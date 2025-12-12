<!-- Project-specific guidance for AI coding agents working on Taskpony -->

# Quick orientation
- **Language & framework**: Single-file Perl PSGI web app (`taskpony.psgi`) using Plack/DBI/SQLite and bundled frontend assets in `static/`.
- **Primary runtime**: run with `plackup` (or via the included `taskpony.service` systemd unit or Docker). See `readme.md` for installation notes.

# Key files to inspect
- `taskpony.psgi` — the application entrypoint and main implementation (HTML templating is inline). Most edits happen here.
- `readme.md` — operational notes: `plackup` command, service location `/opt/taskpony`, Docker examples, and DB schema summary.
- `taskpony.service` — example systemd unit used on Linux installations (shows expected WorkingDirectory and ExecStart).
- `Dockerfile`, `docker-compose.yml`, `build-docker.sh` — Docker build/run options; the image `digdilem/taskpony` is published.
- `static/` — JS/CSS and bundled frontend libs (Bootstrap, jQuery, DataTables, FontAwesome SVGs).

# Project patterns and conventions (concrete, actionable)
- Inline HTML assembly: the app builds pages by appending to a `$html` (and `$retstr`) string using `qq~ ... ~;` blocks. Preserve the `~` delimiter when editing or adding blocks to avoid delimiter collisions.
- Interpolation inside `qq~` uses Perl variable/hashref syntax; examples: `bg-$config->{cfg_header_colour}` and interpolation of `$list_name`. Use braces for hashrefs.
- Control-flow style: lots of nested `if/else` blocks inside the PSGI file — be careful to keep braces balanced. A common syntax failure is an extra or missing `}` near inline HTML blocks (see recent fix around the quick-add form).
- Database access: uses DBI prepared statements (`$dbh->prepare(...)` and `$sth->execute(...)`). Look for `TasksTb`, `ListsTb`, and `ConfigTb` usage for migrations/changes.
- Routes: simple path-based handlers (e.g., `/add`, `/config`, `/lists`, `/edittask`, `/complete`, `/ust`). Modify handlers in `taskpony.psgi` rather than adding a new router layer.

# Build / run / debug commands (examples)
- Run locally (dev):
```
plackup -r -p 5000 taskpony.psgi
```
- Systemd service (production): copy `taskpony.service` to `/etc/systemd/system`, edit `WorkingDirectory` or `$db_path` in `taskpony.psgi` if installing outside `/opt/taskpony`.
- Docker (quick run):
```
docker run -d -p 5000:5000 digdilem/taskpony:latest
```
- Syntax check on development machine: `perl -c taskpony.psgi` (ensure Perl and modules are installed).

# Dependencies & environment
- Perl modules are listed in `cpanfile`. Ensure `Plack`, `DBI`, `DBD::SQLite` are available on the host. In Docker these are preinstalled.
- The app expects a writable SQLite DB (default `taskpony.db` in the configured data directory). Back up this file to preserve data.

# Small-edit rules for contributors / agents
- Prefer small, local changes inside `taskpony.psgi`. Avoid splitting into many files unless you add tests and update `readme.md`.
- When editing HTML fragments: keep `qq~`/`~;` intact and ensure nested `~` does not appear in content; if needed, switch delimiter (e.g., `qq! ... !;`) consistently in the edited block.
- When changing database schema, incrementally migrate existing DBs (document manual migration steps in `readme.md`). There is no migration framework in the repo.
- Preserve single-user design and the decision to avoid authentication; document any security-sensitive changes so maintainers can review them.

# Common pitfalls to watch for
- Missing Perl or modules on the target host: `perl` must be on the PATH for `plackup` and `perl -c` checks.
- Unbalanced braces in `taskpony.psgi` after adding nested HTML blocks — run `perl -c` to catch syntax errors.
- Editing `$db_path` without updating `taskpony.service` or Docker mounts will break persistence.

# Where to ask for clarification
- Open an issue on the repository (`digdilem/taskpony`) for questions about intended UX, DB schema changes, or permissioning choices.

If you want, I can now (a) expand any section with examples, (b) merge with an existing `.github/copilot-instructions.md` if you have one elsewhere, or (c) commit this and run a local syntax check if you provide a machine with Perl installed.
