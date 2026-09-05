# OmaBackup

OmaBackup snapshots your allowlisted Omarchy config into a private git repo
every day and tells you what it is not backing up. A daily scan reports
config that looks user-authored but is not covered by the allowlist, and the
engine refuses to push when it cannot prove the push is safe. Nothing leaves
your machine except a push to the private remote you chose.

![OmaBackup](preview.png)

## About this project

OmaBackup was built with AI assistance (Claude Code) by a hobbyist, not a
professional developer. Every effort was made to follow good practice
anyway: larger pull requests get a review from OpenAI Codex, requested by the
maintainer, every guard has a test that proves it fires, and every claim in
this README was checked against the code. Please read the
source with that in mind, and if you know better, open an issue or a pull
request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the principles the
project follows and a help-wanted list: other git hosts' visibility checks,
restore proven on real fresh hardware, drift categories for tools not yet in
the seed lists, popup accessibility, a second set of eyes on
`share/gitleaks.toml`.

This is a part-time project. Issues and pull requests are handled as time
allows, not on a schedule. If you need something sooner, fork it and make it
your own; the MIT license is there for exactly that.

## Privacy and security

The two allowlists are the model: nothing under `$HOME` outside
`allowlist.txt`, and nothing under `/etc` outside `etc-allowlist.txt`, is
ever staged, and the drift scan exists to report what those lists omit, not
to back anything up on its own.

* **Two secret gates.** A filename gate always runs on the staging tree,
  refusing credential-looking basenames (`ghp_`, `gho_`, `github_pat_`,
  `AKIA...`, `sk-ant-...`, a private-key header, `id_*`, `*.pem`, `*.key`,
  `*.kdbx`, `hosts.yml`). When gitleaks is installed, it also scans the
  staging tree and the staged commit with a project rules file covering
  Anthropic and Claude Code tokens, current OpenAI keys, WireGuard and NaCl
  keys, NetworkManager pre-shared keys and credential-embedded URLs. Either
  gate finding something stops the commit before it happens.
* **A visibility probe before every push.** For a GitHub remote, OmaBackup
  asks `https://api.github.com/repos/OWNER/REPO`, unauthenticated, after
  waiting for the network to come up. The remote counts as GitHub by its
  host, whatever the URL's spelling (scheme, `user@`, port and case are all
  normalised), and the owner/repo it asks about has to be exactly that, so a
  URL it cannot reduce to one is treated as unverifiable and never probed.
  An HTTP 200 is the only proof the repo is public, and the run refuses
  outright; a 404 is proof it is private and the push goes ahead; anything
  else (rate-limited, an outage) commits locally and skips the push rather
  than guessing. The probe is only worth anything if git pushes where it
  fetches, so a `remote.origin.pushurl` that differs from the fetch URL
  refuses the push until you remove it
  (`git config --unset remote.origin.pushurl`).
* **An explicit trust flag for everything else.** A remote that is not on
  GitHub cannot be probed this way, so it is only ever pushed to once you
  mark it trusted, either at setup or by editing `remote.trusted` yourself.
  `--trust-remote` refuses a GitHub host outright: that one is verified
  automatically, and trusting it would only mean skipping the probe on a repo
  that might be public. That trust belongs to one remote: it counts only
  while `remote.url` still names the repo's current origin, so repointing
  origin by hand stops the pushes until you rerun
  `omabackup setup --trust-remote`.
  Push protection is not available on free private repos, so a private
  GitHub repo is still worth double-checking by hand.
* **No token ever touches this tool.** Push authentication is whatever git
  already has configured (SSH key, credential helper, a deploy key); the
  engine never reads, stores or passes one.
* **What it writes, and what it only reads.** OmaBackup reads your Omarchy
  and Hyprland config; it never edits either. Outside that, it writes to a
  known, short list of places: the data repo it owns; its own config
  (`~/.config/omabackup/config.json`) and state files; the five unit files
  it installs into `~/.config/systemd/user/`; the `~/.local/bin/omabackup`
  symlink; one opt-in line appended to `~/.bashrc`, offered at setup and
  added only if you say yes (`setup --remove` takes that line back out again,
  along with the timers, the symlink and the config, and leaves the rest of
  your `.bashrc` byte for byte as it was); and your `$HOME` itself, but only
  when you run `restore --apply`.

## Prior art and thanks

* [omarchy-drift-detector](https://github.com/Abhishek-1804/omarchy-drift-detector)
  for the framing "what have I done to this machine that a fresh Omarchy
  install wouldn't have?", the package baseline from Omarchy's own install
  lists, and the JSON restore plan. If you want a restore on a fresh
  machine today, use it.
* [config-sync](https://github.com/gladimdim/omarchy-config-sync-plugin) for
  putting config in the bar in the first place, and for drawing the line
  between sync and backup that this plugin sits on the other side of.
* The Omarchy [dots](https://github.com/omacom/omarchy/blob/quattro/plans/dots.md)
  and [backup](https://github.com/omacom/omarchy/blob/quattro/plans/backup.md)
  plans, for the hermetic-git rules, the snapshot pairs around migrations,
  and the one-state-file panel pattern.
* [Omaudit Status](https://github.com/godhiraj-code/omarchy-omaudit-status)
  for the rule that a status indicator must refuse to lie, and for bounding
  output before parsing it.
* [omarchy-backup-history](https://github.com/POSO-PocketSolutions/omarchy-backup-history)
  for reading backup health from the systemd journal.
* [omarchy-backup](https://github.com/DigitalPals/omarchy-backup) (DigitalPals)
  for delegating authentication to `gh` and never storing a token.
* [omarchy-synchro](https://github.com/harel/omarchy-synchro) for marking
  every allowlist entry portable or device-specific, and for a restore report
  that lists the excluded secrets and the manual steps.
* [config-prism](https://github.com/AdamMusa/omarchy-config-prism) for the
  "newly packaged" class: a stock file that appeared after your config was
  written.
* [syncshell](https://github.com/omarchy-QOL/syncshell) for the service and
  panel split and its test suite.
* [OmaRecorder](https://github.com/huey-holdings-llc/omarecorder), the
  sibling plugin whose README, principles and lint gate this one copies.

## What it does

* **Daily snapshot**: `omabackup snapshot` stages every allowlisted path,
  generates manifests, checks the floors and the secret gates, and commits
  to the data repo; the timer runs it once a day with jitter, and pushes
  when the visibility probe or the trust flag says it can.
* **Drift report, five categories**: `omabackup drift` walks `$HOME` (and,
  unless skipped, `/etc`) for config that looks user-authored but is not
  covered by the allowlist: `NEW` (no stock counterpart), `MODIFIED`
  (differs from Omarchy's stock default), `GONE` (an allowlist entry that no
  longer resolves, whether marked optional or simply under the missing-entry
  threshold), `TOOBIG` (over the size cap), `EXCLUDED` (matched `.gitignore`
  after staging).
* **Popup triage**: `NEW` files grouped by folder, biggest first; one click
  Allows or Ignores a whole directory (folder targets are refused at depth
  one, so `~/.config/` can never be silenced by accident), a caret expands a
  folder to single files, `GONE` rows offer Remove or Mark-optional, and a
  notes toggle switches Ignore between a dated default reason and asking for
  one.
* **Fail-closed guards**: a large fraction of allowlist entries vanishing at
  once (a few missing is recorded as `GONE` and the run continues; at or
  above `maxMissingPct` it refuses), a floor breach (staged files or
  allowlist entries dropping far below the last commit), a symlinked
  directory inside the backup, an `index.lock` that cannot be proven
  abandoned, a repo mid-merge or mid-rebase, a drift scan that did not
  finish, and a confirmed-public remote all refuse the run instead of
  committing something smaller or unverifiable.
* **Manifests**: packages, systemd services, Omarchy plugin clones, dconf,
  printers, timezone, locale and more, each guarded so a tool that is not
  installed writes a documented placeholder instead of erasing yesterday's
  copy under `rsync --delete`.
* **Restore, dry run by default**: `omabackup restore --configs|--etc
  |--packages|--plugins|--services|--all` reports what it would do; only
  `--apply` writes, nothing is ever deleted, and anything about to be
  overwritten is copied aside first. `--etc` only ever diffs, never writes.
* **Verify**: `omabackup verify` restores the committed backup into a
  throwaway directory and compares every file, symlink target and mode
  against the live one, honouring the normalize exceptions. Both `verify` and
  `restore --configs` read the data repo's working tree, so both refuse while
  `home`, `etc`, `manifests` or `modes.txt` hold uncommitted changes: that is
  the signature of a run that copied your config in and never committed it.
* **Self-test**: a weekly timer re-runs the black-box test suite end to end;
  `--real` also runs `lint` and `verify` against your actual data repo.

## Requirements

Four tools are hard requirements: without `git`, `rsync`, `jq` or `flock` the
CLI refuses to set up at all. Everything else below is used when it is there
and skipped, or reported, when it is not.

**Required**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `git` | `git` | the data repo: commits, remotes, pushes | yes |
| `rsync` | `rsync` | staging config into the repo and restoring it back | yes |
| `jq` | `jq` | every JSON object the CLI reads or writes | yes |
| `flock` | `util-linux` | one snapshot (or lint, or verify) at a time | yes |

**Strongly recommended**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `gitleaks` | `gitleaks` | the content secret scan. Without it nothing is ever pushed | no, `pacman -S gitleaks` |
| `systemd` (`systemctl`) | `systemd` | the snapshot and self-test timers, and the services manifest | yes |
| `gum` | `gum` | the setup wizard's prompts (without it every prompt takes its default) | yes |

**Used when present**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `curl` | `curl` | the GitHub visibility probe: is the remote really private? | yes |
| `nm-online` | `networkmanager` | waiting briefly for the network before that probe | yes |
| `fuser` | `psmisc` | proving an abandoned `.git/index.lock` really is abandoned | yes |
| `setsid` | `util-linux` | starting a snapshot, or a terminal, detached from the widget | yes |
| `python3` | `python` | re-parsing a normalized JSON file to prove the rule did not break it | yes |
| `xdg-terminal-exec` or `omarchy-launch-floating-terminal-with-presentation` | `xdg-terminal-exec`, Omarchy | the popup's "open a terminal in the data repo" button | yes |
| `wl-copy` | `wl-clipboard` | copying the gitleaks install command from the setup card | yes |
| `omarchy-notification-send` or `notify-send` | Omarchy, `libnotify` | desktop notifications for a failed or diverged run | yes |
| `gh` | `github-cli` | `setup --create-private` only | no, optional |

**Manifest generators.** The daily run records facts about the machine using
`pacman`, `dconf`, `nmcli`, `lpstat`, `timedatectl`, `localectl`,
`fprintd-list`, `code`, `uv` and `npm`. Every one of them is optional: a tool
that is not installed writes a documented placeholder, and the previous
committed copy is carried forward rather than deleted.

**`restore --packages --apply` runs a package manager as root.** It calls
`sudo pacman -S --needed` for native packages and `yay -S --needed` for AUR
packages, and prompts you the way those tools normally do. Nothing else in
OmaBackup ever uses `sudo`; the dry run (no `--apply`) only prints what it
would install.

`omabackup setup check` names anything missing from the first two tables and
the package that provides it.

## Install

```bash
omarchy plugin add https://github.com/huey-holdings-llc/omabackup --enable
```

Then open the bar widget and press "Set up OmaBackup", or run
`omabackup setup` yourself. You will be asked where the data repo should
live and for a remote to push to (or to stay local only). To adopt an
existing engine repo instead of creating a new one, run
`omabackup setup --import DIR` (adoption is a flag, not a wizard prompt).

## Update

```bash
omarchy plugin update io.github.huey-holdings-llc.omabackup
```

## Remove

```bash
omarchy plugin remove io.github.huey-holdings-llc.omabackup
omabackup setup --remove
```

`omarchy plugin remove` alone leaves the config, the timers, the CLI symlink
and the `~/.bashrc` login check behind; `setup --remove` disables and deletes
the timers, the `~/.local/bin/omabackup` symlink,
`~/.config/omabackup/config.json`, and the two-line login check it added to
`~/.bashrc` (nothing else in that file is touched). Your data repo and its
remote are never touched by either command.

## Use

### Where things live

| What | Where |
|---|---|
| Config | `~/.config/omabackup/config.json` (0600, written by setup) |
| State | `~/.local/state/omabackup/status.json` (the widget's view) and `omabackup.log` (rotated at 1 MB) |
| Data repo | wherever setup put it, default `~/.local/share/omabackup/data` |

The data repo itself:

```
allowlist.txt        paths under $HOME to back up, one per line
drift-ignore.txt     paths deliberately not backed up, with a dated reason
etc-allowlist.txt    /etc paths kept as reference copies only, never restored
normalize.txt        self-changing fields neutralized before every commit
modes.txt            file and directory permissions, replayed on restore
home/                the mirrored config itself (mode 700)
etc/                 the reference copies named in etc-allowlist.txt
manifests/           generated facts about the machine, plus drift.txt
.gitignore           belt-and-braces excludes, copied from share/ at setup
.gitleaks.toml       the secret-scan rules, copied from share/ at setup
.omabackup           marker: {"format": 1, "createdBy": "<version>"}
```

`allowlist.txt` entries are directories (recursive) or files, relative to
`$HOME`, and support shell globs; a leading `?` marks an entry optional, so
its absence is recorded as `GONE` instead of halting the snapshot.
`drift-ignore.txt` entries take the form `path   # YYYY-MM-DD reason`; a bare
path ignores exactly that entry, and `path/**` ignores the whole subtree
(only ever add `/**` when nothing under that path will ever matter, since a
bare ignore still lets the scanner look at the path's children).
`etc-allowlist.txt` lines are full `/etc/...` paths. `normalize.txt` lines
are `<staged path glob><TAB><sed expression>`, applied to the staged copy
before it is hashed and committed. Both halves are treated as data, never as
a program: the path must be relative to the staging root with no `..` segment
and is re-checked after the glob expands, and the expression runs under
`sed --sandbox`, which refuses the `e`, `r` and `w` commands outright, so a
rule can never run a shell command or read and write a file of its own.
`omabackup lint` reports either problem as `BADRULE`, and the snapshot
refuses the run.

### CLI

```
omabackup <verb> [args] [--json]

  setup [--data-repo DIR] [--remote URL] [--create-private] [--import DIR]
        [--trust-remote] [--no-timers] [--yes]     first-run wizard
  setup check                                       doctor
  setup --remove                                    remove units, symlink, config
  snapshot [--dry-run] [--no-push]                  the daily pipeline
  drift                                             report unbacked config
  status                                            health (writes status.json)
  allow PATH | ignore PATH [REASON]                 triage a drift entry
  resolve-gone PATH remove|optional                 fix a vanished entry
  push [--confirm]                                  push commits (lists need --confirm)
  lint [--no-walk]                                  list hygiene
  restore --configs|--etc|--packages|--plugins|--services|--all [--apply]
  verify                                            restore fidelity check
  health                                            login check (silent when ok)
  timer pause|resume|status|run
  self-test [--real]
  open                                              terminal in the data repo
  version
```

Every verb accepts `--json`, which prints exactly one JSON object, even on
failure. Exit codes: 0 ran, 1 refused or unhealthy, 2 usage.

### Popup keys

| Key | Action |
|---|---|
| `s` | Snapshot now |
| `p` | Push, or open the commit confirmation if the lists are dirty |
| `t` | Open a terminal in the data repo |
| `n` | Toggle ask-for-a-reason mode on Ignore |
| `r` | Refresh |
| `Esc` | Close |

Right-click the bar icon to refresh without opening the popup. The bar shows
a quiet glyph when everything is healthy, a drift count when something needs
triage, and an alert triangle when a guard has actually fired.

## FAQ

**How is this different from omarchy-drift-detector?**
Same private repo, same bar, different question. drift-detector answers
"what have I changed from a fresh Omarchy install", on demand, and can
replay the answer onto a new machine. OmaBackup answers "what am I not
backing up", every day without being asked, and refuses to push when it
cannot prove the push is safe. drift-detector is the better tool for
rebuilding a machine today; OmaBackup is the one that nags you about the
config folder you forgot. Run both if you like; they do not fight.

**How is this different from omarchy-synchro?**
Closest cousin on the capture side: both use an explicit allowlist and
exclude secrets by name and content. synchro is preview-first and manual by
design, and it trusts the allowlist. OmaBackup runs on a timer and does not
trust the allowlist: the daily scan exists to find what the list forgot.

**How is this different from config-sync?**
config-sync keeps two Omarchy machines the same. OmaBackup keeps one machine
recoverable and tells you where the gaps are. Sync copies what it is told
to; backup has to find out what it was not told about.

**Omarchy is planning `omarchy dots`. Why not wait?**
The plan is a good one and OmaBackup borrows from it. It is also
unimplemented, it tracks a fixed manifest, and by design it has no command
that adds to that manifest and no scan for what the manifest misses. When
it lands, OmaBackup's scanner is the thing that tells you what dots is not
keeping.

**Why not chezmoi or Stow?**
Stow and every other symlink manager silently detaches when an Omarchy
migration rewrites a config in place; the dots plan says as much and goes
dormant for those users. chezmoi copies, which is fine, but it cannot tell
you about a file it does not manage, and its maintainer has declined to add
that. OmaBackup's whole job is the file nobody told it about.

**Why is push off?**
One of three reasons, all visible in the setup card or `setup check`:
gitleaks is not installed (commits happen, nothing pushes until it is);
the remote could not be verified private (a non-GitHub remote you have not
marked trusted, or a GitHub probe that came back inconclusive); or the
remote turned out to be public, in which case the whole run refuses rather
than pushing anywhere.

**What does the alert triangle mean?**
Any entry in `problems[]`, things a plain drift count cannot express: no
drift report at all, a scan that did not finish, a repo mid-merge, commits
that cannot be verified as pushed, a remote that has diverged, or a timer
that is not armed. A drift count on its own (files waiting on your
decision) is the calmer "attention" state; the triangle means something is
actually broken.

## Troubleshooting

* **No `status.json` yet**: it is written by `status` and by every verb that
  changes state. Run `omabackup setup` if you have not, then `omabackup
  status` to write one on demand.
* **Timer not enabled**: `setup check` shows `units.snapshot` and
  `units.selftest`; re-run `omabackup setup` (it is idempotent) or
  `systemctl --user enable --now omabackup-snapshot.timer` by hand.
* **A stale `.git/index.lock`**: OmaBackup clears it on its own once `fuser`
  confirms nothing is actually using it; if `fuser` is not installed, or it
  says a process still holds the lock, the run refuses rather than guessing
  and tells you so.
* **The remote turned out to be public**: the visibility probe treats an
  HTTP 200 as proof and refuses the whole run, not just the push. Make the
  repo private, or point `remote.url` at a different one.
* **gitleaks missing**: snapshots still commit locally, they just never
  push; `setup check` prints the exact `pacman -S gitleaks` to fix it.

## Development

```bash
git clone https://github.com/huey-holdings-llc/omabackup ~/projects/omabackup
cd ~/projects/omabackup
scripts/dev-install.sh --enable   # rsync into the plugin dir, symlink the CLI, rescan plugins
bash tests/lint.sh                # shellcheck, manifest schema, QML hygiene, README sections
bash tests/engine.test.sh         # the black-box suite against throwaway fixtures
OMABACKUP_TEST_GROUP=07 bash tests/engine.test.sh   # run one group only
```

Tests are black-box: each group builds its own throwaway home directory,
stock-config stand-in, data repo and local bare remote, then drives
`bin/omabackup` directly and asserts on exit codes, JSON and git state, never
on `lib/` internals. Test-only environment hooks, documented here because
they only ever matter to that harness: `OMABACKUP_CONFIG`,
`OMABACKUP_STATE_DIR`, `OMABACKUP_STOCK_DIR` (a stand-in for
`/usr/share/omarchy`), `OMABACKUP_ETC_ROOT` (keep the real `/etc` out of a
fixture), `NET_WAIT` (how many seconds `nm-online` may wait),
`OMABACKUP_NOTIFY=0`, `OMABACKUP_SKIP_TIMERS=1` (never touch the real
`systemctl --user`), and `OMABACKUP_LOCK_WAIT`.

Six more hooks weaken a guard rather than redirect a path, so they take
effect **only when `OMABACKUP_IN_SUITE=1` is set too**, which the suite
exports at its own top: `OMABACKUP_MIN_FILES` and `OMABACKUP_MIN_ALLOWLIST`
(the derived snapshot floors), `OMABACKUP_MIN_RESTORE` (the floor
`restore --configs` refuses below), `OMABACKUP_NET=0` (skip the visibility
probe entirely), and `OMABACKUP_SKIP_ETC=1` / `OMABACKUP_SKIP_DROPINS=1`
(skip the `/etc` half of the drift scan). Without the marker they are
ignored, and `status` reports a problem naming every one it found, so the
widget shows a fault. A `systemd --user` unit inherits the user manager's
environment, so any of these set once in `~/.config/environment.d` or
`.bashrc` would otherwise have reached the daily timer forever with nothing
saying so.

Design docs: [docs/superpowers/specs/2026-09-03-omabackup-design.md](docs/superpowers/specs/2026-09-03-omabackup-design.md)
and [docs/superpowers/plans/2026-09-03-omabackup-1.0.md](docs/superpowers/plans/2026-09-03-omabackup-1.0.md).
Contribution principles: [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

The roadmap lives in the
[issue tracker](https://github.com/huey-holdings-llc/omabackup/issues).

Not planned: syncing two machines, and sending anything anywhere but the
remote you configured. It is also not designed or tested to run as root.

## License

MIT, see `LICENSE`.
