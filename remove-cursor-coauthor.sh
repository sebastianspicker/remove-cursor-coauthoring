#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.1"
BACKUP_BRANCH_PREFIX="backup/remove-cursor-"
# Python snippet for git-filter-repo --message-callback: strip Cursor co-author trailer and collapse blank lines
MESSAGE_CALLBACK=$'import re\nmessage = re.sub(br"(?im)^Co-authored-by:\\s*Cursor <cursoragent@cursor\\.com>\\s*(?:\\r?\\n)?", b"", message)\nmessage = re.sub(br"(?:\\r?\\n){3,}", b"\\n\\n", message)\nreturn message\n'

# Global temp files for cleanup (trap removes them on exit)
TEMP_FILES=()
cleanup() {
  for f in "${TEMP_FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

# Colored output when stdout is a TTY and NO_COLOR is unset
use_color=false
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  use_color=true
fi

# Create a temp file and register it for cleanup. Path is stored in CREATED_TEMP_FILE (caller must not use command substitution).
create_temp_file() {
  CREATED_TEMP_FILE=$(mktemp)
  TEMP_FILES+=("$CREATED_TEMP_FILE")
}

# Ensure each required command is on PATH; exit 1 with message if not.
require_command() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "Required command not found: $cmd"
      exit 1
    fi
  done
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
  cat <<'EOF'
Usage:
  remove-cursor-coauthor.sh [OPTIONS] [<github_repo_url> <absolute_local_repo_path> ...]
  remove-cursor-coauthor.sh [OPTIONS] --repos-file <file>
  remove-cursor-coauthor.sh [OPTIONS] --config <config.json>

  URL format: https://github.com/<user>/<repo> or git@github.com:<user>/<repo>

Options:
  --dry-run         Print commands, do not run them (default: false)
  --no-push         Rewrite history locally only; do not push to remote (default: false)
  --force-push      When pushing, use --force (default: true)
  --no-force-push   When pushing, do not use --force
  --validate-only   Run all checks but do not rewrite history or push
  --quiet           Minimal output: one line per repo (pass/fail)
  --verbose         Show every git command (default when not --quiet)
  --config <file>   Load defaults and optionally repos from JSON file
  --repos-file <f>  Process repos from file (JSON array or "url path" lines)
  --backup-remote <name>  Before rewriting, push current branch to this remote (skipped if --dry-run or --no-push)
  --version         Print version and exit
  --help            Show this help

Config JSON (--config) may contain:
  defaults: { "dryRun": false, "noPush": false, "forcePush": true, "backupRemote": "backup" }
  repos: [ { "url": "...", "path": "..." }, ... ]

Repos file (--repos-file): one "url path" per line, or JSON [ {"url":"...","path":"..."}, ... ]

Examples:
  # Single repo, force-push (default)
  remove-cursor-coauthor.sh https://github.com/u/r /path/to/r

  # Single repo, local only (no push)
  remove-cursor-coauthor.sh --no-push https://github.com/u/r /path/to/r

  # Validate without rewriting
  remove-cursor-coauthor.sh --validate-only https://github.com/u/r /path/to/r

  # Batch from file
  remove-cursor-coauthor.sh --repos-file repos.txt

  # Batch from config with defaults
  remove-cursor-coauthor.sh --config my-defaults.json
EOF
}

# =============================================================================
# HELPERS
# =============================================================================

# Parses a GitHub URL into its components.
# Sets globals: PARSED_USERNAME, PARSED_REPONAME, PARSED_CANONICAL_URL.
# Returns 0 on success, 1 on failure. Callers must check return code
# before using the globals (they are reset to empty on each call).
parse_github_url() {
  local url="$1"
  local url_clean="${url%.git}"
  url_clean="${url_clean%/}"
  PARSED_USERNAME=""
  PARSED_REPONAME=""
  PARSED_CANONICAL_URL=""
  # Matches:
  # https://github.com/user/repo[.git]
  # git@github.com:user/repo[.git]
  # ssh://git@github.com/user/repo[.git]
  if [[ "$url_clean" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+)$ ]]; then
    PARSED_USERNAME="${BASH_REMATCH[2]}"
    PARSED_REPONAME="${BASH_REMATCH[3]}"
    if [[ "${BASH_REMATCH[1]}" == "git@github.com:" ]]; then
      PARSED_CANONICAL_URL="git@github.com:$PARSED_USERNAME/$PARSED_REPONAME"
    else
      PARSED_CANONICAL_URL="https://github.com/$PARSED_USERNAME/$PARSED_REPONAME"
    fi
    return 0
  fi
  return 1
}

# Normalize a GitHub URL to https://github.com/user/repo for comparison.
# Outputs nothing if the URL is not a recognized GitHub URL.
normalize_github_url_for_compare() {
  local url="${1%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+)$ ]]; then
    echo "https://github.com/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  fi
}

# Unified search using rg (if available) or grep as fallback.
# Checks all local refs for remaining Cursor co-author trailers.
check_cursor_trailers() {
  local repo_path="$1"
  local search_cmd
  local scan_rc=0
  if command -v rg >/dev/null 2>&1; then
    search_cmd=(rg -in)
  else
    search_cmd=(grep -Ein)
  fi
  [[ "$QUIET" == false ]] && echo "  (scanning all local branches and tags for remaining trailers)"
  if git -C "$repo_path" log --all --format='%B' \
     | "${search_cmd[@]}" "co-authored-by: cursor|cursoragent@cursor.com" >/dev/null; then
    log_warn "Cursor co-author trailer still found (in --all refs)."
  else
    scan_rc=$?
    if [[ $scan_rc -eq 1 ]]; then
      log_ok "No Cursor co-author trailers remaining (all refs checked)."
    else
      log_warn "Could not complete trailer scan (git log/search failed)."
    fi
  fi
}

# Unified JSON extraction via a single Python invocation.
# Usage: _json_extract <file> <mode: defaults|repos|root>
# Output depends on mode:
#   defaults → KEY=value lines (DRY_RUN, NO_PUSH, FORCE_PUSH)
#   repos    → url\tpath lines from data.repos[]
#   root     → url\tpath lines from data[] (root-level array)
_json_extract() {
  local json_file="$1"
  local mode="$2"
  python3 -c "
import json, sys
mode = sys.argv[2]
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
if mode == 'defaults':
    d = data.get('defaults') if isinstance(data.get('defaults'), dict) else {}
    for k, o in [('dryRun','DRY_RUN'),('noPush','NO_PUSH'),('forcePush','FORCE_PUSH')]:
        if isinstance(d.get(k), bool): print(o + '=' + ('true' if d[k] else 'false'))
    if 'backupRemote' in d and isinstance(d.get('backupRemote'), str) and d['backupRemote']:
        print('BACKUP_REMOTE=' + d['backupRemote'].replace(chr(10),'').replace(chr(13),''))
elif mode == 'repos':
    for r in (data.get('repos') or []):
        if not isinstance(r, dict): continue
        u, p = str(r.get('url') or '').replace('\t',' '), str(r.get('path') or '').replace('\t',' ')
        print(u + '\t' + p)
elif mode == 'root':
    for r in (data if isinstance(data, list) else []):
        if not isinstance(r, dict): continue
        u, p = str(r.get('url') or '').replace('\t',' '), str(r.get('path') or '').replace('\t',' ')
        print(u + '\t' + p)
" "$json_file" "$mode"
}

# Print and optionally execute a command. Respects DRY_RUN, VERBOSE, and QUIET (suppresses command output when true).
run_cmd() {
  if [[ "$VERBOSE" == true ]]; then
    printf '+'
    for a in "$@"; do
      printf ' %q' "$a"
    done
    echo
  fi
  if [[ "$DRY_RUN" == false ]]; then
    if [[ "$QUIET" == true ]]; then
      "$@" >/dev/null 2>&1
    else
      "$@"
    fi
  fi
}

# Push current branch and tags to remote. force_push is "true" or "false". Returns 0 on success, 1 on failure.
push_branch_and_tags() {
  local repo_path="$1"
  local remote="$2"
  local branch="$3"
  local force_push="$4"
  if [[ "$force_push" == true ]]; then
    run_cmd git -C "$repo_path" push -u "$remote" --force "$branch" || return 1
    run_cmd git -C "$repo_path" push "$remote" --force --tags || return 1
  else
    run_cmd git -C "$repo_path" push -u "$remote" "$branch" || return 1
    run_cmd git -C "$repo_path" push "$remote" --tags || return 1
  fi
}

# Resolve push remote from backed-up remotes:
# 1) remote whose URL matches requested GitHub repo URL
# 2) origin, if present
# 3) first available remote
# Prints selected remote name on stdout; returns 1 if none available.
resolve_target_remote() {
  local backup_file="$1"
  local canonical_url="$2"
  local canonical_norm
  local rname rurl
  local first_remote=""
  local origin_seen=false
  canonical_norm=$(normalize_github_url_for_compare "$canonical_url")

  while IFS=$'\t' read -r rname rurl; do
    [[ -z "$rname" || -z "$rurl" ]] && continue
    [[ -z "$first_remote" ]] && first_remote="$rname"
    [[ "$rname" == "origin" ]] && origin_seen=true
    if [[ -n "$canonical_norm" && "$(normalize_github_url_for_compare "$rurl")" == "$canonical_norm" ]]; then
      echo "$rname"
      return 0
    fi
  done < "$backup_file"

  if [[ "$origin_seen" == true ]]; then
    echo "origin"
    return 0
  fi
  if [[ -n "$first_remote" ]]; then
    echo "$first_remote"
    return 0
  fi
  return 1
}

# =============================================================================
# LOGGING HELPERS
# =============================================================================

log_ok()    { if [[ "$use_color" == true ]]; then echo -e "\033[32m[ok]\033[0m $*"; else echo "[ok] $*"; fi; }
log_warn()  { if [[ "$use_color" == true ]]; then echo -e "\033[33m[warn]\033[0m $*" >&2; else echo "[warn] $*" >&2; fi; }
log_error() { if [[ "$use_color" == true ]]; then echo -e "\033[31m[error]\033[0m $*" >&2; else echo "[error] $*" >&2; fi; }
log_info()  { [[ "$QUIET" == false ]] && echo "[info] $*"; }
log_skip()  { echo "[skip] $*"; }

# =============================================================================
# CONFIG & REPO LOADING
# =============================================================================

apply_config_defaults() {
  local config_file="$1"
  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0
  local tmp
  create_temp_file
  tmp=$CREATED_TEMP_FILE
  _json_extract "$config_file" "defaults" > "$tmp" 2>/dev/null || {
    log_warn "Failed to parse config defaults from $config_file (is it valid JSON?)"
    return 0
  }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    case "$key" in
      DRY_RUN)     [[ "$val" == true || "$val" == false ]] && DRY_RUN="$val" ;;
      NO_PUSH)     [[ "$val" == true || "$val" == false ]] && NO_PUSH="$val" ;;
      FORCE_PUSH)  [[ "$val" == true || "$val" == false ]] && FORCE_PUSH="$val" ;;
      BACKUP_REMOTE) [[ -n "$val" ]] && BACKUP_REMOTE="$val" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

load_repos_from_json_file() {
  local json_file="$1"
  local mode="${2:-repos}"
  local tmp
  create_temp_file
  tmp=$CREATED_TEMP_FILE
  _json_extract "$json_file" "$mode" > "$tmp" 2>/dev/null || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" != *$'\t'* ]] && continue
    REPO_URLS+=("${line%%$'\t'*}")
    REPO_PATHS+=("${line#*$'\t'}")
  done < "$tmp"
  return 0
}

load_repos_from_config() {
  local config_file="$1"
  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0
  if load_repos_from_json_file "$config_file" "repos"; then
    if [[ ${#REPO_URLS[@]} -gt 0 ]]; then
      CONFIG_HAS_REPOS=true
    fi
    return 0
  else
    log_error "Failed to load config (need python3 and valid JSON): $config_file"
    exit 1
  fi
}

load_repos_from_file() {
  local repos_file="$1"
  [[ -z "$repos_file" || ! -f "$repos_file" ]] && return 0
  if python3 -c "import json, sys; d = json.load(open(sys.argv[1], encoding='utf-8')); exit(0 if isinstance(d, list) else 1)" "$repos_file" 2>/dev/null; then
    load_repos_from_json_file "$repos_file" "root" || true
  else
    # Plain-text format: first token is URL (must not contain spaces), rest of line is path
    while IFS= read -r line; do
      # Strip comments and all leading/trailing whitespace
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      local url="${line%% *}"
      local path="${line#* }"
      path="${path#"${path%%[![:space:]]*}"}"
      path="${path%"${path##*[![:space:]]}"}"
      if [[ -z "$path" || "$path" == "$url" ]]; then
        log_warn "Repos file line must be 'url path'; path missing: $line"
        continue
      fi
      REPO_URLS+=("$url")
      REPO_PATHS+=("$path")
    done < "$repos_file"
  fi
}

# =============================================================================
# PROCESS ONE REPO
# =============================================================================

# Validates URL and path; sets USERNAME, REPONAME, CANONICAL_URL, CURRENT_BRANCH.
# If VALIDATE_ONLY, prints validation message and returns 0. Returns 1 on validation failure.
validate_repo_input() {
  local GITHUB_URL="$1"
  local LOCAL_REPO_PATH="$2"
  if ! parse_github_url "$GITHUB_URL"; then
    log_error "GitHub URL must be https://github.com/<user>/<repo> or git@github.com:<user>/<repo> (got: $GITHUB_URL)"
    return 1
  fi
  USERNAME="$PARSED_USERNAME"
  REPONAME="$PARSED_REPONAME"
  CANONICAL_URL="$PARSED_CANONICAL_URL"

  if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_.-]+$ || ! "$REPONAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    log_error "Username and repo name must contain only letters, numbers, dots, hyphens, and underscores."
    return 1
  fi

  if [[ "$LOCAL_REPO_PATH" != /* ]]; then
    log_error "Local repo path must be absolute: $LOCAL_REPO_PATH"
    return 1
  fi

  if [[ ! -d "$LOCAL_REPO_PATH" ]]; then
    log_error "Local repo path does not exist: $LOCAL_REPO_PATH"
    return 1
  fi

  if [[ "$(basename "$LOCAL_REPO_PATH")" != "$REPONAME" ]]; then
    log_warn "Repo name from URL ('$REPONAME') does not match local dir basename ('$(basename "$LOCAL_REPO_PATH")'). Proceeding anyway."
  fi

  if ! git -C "$LOCAL_REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "Path is not a git repository: $LOCAL_REPO_PATH"
    return 1
  fi

  if [[ "$NO_PUSH" == false && "$DRY_RUN" == false ]]; then
    local has_remote=0
    local remote_name
    while IFS= read -r remote_name; do
      [[ -n "$remote_name" ]] && { has_remote=1; break; }
    done < <(git -C "$LOCAL_REPO_PATH" remote 2>/dev/null || true)
    if [[ $has_remote -eq 0 ]]; then
      log_error "Repository has no remotes configured; add a remote or run with --no-push: $LOCAL_REPO_PATH"
      return 1
    fi
  fi

  CURRENT_BRANCH="$(git -C "$LOCAL_REPO_PATH" symbolic-ref --quiet --short HEAD || true)"
  if [[ -z "$CURRENT_BRANCH" ]]; then
    log_error "Repository is in detached HEAD state. Check out a branch first (e.g. main or master): $LOCAL_REPO_PATH"
    return 1
  fi

  if [[ "$VALIDATE_ONLY" == true ]]; then
    if [[ "$QUIET" == true ]]; then
      log_ok "$USERNAME/$REPONAME — validation passed"
    else
      echo "---"
      echo "Validated: $USERNAME/$REPONAME"
      echo "  url:    $CANONICAL_URL"
      echo "  local:  $LOCAL_REPO_PATH"
      echo "  branch: $CURRENT_BRANCH"
      log_ok "All checks passed (validate-only; no changes made)."
    fi
    return 0
  fi
  return 0
}

# Backs up remotes, optionally pushes to BACKUP_REMOTE, creates backup branch, runs filter-repo, restores remotes.
# Sets BACKUP_BRANCH, BACKUP_REMOTES_TMP. Returns 1 if filter-repo failed.
do_rewrite_and_restore_remotes() {
  local LOCAL_REPO_PATH="$1"
  BACKUP_BRANCH="${BACKUP_BRANCH_PREFIX}$(date +%Y%m%d-%H%M%S)-$$"

  if [[ "$QUIET" == false ]]; then
    echo "---"
    echo "Processing: $USERNAME/$REPONAME"
    echo "  url:        $CANONICAL_URL"
    echo "  local:      $LOCAL_REPO_PATH"
    echo "  branch:     $CURRENT_BRANCH"
    echo "  dry-run:    $DRY_RUN"
    echo "  no-push:    $NO_PUSH"
    echo "  force-push: $FORCE_PUSH"
  fi

  create_temp_file
  BACKUP_REMOTES_TMP=$CREATED_TEMP_FILE
  git -C "$LOCAL_REPO_PATH" remote -v | awk '/\(fetch\)/ {print $1"\t"$2}' > "$BACKUP_REMOTES_TMP" 2>/dev/null || true

  if [[ -n "${BACKUP_REMOTE:-}" && "$DRY_RUN" == false && "$NO_PUSH" == false ]]; then
    run_cmd git -C "$LOCAL_REPO_PATH" push "$BACKUP_REMOTE" "$CURRENT_BRANCH" || return 1
  fi

  run_cmd git -C "$LOCAL_REPO_PATH" branch "$BACKUP_BRANCH" || return 1

  local filter_err=0
  run_cmd git -C "$LOCAL_REPO_PATH" filter-repo --refs "$CURRENT_BRANCH" --force --message-callback "$MESSAGE_CALLBACK" || filter_err=1

  if [[ "$DRY_RUN" == false ]]; then
    while IFS=$'\t' read -r rname rurl; do
      [[ -z "$rname" || -z "$rurl" ]] && continue
      git -C "$LOCAL_REPO_PATH" remote add "$rname" "$rurl" 2>/dev/null || true
    done < "$BACKUP_REMOTES_TMP"
  else
    log_info "Would restore remotes from backup"
  fi

  if [[ $filter_err -ne 0 ]]; then
    log_error "git-filter-repo failed during execution! Remotes have been restored."
    return 1
  fi
  return 0
}

# Resolves TARGET_REMOTE from BACKUP_REMOTES_TMP (file is read again; small file, separate concern) and pushes branch and tags.
do_push_phase() {
  local LOCAL_REPO_PATH="$1"
  TARGET_REMOTE="origin"
  TARGET_REMOTE="$(resolve_target_remote "$BACKUP_REMOTES_TMP" "$CANONICAL_URL" || true)"
  if [[ -z "$TARGET_REMOTE" ]]; then
    if [[ "$DRY_RUN" == false ]]; then
      log_error "No usable remotes available for push."
      return 1
    fi
    # In dry-run mode, allow command preview even if no remote can be resolved.
    TARGET_REMOTE="origin"
  fi

  push_branch_and_tags "$LOCAL_REPO_PATH" "$TARGET_REMOTE" "$CURRENT_BRANCH" "$FORCE_PUSH" || return 1
  return 0
}

# Deletes remote backup branches, local backup branch, runs check_cursor_trailers, fetch --prune.
do_cleanup_and_verify() {
  local LOCAL_REPO_PATH="$1"
  if [[ "$DRY_RUN" == false ]]; then
    # Delete only backup branches on the selected push remote. This avoids
    # ambiguous parsing when remote names contain '/' (valid in git).
    if [[ -n "${TARGET_REMOTE:-}" ]]; then
      local fullref br
      while IFS= read -r fullref; do
        [[ -z "$fullref" ]] && continue
        br="${fullref#refs/remotes/"$TARGET_REMOTE"/}"
        [[ -z "$br" || "$br" == "$fullref" ]] && continue
        run_cmd git -C "$LOCAL_REPO_PATH" push "$TARGET_REMOTE" --delete "$br" || true
      done < <(git -C "$LOCAL_REPO_PATH" for-each-ref --format='%(refname)' "refs/remotes/$TARGET_REMOTE/${BACKUP_BRANCH_PREFIX}*" 2>/dev/null || true)
    fi

    run_cmd git -C "$LOCAL_REPO_PATH" branch -D "$BACKUP_BRANCH" || true

    check_cursor_trailers "$LOCAL_REPO_PATH"

    if [[ -n "${TARGET_REMOTE:-}" ]]; then
      run_cmd git -C "$LOCAL_REPO_PATH" fetch --prune "$TARGET_REMOTE" || true
    fi
    [[ "$VERBOSE" == true ]] && run_cmd git -C "$LOCAL_REPO_PATH" branch -a || true
  else
    log_info "Skipped network/git mutations and verification (dry-run)."
  fi
  return 0
}

process_one_repo() {
  local GITHUB_URL="$1"
  local LOCAL_REPO_PATH="$2"

  validate_repo_input "$GITHUB_URL" "$LOCAL_REPO_PATH" || return 1
  [[ "$VALIDATE_ONLY" == true ]] && return 0

  do_rewrite_and_restore_remotes "$LOCAL_REPO_PATH" || return 1

  if [[ "$NO_PUSH" == true ]]; then
    log_info "Skipping remote and push; history rewritten locally only."
    if [[ "$DRY_RUN" == false ]]; then
      run_cmd git -C "$LOCAL_REPO_PATH" branch -D "$BACKUP_BRANCH" || true
    fi
    [[ "$QUIET" == true ]] && log_ok "$USERNAME/$REPONAME — rewritten locally"
    return 0
  fi

  do_push_phase "$LOCAL_REPO_PATH" || return 1
  do_cleanup_and_verify "$LOCAL_REPO_PATH"

  [[ "$QUIET" == true ]] && log_ok "$USERNAME/$REPONAME — done"
  return 0
}

# =============================================================================
# CLI PARSING
# =============================================================================

# Defaults (overridden by --config, then by CLI)
DRY_RUN=false
NO_PUSH=false
FORCE_PUSH=true
VALIDATE_ONLY=false
QUIET=false
VERBOSE=true
CONFIG_FILE=""
REPOS_FILE=""
BACKUP_REMOTE=""
REPO_ARGS=()

# (1) Pre-scan for --config so we can load defaults before CLI parsing
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "--config" && $((i+1)) -lt ${#args[@]} ]]; then
    CONFIG_FILE="${args[$((i+1))]}"
  fi
done

# (2) Apply config defaults; CLI will override below
apply_config_defaults "$CONFIG_FILE"

# (3) Parse CLI options (overrides config)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "remove-cursor-coauthor $VERSION"
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-push)
      NO_PUSH=true
      shift
      ;;
    --force-push)
      FORCE_PUSH=true
      shift
      ;;
    --no-force-push)
      FORCE_PUSH=false
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    --quiet|-q)
      QUIET=true
      VERBOSE=false
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      QUIET=false
      shift
      ;;
    --config)
      [[ $# -lt 2 ]] && { log_error "--config requires <file>"; usage; exit 1; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --repos-file)
      [[ $# -lt 2 ]] && { log_error "--repos-file requires <file>"; usage; exit 1; }
      REPOS_FILE="$2"
      shift 2
      ;;
    --backup-remote)
      [[ $# -lt 2 ]] && { log_error "--backup-remote requires <remote name>"; usage; exit 1; }
      BACKUP_REMOTE="$2"
      shift 2
      ;;
    -*)
      log_error "Unsupported option '$1'"
      usage
      exit 1
      ;;
    *)
      REPO_ARGS+=("$1")
      shift
      ;;
  esac
done

# =============================================================================
# REPO LIST BUILDING
# =============================================================================

REPO_URLS=()
REPO_PATHS=()
CONFIG_HAS_REPOS=false

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi
  load_repos_from_config "$CONFIG_FILE"
fi

if [[ -n "$REPOS_FILE" ]]; then
  if [[ "$CONFIG_HAS_REPOS" == true ]]; then
    log_warn "--repos-file ignored because --config contains repos."
  else
    if [[ ! -f "$REPOS_FILE" ]]; then
      log_error "Repos file not found: $REPOS_FILE"
      exit 1
    fi
    load_repos_from_file "$REPOS_FILE"
  fi
fi

if [[ ${#REPO_ARGS[@]} -gt 0 && "$CONFIG_HAS_REPOS" != true ]]; then
  if [[ $((${#REPO_ARGS[@]} % 2)) -ne 0 ]]; then
    log_error "Repo list must be pairs of <url> <path> (got ${#REPO_ARGS[@]} args)"
    usage
    exit 1
  fi
  i=0
  while [[ $i -lt ${#REPO_ARGS[@]} ]]; do
    REPO_URLS+=("${REPO_ARGS[$i]}")
    REPO_PATHS+=("${REPO_ARGS[$((i+1))]}")
    i=$((i+2))
  done
fi

# =============================================================================
# VALIDATION
# =============================================================================

if [[ ${#REPO_URLS[@]} -eq 0 ]]; then
  log_error "No repos specified. Use <url> <path>, --repos-file, or --config with repos array."
  usage
  exit 1
fi

require_command git
if [[ "$VALIDATE_ONLY" == false ]]; then
  if ! command -v git-filter-repo >/dev/null 2>&1; then
    log_error "git-filter-repo is required. Install with: brew install git-filter-repo"
    exit 1
  fi
fi
if [[ -n "$CONFIG_FILE" || -n "$REPOS_FILE" ]]; then
  require_command python3
fi
if [[ -n "$BACKUP_REMOTE" && ! "$BACKUP_REMOTE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  log_error "--backup-remote must be a valid remote name (letters, numbers, dots, hyphens, underscores only)"
  exit 1
fi

# =============================================================================
# PROCESSING
# =============================================================================

num_repos=${#REPO_URLS[@]}
fail_count=0
success_count=0
FAILED_REPO_URLS=()
FAILED_REPO_PATHS=()

for ((i=0; i<num_repos; i++)); do
  [[ "$QUIET" == false ]] && echo "========== Repo $((i+1))/$num_repos =========="
  set +e
  process_one_repo "${REPO_URLS[$i]}" "${REPO_PATHS[$i]}"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    FAILED_REPO_URLS+=("${REPO_URLS[$i]}")
    FAILED_REPO_PATHS+=("${REPO_PATHS[$i]}")
    [[ "$QUIET" == false ]] && echo "Failed for ${REPO_URLS[$i]} (${REPO_PATHS[$i]}); continuing with next."
    [[ "$QUIET" == true ]] && log_error "${REPO_URLS[$i]} — failed"
    fail_count=$((fail_count + 1))
  else
    success_count=$((success_count + 1))
  fi
done

# --- Summary ---

if [[ $num_repos -eq 1 && $fail_count -gt 0 ]]; then
  echo "Done (failed)."
elif [[ $num_repos -gt 1 ]]; then
  echo "Done. $success_count/$num_repos succeeded, $fail_count failed."
else
  echo "Done."
fi
if [[ $fail_count -gt 0 && "$QUIET" == false ]]; then
  echo -n "Failed repos:"
  for ((i=0; i<fail_count; i++)); do
    echo -n " ${FAILED_REPO_URLS[$i]} (${FAILED_REPO_PATHS[$i]})"
  done
  echo
fi

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
