# Remove Cursor Co-Author from Git History

In the latest update, Cursor has taken to introducing itself in every commit message. Don't get me wrong: I'm all for full transparency when it comes to AI-assisted coding. I'm just not satisfied with Cursor doing it on its own, without permission. So I use Cursor—ironically—to get rid of its own messages.

This script strips `Co-authored-by: Cursor <cursoragent@cursor.com>` from all commit messages in a repo using `git-filter-repo`, and can force-push to the given GitHub remote (or only rewrite history locally). It supports a JSON config for defaults, and can process multiple repos in one run.

## Requirements

- **bash**
- **git**
- **git-filter-repo**
- **python3** (for JSON config and JSON repos file)

Install `git-filter-repo` (macOS):

```bash
brew install git-filter-repo
```

## Usage

```text
remove-cursor-coauthor.sh [OPTIONS] [<url> <path> ...]
remove-cursor-coauthor.sh [OPTIONS] --repos-file <file>
remove-cursor-coauthor.sh [OPTIONS] --config <config.json>
```


| Option                | Description                                             |
| --------------------- | ------------------------------------------------------- |
| `--dry-run`           | Print commands, do not run them                         |
| `--no-push`           | Rewrite history locally only; do not add origin or push |
| `--force-push`        | When pushing, use `--force` (default)                   |
| `--no-force-push`     | When pushing, do not use `--force`                      |
| `--validate-only`     | Run all checks but do not rewrite or push               |
| `--quiet`, `-q`       | Minimal output: one line per repo (pass/fail)           |
| `--verbose`, `-v`     | Show every git command (default)                        |
| `--config <file>`     | Load defaults and optionally repos from JSON            |
| `--repos-file <file>` | Process repos from file (see below)                     |
| `--version`           | Print version and exit                                  |
| `--help`              | Show help                                               |


Repo input:

- **Positional:** Pairs of `<github_repo_url>` and `<absolute_local_repo_path>`. You can pass multiple pairs in one call.
- `**--repos-file`:** File with one `url path` per line (path = rest of line), or a JSON array `[ {"url": "...", "path": "..."}, ... ]`.
- `**--config`:** JSON file with a `repos` array (and optional `defaults`). See Config JSON below.

URL format: `https://github.com/<user>/<repo>` or `git@github.com:<user>/<repo>` (with or without `.git`).

## Config JSON

Use `--config <file>` to set defaults and optionally list repos. CLI options override config defaults.

Example config: [remove-cursor-coauthor.example.json](remove-cursor-coauthor.example.json). Minimal copy:

```json
{
  "defaults": {
    "dryRun": false,
    "noPush": false,
    "forcePush": true
  },
  "repos": [
    { "url": "https://github.com/user/repo1", "path": "/path/to/repo1" },
    { "url": "git@github.com:user/repo2.git", "path": "/path/to/repo2" }
  ]
}
```

- **defaults** (optional): `dryRun`, `noPush`, `forcePush` (booleans). Omitted keys keep script defaults.
- **repos** (optional): Array of `{ "url": "...", "path": "..." }`. If present, positional repo pairs and `--repos-file` are ignored when `--config` is used; to add more repos, put them in the config or use `--repos-file` without `--config`.

Run with defaults from config (repos from config):

```bash
./remove-cursor-coauthor.sh --config remove-cursor-coauthor.json
```

Override config (e.g. local-only for this run):

```bash
./remove-cursor-coauthor.sh --config remove-cursor-coauthor.json --no-push
```

## Examples

Single repo, force-push (default):

```bash
./remove-cursor-coauthor.sh https://github.com/user/repo /path/to/repo
```

Single repo, local only (no push):

```bash
./remove-cursor-coauthor.sh --no-push https://github.com/user/repo /path/to/repo
```

Push without force:

```bash
./remove-cursor-coauthor.sh --no-force-push https://github.com/user/repo /path/to/repo
```

Dry-run:

```bash
./remove-cursor-coauthor.sh --dry-run https://github.com/user/repo /path/to/repo
```

Validate without rewriting (pre-flight check):

```bash
./remove-cursor-coauthor.sh --validate-only https://github.com/user/repo /path/to/repo
```

Quiet mode (one line per repo):

```bash
./remove-cursor-coauthor.sh --quiet https://github.com/user/repo /path/to/repo
```

Multiple repos (positional pairs):

```bash
./remove-cursor-coauthor.sh \
  https://github.com/user/repo1 /path/to/repo1 \
  https://github.com/user/repo2 /path/to/repo2
```

Batch from plain file (one `url path` per line):

```bash
./remove-cursor-coauthor.sh --repos-file repos.txt
```

Batch from config (defaults + repos list):

```bash
./remove-cursor-coauthor.sh --config my-defaults.json
```

## Important / Caveats

- **History rewrite:** The script rewrites commit history. If you push (default), it force-pushes. Anyone else with a clone must re-clone or rebase.
- `**--no-push`:** Only rewrites history locally (backup branch is created then removed). No remote is added and nothing is pushed.
- **Local path:** Must be **absolute**. A warning is shown if the directory's basename does not match the repo name from the URL, but processing continues.
- **Branch required:** The repo must be on a branch (not detached HEAD). Check out `main` or your target branch before running.
- **Backup branch:** A local branch `backup/remove-cursor-<timestamp>-<pid>` is created before filtering. Only that branch is deleted after a successful run. Remote backup branches from previous runs matching `backup/remove-cursor-`* are also removed when pushing.
- **Remotes:** `git-filter-repo` may remove existing remotes. The script re-adds only `origin` when pushing. If you had other remotes (e.g. `upstream`), re-add them manually.
- **Exit code:** Returns 0 if all repos succeed; returns 1 if any repo fails. For batch runs, a summary is printed.

## No warranty

Use at your own risk. This script modifies Git history and remotes; ensure you have backups or have tried `--dry-run` first.

## See also

- [SECURITY_AND_QUALITY.md](SECURITY_AND_QUALITY.md) — security assumptions, temp cleanup, safe usage.

