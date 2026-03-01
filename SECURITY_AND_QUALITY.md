# Security and quality

Short overview for `remove-cursor-coauthor.sh` with practical security and operational guidance for public use.

## Assumptions

- You run the script on repos you control; it is not setuid and does not escalate privileges.
- Config and repos files are trusted (local JSON / text files). Do not point `--config` or `--repos-file` at untrusted paths.
- Git credentials are handled by your existing Git config; the script does not read or store credentials.

## Safety measures

- **No `eval` on user input:** Config defaults are parsed with a strict allowlist (only `DRY_RUN`, `NO_PUSH`, `FORCE_PUSH` with values `true`/`false`). Repo URLs and paths are never passed to `eval`.
- **URL handling:** Remote URL is built only from regex-captured GitHub username/repo segments. No arbitrary string is pasted into the URL.
- **Temp files:** Config is read via a temp file; the script uses a trap to remove it on exit and removes it explicitly on failure so no config data is left on disk.
- **History rewrite:** The script rewrites Git history and can force-push. Use `--dry-run` to preview commands and `--no-push` to only rewrite locally.
- **Remotes:** After filtering, the script restores remote URLs from a backup. Custom refspecs or `pushurl` are not restored; re-add them manually if you use them.

## How to run safely

1. Run with `--dry-run` first to see which commands would be executed.
2. Use `--no-push` if you only want local history rewritten and no push.
3. Ensure the repo is on a branch (not detached HEAD); the script will error otherwise.
4. Do not put secrets in repo paths or config paths; the script may print them in output.

## Requirements

- bash, git, git-filter-repo, python3 (for JSON config/repos). No other dependencies.
