# OmaBackup design

Date: 2026-09-03. Status: approved in brainstorm, awaiting written review.

## Context

OmaBackup is the public version of a personal Omarchy config backup engine
(`hp-laptop-config`) and the bar widget that fronts it. The landscape
assessment of the same date (`docs/landscape.md`, vault note
`comparison-omarchy-backup-drift-landscape.md`) found that "back up your
config to a private git repo from the bar" is already shipped by four
plugins and planned upstream, while nothing does what this engine does:
report the user config that nothing captures, every day, and refuse to push
when it cannot prove the push is safe. That is the pitch, and the design
protects it.

Decisions taken with the owner before this document:

- Name stays **OmaBackup**; plugin id `io.github.huey-holdings-llc.omabackup`;
  CLI `omabackup`.
- **Fork and generalise.** The engine is copied into this repo and reworked
  here. `hp-laptop-config` keeps running its own scripts until the fork is
  proven, then migrates (section 12).
- **Full engine in 1.0**: scan, snapshot, push, widget, manifests, restore
  (dry run by default), verify, `/etc` reference copies.
- **gitleaks required for push, optional for local commits.**
- **User's own git auth**, GitHub visibility probe when possible, explicit
  trust flag otherwise.
- **Approach A**: one bash CLI over a library, tests black-box against the
  CLI so any library can later be ported to Python behind the same verbs.

## Principles

Copied from OmaRecorder's CONTRIBUTING and applied here:

1. Base Omarchy first. Everything the engine needs ships with Omarchy
   (bash, git, rsync, jq, gum, systemd, flock, pacman). The one exception
   is gitleaks (Arch extra), which gates pushes only and is named at setup.
2. The CLI is the product; QML is a view. Anything the widget does is an
   `omabackup` verb first, with a test.
3. Fail closed. "Cannot verify" is reported like a failure. A guard that
   cannot fire is a bug; every guard has a test that proves it fires.
4. Data is never code. Paths, reasons and URLs travel as argv and `jq --arg`.
   `tests/lint.sh` fails the build on `bash -c` or `/tmp` in QML.
5. Say what it does. README claims are checked against the code; behaviour
   changes update README and CHANGELOG in the same pull request. No em
   dashes in anything user-facing.
6. Read the user's Omarchy, Hyprland and shell config; never write it. The
   engine writes only to the data repo, its own config and state, and the
   user's systemd directory during setup.

## 1. Repository layout (plugin, public)

```
manifest.json          id, version (single source), kinds ["service","bar-widget"], keepLoaded
Service.qml            watches status.json, runs verbs, exposes actions
Panel.qml              bar widget and popup
ui/                    DriftGroupRow, DriftRow, InfoRow, SetupCard, AccessibleActionButton, ThinScrollBar
bin/omabackup          dispatcher: parses the verb, loads lib, routes
lib/common.sh          logging, notify, json helpers, die, argv guards
lib/config.sh          config load and validation, path resolution
lib/lock.sh            the data-repo flock
lib/snapshot.sh        assert, stage, sync, commit, push
lib/drift.sh           the scan and its predicates
lib/manifests.sh       every manifests/ generator with placeholder carry-forward
lib/secrets.sh         gitleaks passes and the filename regex gate
lib/remote.sh          remote parsing, visibility probe, trust flag
lib/lint.sh            list linting and the completeness walk
lib/restore.sh         staged dry-run restore
lib/verify.sh          restore-fidelity check
lib/health.sh          the read-only checks and severity mapping
lib/widget.sh          status JSON and the write verbs (allow, ignore, resolve-gone, push, timer)
lib/setup.sh           the wizard, unit install, removal
share/allowlist.example, drift-ignore.example, etc-allowlist.example, normalize.example
share/gitleaks.toml    the custom rules with their proofs
share/data.gitignore   the belt-and-braces ignore list for the data repo
share/units/           omabackup-snapshot.{service,timer}, omabackup-selftest.{service,timer}, omabackup-failed.service
scripts/dev-install.sh rsync into the plugin dir, validate, symlink CLI, rescan
tests/engine.test.sh   the black-box suite
tests/lint.sh          static checks
tests/fixtures/        synthetic home skeleton, stock tree stand-in
docs/landscape.md, docs/triage.md, docs/superpowers/specs/
README.md, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, LICENSE, preview.png
```

Rules: no symlinks in the tree (validator). No agent-instruction files in
the distributed tree; `AGENTS.md` exists locally and is gitignored, as in
OmaRecorder. The triage skill is not shipped; its procedure is
`docs/triage.md`.

## 2. Data repo contract (private, user-owned)

```
allowlist.txt        one path per line relative to $HOME, globs, dirs recursive, leading ? = optional
drift-ignore.txt     path   # YYYY-MM-DD reason ; path/** ignores a subtree, bare path ignores one entry
etc-allowlist.txt    /etc paths copied for reference only
normalize.txt        <staged path glob> TAB <sed expression>, applied to staged copies
modes.txt            NUL-delimited mode+path for files and dirs
home/                verbatim mirror of allowlisted paths (mode 700)
etc/                 reference copies
manifests/           generated, timestamp-free, plus drift.txt and .last-run (ignored)
.gitignore           copied from share/data.gitignore at setup, never edited by the engine
.gitleaks.toml       NOT written (0.7.0 amendment: the scan always uses the plugin's own
                     share/gitleaks.toml, so a copy in the repo was inert and setup no
                     longer lays one down; repos from before 0.7.0 still carry one)
.omabackup           marker: {"format": 1, "createdBy": "<version>"}
.lock                flock target, ignored
.staging/            scratch, ignored, recreated each run
```

The engine refuses a data repo without the marker or with a format it does
not know (`setup --import` writes the marker after checking the layout).
The engine never writes code, units or config into the data repo. Commit
scope for the timer is `home etc manifests modes.txt`; the four lists are
committed only by `push --confirm`, which shows exactly which files it
will stage and never uses `-A`.

## 3. Config and state

`~/.config/omabackup/config.json` (0600), written by setup, read by every
verb:

```json
{
  "dataRepo": "~/.local/share/omabackup/data",
  "remote": { "url": "git@github.com:me/omabackup-data.git", "trusted": false },
  "maxFileSize": "8m",
  "staleDays": 2,
  "maxMissingPct": 25,
  "maxScanFiles": 2000,
  "notify": true,
  "shellNag": false,
  "timer": { "calendar": "daily", "jitter": "30m" }
}
```

`remote.url` may be empty (local only). `remote.trusted` is only consulted
when the visibility probe cannot run (section 7). Unknown keys are an error
at load, not ignored, so a typo cannot silently disable a threshold.

`~/.local/state/omabackup/status.json` is rewritten atomically (write to
temp, rename) at the end of every verb that changes state and by `status`.
`~/.local/state/omabackup/omabackup.log` rotates at 1 MB. Runtime scratch
is the data repo's `.staging`, never `/tmp`.

Test hooks, all env, all documented as test-only: `OMABACKUP_CONFIG`,
`OMABACKUP_STATE_DIR`, `OMABACKUP_STOCK_DIR` (stand-in for
`/usr/share/omarchy`), `OMABACKUP_NET=0` (disables the probe),
`OMABACKUP_NOTIFY=0`.

## 4. CLI surface

Every verb accepts `--json`; with it, stdout is exactly one JSON object,
even on failure. Exit codes: 0 the command ran (the JSON says whether the
system is healthy), 1 the command refused or found the system unhealthy,
2 usage. Without `--json`, output is human text and the same exit codes.

| Verb | Does | Notes |
| --- | --- | --- |
| `setup [--data-repo DIR] [--remote URL] [--create-private] [--import DIR] [--trust-remote] [--no-timers] [--yes]` | The wizard (section 6) | Every prompt has a flag; `--yes` accepts defaults |
| `setup check` | Doctor: tools, config, data repo marker, units, remote | Names the package for anything missing |
| `setup --remove` | Disable and delete units, remove CLI symlink and config | Data repo untouched, says so |
| `snapshot [--dry-run] [--no-push]` | The pipeline: assert, stage, manifests, modes, scan, floors, secrets, sync, probe, commit, push | The timer runs this |
| `drift` | Run the scan and print the report | Ends with the sentinel; `snapshot` refuses to commit without it |
| `status` | Read-only health, writes status.json | The widget's read; never consumes the nag stamp |
| `allow PATH` | Add to allowlist | Path must be in the current drift report; lock; lint or roll back |
| `ignore PATH [REASON]` | Add to drift-ignore with a dated reason | Default reason "triaged from widget" dated today |
| `resolve-gone PATH remove\|optional` | Fix a GONE entry | Same guards |
| `push [--confirm]` | Push commits; with dirty lists, list them and require `--confirm` | Stages exactly the listed files |
| `lint` | List hygiene and the completeness walk | Exit code = problem count, capped at 1 for the JSON contract |
| `restore --configs\|--etc\|--packages\|--plugins\|--services\|--all [--apply]` | Staged restore, dry run unless `--apply` | Never deletes; per-file safety copies; `--etc` diff only; packages never `--noconfirm` |
| `verify` | Restore the committed backup into a throwaway HOME and compare | Honours normalize exceptions |
| `health` | Login check: silent and 0 when healthy, lines and 1 otherwise | Only this verb writes the nag stamp |
| `timer pause\|resume\|status` | Control the snapshot timer | Pause is a systemd stop of the timer, not a unit condition |
| `self-test [--real]` | The suite (section 9) | `--real` adds the two groups that read the real data repo |
| `open` | Terminal in the data repo | Uses `xdg-terminal-exec` |
| `version` | From manifest.json | |

Write verbs: input is a `~/`-prefixed path exactly as `status` emitted it;
absolute paths, `..`, newlines and tabs are rejected; folder targets are
refused at depth 1 (`~/.config/` can never be silenced by one click). The
lock is held for the edit and any rollback, released before `lint` runs
because lint takes the same lock.

## 5. Widget contract

`Service.qml` is a singleton that:

- watches `status.json` with a FileView in watch mode, keeping the parent
  directory watcher and re-binding after the atomic rename;
- runs `omabackup status --json` on popup open and on manual refresh, and
  after every write verb returns;
- runs no polling timer;
- runs every verb as an argv array; never builds a shell string.

The status object (**field list updated 2026-09-06 to record what 0.7.0
actually emits**; the rest of this section is the original design):

```
state              "ok" | "attention" | "fault"
setup              "not-configured" | "gitleaks-missing" | "remote-unverified" | "ready"
repo, generated, last_run, last_run_age_days
drift_scan_complete, drift_count, drift_truncated
drift[]            {type: NEW|MODIFIED|GONE|TOOBIG|EXCLUDED|ERROR, path, note,
                    optional, dir}
unpushed, diverged, upstream_readable
remote             "configured" | "missing" | "none"
push_verifiable, push_reason
uncommitted[]      repo files the timer will not commit
timers_checked, timer_enabled, timer_active, timer_next,
selftest_enabled, selftest_active
problems[]         strings; any entry makes state "fault"
```

What the four late fields are for, since none of them was in the original list:

- `remote` is three-valued because git alone cannot tell a deliberate
  local-only install from an origin somebody removed. `configured` is an
  origin that exists, `none` is "empty to stay local" answered at setup, and
  `missing` is a URL the config records with no origin behind it, which is a
  fault: every commit since has gone nowhere.
- `upstream_readable` is false when the ahead count could not be read at all,
  so the widget can tell "nothing waiting" from "nobody knows".
- `optional` on a drift item is true when the allowlist entry behind a GONE
  row carries the `?` marker, so the popup can hide a "Mark optional" button
  that would do nothing. It is false, never absent, on every other class.
- `dir` on a drift item is the report's trailing slash, published rather than
  thrown away: allowing a folder decides for everything put in it later, and
  the popup says so only because it knows.

Severity: any `problems[]` entry is `fault`; else drift or uncommitted is
`attention`; else `ok`. `setup` other than `ready` shows the setup card in
place of the drift list and sets the glyph to attention, not fault.

Panel: bar glyph (quiet when ok, drift count when attention, alert triangle
when fault); popup with vitals (last snapshot age, next run with
pause/resume, push state, pending repo edits), drift triage grouped by
folder (biggest first, folder-level allow/ignore, caret to expand, GONE
rows offer remove and mark-optional, notes toggle), then Snapshot now, the
dynamic Push button, and Open terminal. Keys: `s` snapshot, `p` push,
`t` terminal, `n` notes toggle, `r` refresh, `Esc` close. Right-click on
the bar icon refreshes. Theme tokens only; every action keyboard-reachable.

## 6. Setup and removal

Triggered from the setup card or by running `omabackup setup`. A gum wizard
in a floating terminal, resumable (it records its phase in config), every
step idempotent:

1. **Tools.** Check git, rsync, jq, gum, systemd user session; check
   gitleaks and record its absence as "commits only, no push" rather than
   stopping.
2. **Data repo.** New (default `~/.local/share/omabackup/data`, `git init`,
   mode 700), adopt an existing engine repo (`--import DIR`: verifies the
   five list files and the three trees, writes the marker), or point at an
   existing empty repo.
3. **Seeds.** Copy the four `*.example` lists (Omarchy-stock entries only),
   `data.gitignore`, `gitleaks.toml`. Skipped when adopting.
4. **First scan.** Run `drift`, show counts by category, say "triage it from
   the bar". Never auto-allow anything.
5. **Remote.** Paste a URL, or create one with `gh repo create --private`
   when `gh auth status` succeeds, or skip (local only). For non-GitHub
   remotes ask the trust question with its consequence spelled out.
6. **Units.** Install the five unit files from `share/units/` with the
   configured calendar and jitter into `~/.config/systemd/user/`, enable
   `omabackup-snapshot.timer` (daily, `Persistent=true`, `RandomizedDelaySec`,
   `OnFailure=omabackup-failed.service`, no `SSH_AUTH_SOCK` assumed) and
   `omabackup-selftest.timer` (weekly, notify on failure).
7. **CLI.** Symlink `~/.local/bin/omabackup` to the plugin's `bin/omabackup`
   (outside the plugin tree, so the tree has no symlinks).
8. **Shell nag.** Offer the `.bashrc` line; default no.
9. **First snapshot.** Run `snapshot --no-push` in front of the user; enable
   the timer only after it succeeds.

`setup --remove` reverses 6, 7 and 8, deletes the config, and prints that
the data repo and its remote are untouched. `omarchy plugin remove` leaves
config and data alone; the README's Remove section says so and gives the
`setup --remove` command.

## 7. Secrets and remote

- **Allowlist is the model.** Nothing outside `allowlist.txt` is ever
  staged. `drift` exists to report the omissions.
- **Filename gate** always runs on the staging tree (`ghp_`, `gho_`,
  `github_pat_`, `AKIA`, `sk-ant-`, `BEGIN.*PRIVATE`, `id_*`, `*.pem`,
  `*.key`, `*.kdbx`, `hosts.yml`), written without a pipe so it cannot
  fail open on SIGPIPE.
- **gitleaks**, when installed: `gitleaks dir .staging` before sync and
  `gitleaks git --staged` on the commit, with `share/gitleaks.toml` (rules
  for Anthropic and Claude Code tokens, current OpenAI keys, WireGuard and
  NaCl keys, NetworkManager PSKs, credential URLs). Any hit dies before
  commit.
- **Without gitleaks**: the run commits locally, sets `push_verifiable`
  false with reason `gitleaks-missing`, and never pushes. The widget shows
  it; `setup check` names the package.
- **Visibility probe** for GitHub remotes on every push: `GET
  https://api.github.com/repos/OWNER/REPO` unauthenticated, after waiting
  up to 45 s for the network. 200 dies (public); 404 pushes; anything else
  commits and skips with `push_verifiable` false. `OWNER/REPO` is derived
  from the actual origin URL each run.
- **Non-GitHub or unprobeable remotes** push only when `remote.trusted` is
  true; otherwise commit and skip, `push_verifiable` false with reason
  `remote-unverified`.
- **Auth** is whatever git already has. The engine never reads, stores or
  passes a token. A deploy key with `core.sshCommand` is documented as an
  option for keyring-less setups.
- Push protection is not available on free private repos; the README says
  so in the Privacy section.

## 8. Fail-closed rules and notifications

Carried over from the engine, each with its test:

- Missing data repo, missing marker, unreadable last-run stamp, clock in
  the future, repo mid-rebase or mid-merge, stale `index.lock` without
  `fuser`: refuse, report.
- Floors from the previous commit: tracked `home/` file count at least half
  of last time (min 20); allowlist entries at least 90 % of last time.
- Missing allowlist entries: soft (`GONE`) below `maxMissingPct`, fatal at or
  above it; re-checked after 5 s for mid-migration renames.
- Symlink guards on the live tree: an entry that became a symlink to a
  directory, or a symlinked directory inside an entry, dies.
- Drift sentinel: the scan's last line is `# drift-scan-complete`;
  `snapshot` refuses to commit without it.
- Scan cost: a directory over `maxScanFiles` residual files is reported as
  one line at the highest directory holding only that blob.
- Manifests: placeholder values restore the previous copy rather than
  replacing real data.
- Normalize: a rule that empties a file dies; normalized JSON is re-parsed.
- Concurrency: one flock per data repo shared by snapshot, lint, verify and
  the write verbs; a timed-out wait is a warning and exit 0 (queue, do not
  skip silently).
- Two secret gates and the probe as in section 7.

Notifications (`omarchy-notification-send`, suppressed when
`notify` is false or `OMABACKUP_NOTIFY=0`): newly appearing drift only, once
per change signature; remote divergence once; timer failure and self-test
failure as critical via the `OnFailure` unit. The login nag (`health`) is
opt-in and repeats while the condition exists.

## 9. Tests and CI

- `tests/engine.test.sh`: the existing 52-group suite ported to black-box
  form. Each group builds what it needs under one throwaway directory:
  fixture HOME, stock stand-in, data repo, local bare remote; sets
  `OMABACKUP_CONFIG`, `OMABACKUP_STATE_DIR`, `OMABACKUP_STOCK_DIR`,
  `OMABACKUP_NET=0`, `OMABACKUP_NOTIFY=0`; calls `omabackup <verb> --json`;
  asserts on exit codes, JSON fields, files in the data repo and git state.
  It never reads `lib/` internals, so a library can be reimplemented behind
  the same verbs without touching a test. Secrets used as fixtures are
  assembled at run time.
- Every fail-closed rule in section 8 and every write-verb guard in
  section 4 has a group whose assertion is "the guard fired". The mutation
  rule from the engine stays in CONTRIBUTING: reintroduce a bug and the
  suite must go red.
- `self-test --real` adds the two groups that run `lint` and `verify`
  against the configured data repo; the weekly timer passes `--real`; CI
  does not.
- `tests/lint.sh`: shellcheck on `bin/` and `lib/`; manifest checks
  (schemaVersion, id, semver, kinds have entry points); CHANGELOG top
  release equals manifest version; no symlinks; `omarchy-plugin-validate`;
  QML has no `bash -c`, no `/tmp`, no empty files; README has Install,
  Update and Remove and the `omarchy plugin add` line; no em dashes in
  README, CHANGELOG, CONTRIBUTING, SECURITY or `--help` text.
- CI: one job on `archlinux:latest`, installs what Omarchy ships plus
  gitleaks, runs lint then the suite. `permissions: contents: read`.
- Second-model review: AGENTS.md (gitignored) with the review priorities;
  Codex on PRs that touch `lib/` or the widget contract.

## 10. Packaging and release

- `manifest.json` is the single version source; `omabackup version` reads
  it. Keep a Changelog format, SemVer, tags `vX.Y.Z`.
- Install: `omarchy plugin add https://github.com/huey-holdings-llc/omabackup --enable`,
  then the setup card. Update: `omarchy plugin update`. Remove: `omarchy
  plugin remove` plus `omabackup setup --remove`.
- LICENSE is MIT with the external-dependency note the marketplace asks for
  (gitleaks named as optional).
- Marketplace expectation: `review-required` because of the systemd units;
  the submission notes say why the timer exists and that the engine never
  runs as root and never reads outside the allowlist and `/etc`
  reference list.
- README shape follows OmaRecorder: lede, About this project (AI-assisted,
  part-time, fork it), Privacy and security, Prior art and thanks (from
  `docs/landscape.md`), What it does, Requirements table, Install, Update,
  Remove, Use, FAQ (opens with drift-detector, synchro, config-sync, dots,
  chezmoi), Troubleshooting, Development, Roadmap, License.

## 11. Data flow, one daily run

```
timer -> omabackup snapshot
  config load -> lock -> assert (repo, marker, clock, git state)
  -> stage (rsync each allowlist entry into .staging, excludes, size cap)
  -> manifests (generators with carry-forward) -> modes
  -> drift (scan vs stock and allowlist, sentinel) -> floors
  -> secrets (filename gate; gitleaks dir if present)
  -> normalize (sed on staged copies; safety checks)
  -> sync (rsync --delete .staging into home/ etc/ manifests/)
  -> git add home etc manifests modes.txt -> gitleaks git --staged if present
  -> commit if changed -> probe -> push or skip
  -> status.json written -> notifications on change -> unlock
widget: FileView sees status.json -> re-renders; buttons call verbs -> verbs write status.json
```

## 12. Migration of the owner's laptop

Gate: 1.0 tagged, CI green, and `omabackup verify` green against a fresh
clone of `hp-laptop-config` adopted with `setup --import` into a scratch
config. Then, on the laptop:

1. `omabackup setup --import ~/projects/hp-laptop-config --no-timers`
   (writes the marker, config, symlink; the old units keep running).
2. Run `omabackup snapshot --dry-run` and `omabackup self-test --real`
   until clean.
3. Disable `hp-laptop-config-*.timer`, enable the OmaBackup timers.
4. After seven daily snapshots and one weekly self-test: delete `bin/`,
   `systemd/`, `.claude/skills/backup-triage` and `docs/public-plugin.md`
   from `hp-laptop-config` in one commit; the repo is now a pure data repo.
5. Rollback at any point before step 4: re-enable the old timers.

The vault app note records each step.

## 13. Not in 1.0

Multi-machine sync and per-host profiles; a restore proven on fresh
hardware (README states it, as drift-detector does); update drift around
`omarchy update` (the first roadmap item, via a `post-update` hook and a
snapshot pair); encrypted secrets; a history grid; a graphical file picker
(crashes Quickshell on Omarchy 4). The roadmap lives in issues, with a
"Not planned" line in the README: this plugin never syncs, never runs as
root, never sends anything anywhere but the configured remote.
