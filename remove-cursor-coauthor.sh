#!/usr/bin/env bash
set -euo pipefail

VERSION="1.1.0"

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
  --version         Print version and exit
  --help            Show this help

Config JSON (--config) may contain:
  defaults: { "dryRun": false, "noPush": false, "forcePush": true }
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
  if [[ "$url_clean" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
    PARSED_USERNAME="${BASH_REMATCH[1]}"
    PARSED_REPONAME="${BASH_REMATCH[2]}"
    PARSED_CANONICAL_URL="https://github.com/$PARSED_USERNAME/$PARSED_REPONAME"
    return 0
  fi
  if [[ "$url_clean" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
    PARSED_USERNAME="${BASH_REMATCH[1]}"
    PARSED_REPONAME="${BASH_REMATCH[2]}"
    PARSED_CANONICAL_URL="git@github.com:$PARSED_USERNAME/$PARSED_REPONAME"
    return 0
  fi
  return 1
}

# Unified search using rg (if available) or grep as fallback.
# Checks all local refs for remaining Cursor co-author trailers.
check_cursor_trailers() {
  local repo_path="$1"
  local search_cmd
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
    log_ok "No Cursor co-author trailers remaining (all refs checked)."
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
with open(sys.argv[1]) as f:
    data = json.load(f)
if mode == 'defaults':
    d = data.get('defaults') or {}
    for k, o in [('dryRun','DRY_RUN'),('noPush','NO_PUSH'),('forcePush','FORCE_PUSH')]:
        if k in d: print(o + '=' + ('true' if d[k] else 'false'))
elif mode == 'repos':
    for r in (data.get('repos') or []):
        print((r.get('url') or '').replace('\t',' ') + '\t' + (r.get('path') or '').replace('\t',' '))
elif mode == 'root':
    for r in (data if isinstance(data, list) else []):
        print((r.get('url') or '').replace('\t',' ') + '\t' + (r.get('path') or '').replace('\t',' '))
" "$json_file" "$mode"
}

# Print and optionally execute a command. Respects DRY_RUN and VERBOSE.
run_cmd() {
  if [[ "$VERBOSE" == true ]]; then
    printf '+'
    for a in "$@"; do
      printf ' %q' "$a"
    done
    echo
  fi
  if [[ "$DRY_RUN" == false ]]; then
    "$@"
  fi
}

# =============================================================================
# LOGGING HELPERS
# =============================================================================

log_ok()    { echo "[ok] $*"; }
log_warn()  { echo "[warn] $*" >&2; }
log_error() { echo "[error] $*" >&2; }
log_info()  { [[ "$QUIET" == false ]] && echo "[info] $*"; }
log_skip()  { echo "[skip] $*"; }

# =============================================================================
# CONFIG & REPO LOADING
# =============================================================================

apply_config_defaults() {
  local config_file="$1"
  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0
  local tmp
  tmp=$(mktemp)
  _json_extract "$config_file" "defaults" > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    log_warn "Failed to parse config defaults from $config_file (is it valid JSON?)"
    return 0
  }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    case "$key" in
      DRY_RUN)    [[ "$val" == true || "$val" == false ]] && DRY_RUN="$val" ;;
      NO_PUSH)    [[ "$val" == true || "$val" == false ]] && NO_PUSH="$val" ;;
      FORCE_PUSH) [[ "$val" == true || "$val" == false ]] && FORCE_PUSH="$val" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

load_repos_from_json_file() {
  local json_file="$1"
  local mode="${2:-repos}"
  local tmp
  tmp=$(mktemp)
  _json_extract "$json_file" "$mode" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    REPO_URLS+=("${line%%$'\t'*}")
    REPO_PATHS+=("${line#*$'\t'}")
  done < "$tmp"
  rm -f "$tmp"
  return 0
}

load_repos_from_config() {
  local config_file="$1"
  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0
  if load_repos_from_json_file "$config_file" "repos"; then
    [[ ${#REPO_URLS[@]} -gt 0 ]] && CONFIG_HAS_REPOS=true
  else
    log_error "Failed to load config (need python3 and valid JSON): $config_file"
    exit 1
  fi
}

load_repos_from_file() {
  local repos_file="$1"
  [[ -z "$repos_file" || ! -f "$repos_file" ]] && return 0
  if head -1 "$repos_file" | grep -qE '^[[:space:]]*\['; then
    load_repos_from_json_file "$repos_file" "root" || true
  else
    while IFS= read -r line; do
      # Strip comments and all leading/trailing whitespace (spaces + tabs)
      line="${line%%#*}"
      line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      local url="${line%% *}"
      local path="${line#* }"
      path="$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
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

process_one_repo() {
  local GITHUB_URL="$1"
  local LOCAL_REPO_PATH="$2"
  local USERNAME REPONAME CANONICAL_URL
  local CURRENT_BRANCH BACKUP_BRANCH CALLBACK

  # --- Validation ---

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

  CURRENT_BRANCH="$(git -C "$LOCAL_REPO_PATH" symbolic-ref --quiet --short HEAD || true)"
  if [[ -z "$CURRENT_BRANCH" ]]; then
    log_error "Repository is in detached HEAD state. Check out a branch first (e.g. main or master): $LOCAL_REPO_PATH"
    return 1
  fi

  # --- Validate-only mode: stop here ---

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

  # --- Rewrite history ---

  BACKUP_BRANCH="backup/remove-cursor-$(date +%Y%m%d-%H%M%S)-$$"
  CALLBACK=$'import re\nmessage = re.sub(br"(?im)^Co-authored-by:\\s*Cursor <cursoragent@cursor\\.com>\\s*(?:\\r?\\n)?", b"", message)\nmessage = re.sub(br"(?:\\r?\\n){3,}", b"\\n\\n", message)\nreturn message\n'

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

  run_cmd git -C "$LOCAL_REPO_PATH" branch "$BACKUP_BRANCH"
  run_cmd git -C "$LOCAL_REPO_PATH" filter-repo --force --message-callback "$CALLBACK"

  # --- No-push mode ---

  if [[ "$NO_PUSH" == true ]]; then
    log_info "Skipping remote and push; history rewritten locally only."
    if [[ "$DRY_RUN" == false ]]; then
      run_cmd git -C "$LOCAL_REPO_PATH" branch -D "$BACKUP_BRANCH"
    fi
    [[ "$QUIET" == true ]] && log_ok "$USERNAME/$REPONAME — rewritten locally"
    return 0
  fi

  # --- Push to remote ---

  if git -C "$LOCAL_REPO_PATH" remote get-url origin >/dev/null 2>&1; then
    run_cmd git -C "$LOCAL_REPO_PATH" remote remove origin
  fi
  run_cmd git -C "$LOCAL_REPO_PATH" remote add origin "$CANONICAL_URL"

  if [[ "$FORCE_PUSH" == true ]]; then
    run_cmd git -C "$LOCAL_REPO_PATH" push -u origin --force "$CURRENT_BRANCH"
    run_cmd git -C "$LOCAL_REPO_PATH" push origin --force --tags
  else
    run_cmd git -C "$LOCAL_REPO_PATH" push -u origin "$CURRENT_BRANCH"
    run_cmd git -C "$LOCAL_REPO_PATH" push origin --tags
  fi

  # --- Cleanup & verification ---

  if [[ "$DRY_RUN" == false ]]; then
    REMOTE_BACKUPS=()
    while IFS= read -r line; do
      line="${line## }"
      [[ -n "$line" ]] && REMOTE_BACKUPS+=("$line")
    done < <(git -C "$LOCAL_REPO_PATH" branch -r --list 'origin/backup/remove-cursor-*' 2>/dev/null | sed 's#^ *origin/##')
    for b in "${REMOTE_BACKUPS[@]}"; do
      [[ -z "$b" ]] && continue
      run_cmd git -C "$LOCAL_REPO_PATH" push origin --delete "$b" || true
    done

    run_cmd git -C "$LOCAL_REPO_PATH" branch -D "$BACKUP_BRANCH"

    check_cursor_trailers "$LOCAL_REPO_PATH"

    run_cmd git -C "$LOCAL_REPO_PATH" fetch --prune origin
    [[ "$VERBOSE" == true ]] && run_cmd git -C "$LOCAL_REPO_PATH" branch -a
  else
    log_info "Skipped network/git mutations and verification (dry-run)."
  fi

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
REPO_ARGS=()

# (1) Pre-scan for --config so we can load defaults before CLI parsing
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "--config" && $((i+1)) -lt ${#args[@]} ]]; then
    CONFIG_FILE="${args[$((i+1))]}"
    break
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

if [[ "$VALIDATE_ONLY" == false ]]; then
  if ! command -v git-filter-repo >/dev/null 2>&1; then
    log_error "git-filter-repo is required. Install with: brew install git-filter-repo"
    exit 1
  fi
fi

# Check python3 when JSON parsing features are used
if [[ -n "$CONFIG_FILE" || -n "$REPOS_FILE" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 is required for --config and --repos-file (JSON parsing)."
    exit 1
  fi
fi

# =============================================================================
# PROCESSING
# =============================================================================

num_repos=${#REPO_URLS[@]}
fail_count=0
success_count=0

for ((i=0; i<num_repos; i++)); do
  [[ "$QUIET" == false ]] && echo "========== Repo $((i+1))/$num_repos =========="
  set +e
  process_one_repo "${REPO_URLS[$i]}" "${REPO_PATHS[$i]}"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    [[ "$QUIET" == false ]] && echo "Failed for ${REPO_URLS[$i]} (${REPO_PATHS[$i]}); continuing with next."
    [[ "$QUIET" == true ]] && log_error "${REPO_URLS[$i]} — failed"
    fail_count=$((fail_count + 1))
  else
    success_count=$((success_count + 1))
  fi
done

# --- Summary ---

if [[ $num_repos -gt 1 ]]; then
  echo "Done. $success_count/$num_repos succeeded, $fail_count failed."
else
  echo "Done."
fi

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
