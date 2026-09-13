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
maintainer, every guard has a test that proves it fires, and every behaviour
this README describes has a test or a line of code behind it. Please read the
source with that in mind, and if you know better, open an issue or a pull
request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the principles the
project follows and a help-wanted list: other git hosts' visibility checks,
restore proven on real fresh hardware, drift categories for tools not yet in
the seed lists, popup accessibility beyond the button names (keyboard focus
order, and someone who actually uses a screen reader trying it), a second set
of eyes on `share/gitleaks.toml`.

This is a part-time project. Issues and pull requests are handled as time
allows, not on a schedule. If you need something sooner, fork it and make it
your own; the MIT license is there for exactly that.

## Privacy and security

The two allowlists are the model: nothing under `$HOME` outside
`allowlist.txt`, and nothing under `/etc` outside `etc-allowlist.txt`, is
ever staged, and the drift scan exists to report what those lists omit, not
to back anything up on its own.

* **Two secret gates.** A filename gate always runs on the staging tree,
  refusing credential-looking basenames: the classes
  `share/data.gitignore` names (`id_*` except `id_*.pub`, `*.pem`, `*.key`,
  `*.p12`, `*.pfx`, `*.kdbx`, `*.ovpn`, `*.jks`, `*.asc`, `.env`, `.env.*`,
  `.netrc`, `.git-credentials`, `.npmrc`, `.pypirc`, `.credentials.json`,
  `credentials`, `Cookies*`, `hosts.yml`) plus token prefixes (`ghp_`,
  `gho_`, `github_pat_`, `AKIA...`, `sk-ant-`, `sk-proj-`, `glpat-`, `xoxb-`
  and friends, `AIza`, `hf_`, `npm_`, `dop_v1_`, `SG.`, and a private-key
  header). Two of these refuse more than you may expect, on purpose, because
  a filename cannot tell you whether the secret is real: `.env.*` covers
  `.env.example` (a template that has been filled in looks exactly like a
  template that has not), and `*.asc` covers an armoured PUBLIC key or a
  detached signature as readily as an armoured private one. The cost of a
  wrong refusal is renaming one file, or listing the path in
  `drift-ignore.txt` and keeping it out of the backup. When gitleaks is
  installed, it also scans the staging tree and the staged commit with a
  project rules file covering Anthropic and Claude Code tokens, current
  OpenAI keys, WireGuard and NaCl keys, NetworkManager pre-shared keys and
  credential-embedded URLs. Either gate finding something stops the commit
  before it happens.
* **A visibility probe before every push.** For a GitHub remote, OmaBackup
  asks `https://api.github.com/repos/OWNER/REPO`, unauthenticated, after
  waiting for the network to come up. The remote counts as GitHub by its
  host, whatever the URL's spelling (scheme, `user@`, port and case are all
  normalised), and the owner/repo it asks about has to be exactly that, so a
  URL it cannot reduce to one is treated as unverifiable and never probed.
  An HTTP 200 is the only proof the repo is public, and the run refuses
  outright; a 404 means the repo is private or does not exist yet, and the
  push goes ahead (a push to a repo that is not there fails on its own);
  anything
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
  symlink; a three-line login check appended to `~/.bashrc` (a blank line, a
  comment naming OmaBackup, and the command), offered at setup and
  added only if you say yes (`setup --remove` takes those lines back out again,
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
* **Drift report, six categories**: `omabackup drift` walks `$HOME` (and,
  unless skipped, `/etc`) for config that looks user-authored but is not
  covered by the allowlist: `NEW` (no stock counterpart), `MODIFIED`
  (differs from Omarchy's stock default), `GONE` (an allowlist entry that no
  longer resolves, whether marked optional or simply under the missing-entry
  threshold), `TOOBIG` (over the size cap), `EXCLUDED` (matched `.gitignore`
  after staging), and `ERROR` (a part of the scan that could not run, so the
  count is a floor and not a total). An `ERROR` row is the one class that
  says the report itself cannot be trusted, so it is always a problem, never
  just a number to triage.
* **Popup triage**: `NEW` files grouped by folder, biggest first; one click
  Allows or Ignores a whole directory (folder groups are only formed two
  segments deep or more, because a depth-one target is refused so
  `~/.config/` can never be silenced by accident), a caret expands a
  folder to single files, `MODIFIED` rows carry the same Allow/Ignore pair,
  `TOOBIG` and `EXCLUDED` rows carry a line naming the limit holding the file
  and offer Ignore alone (both are already allowlisted, so Allow lifts
  neither limit), `ERROR` rows carry a line and no buttons at all,
  `GONE` rows offer Remove or Mark-optional (the
  second only while the entry is not already optional; every seed entry is,
  so on a fresh machine those rows offer Remove alone), and a notes toggle
  switches Ignore between a dated default reason and asking for one.
* **Fail-closed guards**: a large fraction of allowlist entries vanishing at
  once (a few missing is recorded as `GONE` and the run continues; at or
  above `maxMissingPct` it refuses, counting every entry this repo has ever
  backed up and $HOME no longer has, optional ones included, so erosion a
  little at a time still adds up and a second machine's first run is guarded
  too; clear it with `omabackup resolve-gone <path> remove` for each entry
  that is gone for good, or by editing `allowlist.txt` and committing it),
  a producer whose
  output the `/etc` scan cannot parse, a floor breach (staged files or
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
  |--packages|--plugins|--services|--all` reports what it would do, and
  `--configs` names the first 20 paths it would write (the other stages list
  what they would install or enable); only `--apply` writes, and nothing is
  removed without first being copied aside to `<path>.bak.<epoch>`, which is
  excluded from future snapshots. A run that made such copies says how many
  and where. `--etc` only ever diffs, never writes.
* **Verify**: `omabackup verify` restores the committed backup into a
  throwaway directory and compares every file, symlink target and mode
  against the live one, honouring the normalize exceptions. Both `verify` and
  `restore --configs` read the data repo's working tree, so both refuse while
  `home`, `etc`, `manifests` or `modes.txt` hold uncommitted changes: that is
  the signature of a run that copied your config in and never committed it.
* **Self-test**: a weekly timer runs `self-test --real`, which is the
  black-box test suite end to end plus two groups that run `lint` and
  `verify` against your actual data repo. A run that fails tells you to
  re-run it by hand; a run the timer had to stop says only that it ran out of
  time.

## Requirements

Four tools are hard requirements: without `git`, `rsync`, `jq` or `flock` the
CLI refuses to set up at all. Not listed, because a system without them is not
a system: `bash` 4.4 or newer and the `coreutils`, `findutils`, `grep`, `sed`,
`gawk` and `diffutils` programs every Arch install already has. Everything
else below is used when it is there and skipped, or reported, when it is not.

**Required**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `git` | `git` | the data repo: commits, remotes, pushes | yes |
| `rsync` | `rsync` | staging config into the repo and restoring it back | yes |
| `jq` | `jq` | every JSON object the CLI reads or writes | yes |
| `flock` | `util-linux` | one snapshot, lint, verify, restore or list edit at a time | yes |

**Strongly recommended**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `gitleaks` | `gitleaks` | the content secret scan. Without it nothing is ever pushed | no, `pacman -S gitleaks` |
| `systemd` (`systemctl`) | `systemd` | the snapshot and self-test timers, and the services manifest | yes |
| `gum` | `gum` | the setup wizard's prompts. Without it, text prompts take their default and yes/no gates answer no, so `setup --remove` needs `--yes` | yes |

**Used when present**

| Tool | Package | Used for | In Omarchy 4 |
|---|---|---|---|
| `curl` | `curl` | the GitHub visibility probe: is the remote really private? | yes |
| `nm-online` | `networkmanager` | waiting briefly for the network before that probe | yes |
| `fuser` | `psmisc` | proving an abandoned `.git/index.lock` really is abandoned | yes |
| `setsid` | `util-linux` | starting a snapshot, or a terminal, detached from the widget | yes |
| `python3` | `python` | re-parsing a normalized JSON file to prove the rule did not break it | yes |
| `omarchy-launch-floating-terminal-with-presentation` or `xdg-terminal-exec` | Omarchy, `xdg-terminal-exec` | the popup's "open a terminal in the data repo" button (the Omarchy launcher is preferred) | yes |
| `wl-copy` | `wl-clipboard` | copying the gitleaks install command from the setup card | yes |
| `omarchy-launch-browser` or `xdg-open` | Omarchy, `xdg-utils` | `open --remote`: the backup repository's page on GitHub (the Omarchy launcher is preferred) | yes |
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

`omabackup setup check` is the doctor: one line per check, in one of three
shapes.

| Shape | Means |
|---|---|
| `ok    <check>` | nothing to do |
| `warn  <check>: <what is wrong>. Fix: <command>` | something is wrong and OmaBackup still runs |
| `FAIL  <check>: <what is wrong>. Fix: <command>` | something is wrong that stops it |

A `FAIL` line is what makes the verb exit 1, so an exit of 0 means there was
no `FAIL` line. It covers the tools in the first two tables, the config, the
data repo (with its path) and its marker, the two timers and the remote, and
every line that is not `ok` carries the command that fixes it, its own
`pacman -S <package>` included. `setup check --json` prints the same answers
as one object for the widget.

## Install

```bash
omarchy plugin add https://github.com/huey-holdings-llc/omabackup --enable
```

Then open the bar widget and press "Set up OmaBackup", or run
`omabackup setup` yourself. You will be asked where the data repo should
live and for a remote to push to (or to stay local only, which is a
supported answer: with no remote at all the widget says "Remote: none (local
only)" and stays green, and only a remote that exists and cannot be verified
is reported as a problem). To adopt an existing engine repo instead of
creating a new one, run `omabackup setup --import DIR` (adoption is a flag,
not a wizard prompt).

## Update

```bash
omarchy plugin update io.github.huey-holdings-llc.omabackup
```

## Remove

```bash
omabackup setup --remove
omarchy plugin remove io.github.huey-holdings-llc.omabackup
```

**In that order.** `~/.local/bin/omabackup` is a symlink into the plugin
directory, so removing the plugin first leaves it dangling and `omabackup
setup --remove` can no longer be run at all: the timers, the config and the
`~/.bashrc` line stay behind, and the failure notifier execs the same dead
path, so a failing daily backup says nothing. (If it has already happened,
run `setup --remove` from a checkout of this repo: `bash bin/omabackup setup
--remove`.)

`setup --remove` disables and deletes the timers, the
`~/.local/bin/omabackup` symlink, `~/.config/omabackup/config.json`, and the
three-line login check it added to `~/.bashrc` (nothing else in that file is
touched). It asks first; with no `gum` to ask with, pass `--yes`. Your data
repo and its remote are never touched by either command.

## Use

### Where things live

| What | Where |
|---|---|
| Config | `~/.config/omabackup/config.json` (0600, written by setup) |
| State | `~/.local/state/omabackup/status.json` (the widget's view) and `omabackup.log` (rotated at 1 MB) |
| Data repo | wherever setup put it, default `~/.local/share/omabackup/data` |

The config file is plain JSON and every key has a default, so a file that
names only `dataRepo` is complete. A key this version does not know is
warned about; one close enough to a known key to be a typo is refused.

```
dataRepo         absolute path of the data repo (written by setup)
remote.url       the data repo's origin, kept in step with git by setup
remote.trusted   false; true lets a non-GitHub remote be pushed to without
                 the visibility probe (GitHub remotes are always probed)
maxFileSize      8m; an allowlisted file above it is listed, not copied
staleDays        2; a last snapshot older than this is a problem, and a
                 push verdict older than this counts as unprobed
maxMissingPct    25; this share of allowlist entries or more vanishing at
                 once refuses the run
maxScanFiles     2000; a folder with more files than this is one collapsed
                 row in the drift report
notify           true; false silences the desktop notifications
shellNag         false; true makes setup add the login check to ~/.bashrc
timer.calendar   daily; the snapshot timer's OnCalendar
timer.jitter     30m; its RandomizedDelaySec
setupPhase       setup's own resume marker, not something to edit
```

Edits take effect on the next run, with two exceptions that only setup reads.
`timer.*` is written into the unit files, so rerun `omabackup setup --yes`
after changing it; no other verb validates it, so a bad value is only ever
caught there, and by `omabackup setup check`, never by another verb along
the way (`status` still reads `timer.calendar` back out of config to compare
it against the installed unit, just without checking it against systemd's
grammar).
`shellNag` set to true adds the login check the next time
setup runs; set back to false it removes nothing, so take the two lines under
the OmaBackup comment out of `~/.bashrc` yourself (`setup --remove` does,
but it uninstalls everything else too).

The data repo itself, whose root and `.git` are kept at mode 700 (setup sets
both, and every verb re-asserts them, since `.git` holds the whole backup in
full history):

```
allowlist.txt        paths under $HOME to back up, one per line
drift-ignore.txt     paths deliberately not backed up, with a dated reason
etc-allowlist.txt    /etc paths kept as reference copies only, never restored
normalize.txt        self-changing fields neutralized before every commit
modes.txt            file and directory permissions, replayed on restore
home/                the mirrored config itself (mode 700)
etc/                 the reference copies named in etc-allowlist.txt
manifests/           generated facts about the machine, plus drift.txt
.gitignore           belt-and-braces excludes, copied from share/ at setup; the next
                     snapshot after an upgrade appends the patterns the newer
                     version ships and commits them
.omabackup           marker: {"format": 1, "createdBy": "<version>"}
                     a marker whose format is HIGHER than this version knows
                     is refused, never rewritten, so the newer machine in a
                     synced pair keeps working
```

A repo set up before 0.7.0 also holds a `.gitleaks.toml` that an older setup
copied in. Nothing reads it: the content scan always runs with the plugin's
own `share/gitleaks.toml`, so a rule added to the repo copy never took effect
in either direction. The copy is inert, and deleting it changes nothing. A
`.gitleaksignore` in the repo is the one exception, on purpose: the scan
reads it, one fingerprint per finding you have decided is not a secret (see
Troubleshooting), so it can excuse a finding but never switch off a rule.
Whichever you choose, commit it: the file is tracked, no verb commits it for
you, and either an edit or a deletion left in the working tree is an
uncommitted edit `status` reports at every login. To be rid of it:

```bash
git -C <data repo> rm .gitleaks.toml
git -C <data repo> commit -m "drop the inert rules copy"
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

The config file is read the same way. A key this version does not recognise is
ignored with a warning, so a config written (or synced) by a newer OmaBackup
does not stop an older one; a key that reads as a typo of a known one is
refused instead, because a misspelled `maxMissingPct` is a threshold you
believe is set and is not. `timer.calendar` and `timer.jitter` are checked with
`systemd-analyze calendar` and `systemd-analyze timespan` in `omabackup setup`,
right before they reach a unit file, and `omabackup setup check` reports the
same check as a doctor line. A machine with no `systemd-analyze` at all
refuses the same way, since neither value can be proved valid without it;
`setup --no-timers` is the way to finish setup on one. `status` reports it
separately when the installed snapshot timer and the config disagree
(editing the config alone changes nothing until you rerun `omabackup
setup`).

### CLI

```
omabackup <verb> [args] [--json]

  setup [--data-repo DIR] [--remote URL] [--create-private] [--import DIR]
        [--trust-remote] [--no-timers] [--yes]      first-run wizard
  setup check                                       doctor
  setup --remove [--yes]                            remove units, symlink, config
  snapshot [--dry-run] [--no-push]                  the daily pipeline
  drift                                             report unbacked config
  status                                            health (writes status.json)
  allow PATH | ignore PATH [REASON]                 triage a drift entry
  resolve-gone PATH remove|optional                 fix a vanished entry
  push [--confirm [SIG]]                            push commits (repo edits need --confirm)
  lint [--no-walk]                                  list hygiene
  restore --configs|--etc|--packages|--plugins|--services|--all [--apply]
  verify                                            restore fidelity check
  health                                            login check (silent when ok)
  timer pause|resume|status|run
  self-test [--real]
  open [--report|--remote]                          a terminal in the data repo, the drift report, or its page on GitHub
  version
```

Every verb also accepts `--help` (or `-h`) as its first argument and answers
with its own lines from the block above, so you never have to read the whole
list to remember one verb's flags.

Every verb accepts `--json`, which prints exactly one JSON object, even on
failure. One caveat: `jq` is what builds that object, so on a machine without
it the CLI prints one plain line and exits 1 before any verb runs. Without
`--json` the triage verbs (`allow`, `ignore`, `resolve-gone`, `push`, `timer`,
`open`) print one plain line saying what happened, such as `allowed
~/.config/mytool/mytool.conf` or `refused: already allowlisted: .bashrc`. The
popup passes `--json` on every call, so what it reads is unchanged. Exit codes
are the same either way: 0 ran, 1 refused or unhealthy, 2 usage.

In every JSON reply, `problems` is a list of sentences meant to be read as
they are, which is what the popup shows you. `lint --json` adds `findings`
beside it: the same problems as `{code, path, note}` records, for a script
that wants to sort or count them rather than print them. `notes` holds the
informational ones lint does not fail on.

`status` records what it found even when it cannot go on. If the data repo has
become unreadable (the `.omabackup` marker is gone, or `.git` is no longer a
repository) it writes `status.json` with `"state": "fault"` and the reason
before exiting 1, so the bar widget shows what broke instead of the last good
run's green. `health` does the same at login. A repo in that state is still
refused outright by every verb that would write to it.

### Popup keys

| Key | Action |
|---|---|
| `s` | Snapshot now |
| `p` | Push, or open the commit confirmation if the lists are dirty |
| `t` | Open the drift report in a pager (`omabackup open --report`) |
| `b` | Open the backup repository on GitHub (nothing happens if the remote has no page) |
| `n` | Toggle ask-for-a-reason mode on Ignore |
| `r` | Refresh |
| `Tab` | Move to the next bar panel |
| `Esc` | Close |

The popup names the repository your backups go to, under Pushed. A GitHub
remote shows as `owner/repo` and opens in your browser when you click it or
press `b`; another host shows as `host/path` as plain text, because a
GitHub repository is the only one whose web page this tool can work out
from a git remote. A local-only repo shows no such row at all: the line
above it already says so. The URL is built by the CLI from the remote,
validated to be exactly `owner/repo`, so nothing a git remote says can
send your browser somewhere else. `omabackup open --remote` does the same
thing from a terminal.

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
`status` prints the gate's own reason as `push_reason`, and that is the
field to read. The ones you will see: `gitleaks-missing` (commits happen,
nothing pushes until you install it), `remote-unverified` (a non-GitHub
remote you have not marked trusted, or a GitHub repo the API would not
confirm), `net-disabled` (the visibility probe was switched off and the
remote is not trusted), `probe-<code>` (GitHub answered something that
proves nothing either way, `probe-403` for a rate limit, `probe-000` for no
network), `pushurl-differs` (origin fetches from one URL and pushes to
another, so nothing verified about the first says anything about the
second; fix it with `git remote set-url --push --delete origin`),
`no-remote`, `unprobed` (nothing has probed this origin yet, or the last
verdict was recorded against a different one) and `stale` (the last verdict
is older than `staleDays`, and an old yes is not a yes). A remote that turns
out to be public is not in this list because it is not a reason push is off:
an HTTP 200 refuses the whole run.

`probe-403` is the one that can last. The GitHub API counts its
unauthenticated rate limit per IP address, not per repository, so if you
share an address with a lot of other people (a carrier-grade NAT, a campus
or office network, a VPN exit) the API can answer 403 for hours or days at a
time through no fault of yours. Nothing is broken and nothing is lost: the
snapshot still runs and still commits, and the commits wait locally until a
probe gets a real answer. What changes is that the popup stops saying "up to
date" about a push it cannot vouch for. The Pushed row reads "unverifiable
since" and the date the last conclusive answer was given, and once that date
is further back than `staleDays` it becomes an alert-triangle problem
naming the reason and the number of days. `status --json` carries the same
two facts as `push_unverifiable_days` (an integer, or `null` when the gate
does have an answer) and `push_unverifiable_since` (the date, or an empty
string). If it never clears, the way out is a remote the probe does not need:
a non-GitHub host you mark trusted with `omabackup setup --trust-remote`.

`setup check` answers a narrower question, "is this install wired up", so it
shows the tools, the marker, the units and the remote's kind and trust flag,
and it does not run the probe or report `pushurl-differs`. For why a push
did not happen, ask `omabackup status`.

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
* **Remote has diverged**: the remote has commits this machine does not, so
  nothing can be pushed. Backups keep committing locally, so nothing is lost
  in the meantime, but they are not off this machine until this is sorted out.
  It usually means another machine pushed a snapshot of its own, or you
  edited a list in the repo's web interface. Replay your local commits on top
  of the remote's:

  ```bash
  git -C ~/.local/share/omabackup/data pull --rebase
  omabackup push
  ```

  (Use your own data repo path if it is somewhere else; `omabackup setup
  check` prints it on the `data repo` line.) If the rebase stops on a
  conflict, git names the files.
  Edit each one so it reads the way you want, `git add` it, then run
  `git rebase --continue`, repeating until the rebase finishes, and then
  `omabackup push`. To back out and think about it later, `git rebase --abort`
  leaves everything exactly as it was; the next snapshot commits locally as
  usual.
* **"a name the report cannot represent"**: a file whose name holds a TAB or a
  newline cannot be written as a drift row, so the scan reports the directory
  it is in and marks the state a fault rather than writing a row that names a
  different file. The scan itself finished. Rename the file, or add a dated
  `<its directory>/**` line to `drift-ignore.txt` if the whole directory is
  noise.
* **"N of M allowlist entries no longer exist; refusing to run"**: the
  mass-disappearance guard, and two of them produce that sentence. The first
  counts required entries (no leading `?`) that no longer resolve. The second
  counts every entry this repo has ever backed up that `$HOME` no longer has,
  optional ones included, which is the one that fires on a wrong `$HOME` or
  an unmounted partition before the next commit throws the missing files
  away. Either way the entries counted are listed above the refusal, one per
  line, under `missing:` for the first and `vanished:` for the second. Two
  ways out, and only the second refusal names them: if those paths really are
  gone for good, `omabackup resolve-gone <path> remove` for each one, or edit
  `allowlist.txt` by hand and commit it. An entry for something that is
  simply not on this machine belongs in the list with a leading `?`.
* **"data repo marker has no usable format field"**: `.omabackup` is the file
  that says the repo is OmaBackup's and what format it is in, and a marker
  that is not readable JSON is refused rather than overwritten, because
  rewriting it would tell a newer machine its own repo is older than it is.
  The marker is committed, so the fix is
  `git -C <data repo> checkout -- .omabackup`. A marker whose format is
  higher than this version understands is a different message and the fix is
  to upgrade OmaBackup.
* **"a remote was configured but the repo has no origin"**: `status` reports
  `remote: missing` and a fault. The config records that you set a remote up
  and git no longer has one, usually after a `git remote remove` or a
  re-cloned `.git`, and every commit since has gone nowhere. Re-run
  `omabackup setup` (or add origin back by hand). Having no remote at all is
  a different, supported state: `remote: none`, and the widget stays green.
* **"a file whose name contains `*` `?` or `[` cannot be backed up by
  name"**: `allow` and `ignore` refuse such a path. Both lists are matched as
  globs and neither format has an escape, so writing the name into one would
  silently claim every sibling it matches. There is no hand edit that fixes
  it: rename the file, or ignore the folder it is in.
* **"OMABACKUP_IN_SUITE is set outside a test run"**: the marker that lets the
  test suite weaken its own guards is set in your environment. It does
  nothing on its own (see Development below), but nothing legitimate sets it,
  so `status` reports it. Unset it wherever it came from, usually
  `~/.config/environment.d` or a shell rc file, and remember a
  `systemd --user` unit inherits it too.
* **"the remote URL carries a password"**: `setup` will not store a URL of
  the form `https://user:password@host/...`. It would land in `.git/config`,
  in the config file and in the log. Use an SSH remote, or HTTPS with a
  credential helper (`git config credential.helper`), point origin at the
  password-free form with `git remote set-url origin`, then rerun `setup`.
* **"the last snapshot refused and nothing was backed up"**: the most recent
  run stopped at one of the gates, and the rest of the line is the reason it
  gave. Nothing was committed, so nothing left this machine. This appears the
  moment it happens rather than waiting for the backup to go stale, and it
  clears itself on the next run that finishes. The commonest cause is the
  secret scan finding a credential-shaped string in a file you back up: fix
  the file, or decide the finding is not a secret and record that decision
  (the next entry says how), then run `omabackup snapshot` again.
* **"gitleaks exited 1 scanning the staging tree"** (or **"on the staged
  commit"**), **"no snapshot was committed"**: the content scan found
  something shaped like a credential. If it is one, take it out of the file,
  or stop backing that file up. If it is not (an example key in a note, a
  test fixture, a hash that happens to look like a token), there are three
  ways to say so. Reword the line so it no longer matches. Put
  `gitleaks:allow` in a comment on the same line. Or add the finding's
  fingerprint, `<path in the repo>:<rule>:<line>` (for example
  `home/.bashrc:anthropic-api-key:3`), as a line in the data repo's
  `.gitleaksignore`, and commit it: the popup's Commit button or
  `omabackup push --confirm` will. A fingerprint names a line number, so it
  stops matching when the line moves, and the next edit gets looked at
  again.
* **"added N ignore pattern(s) this version ships"**: an upgrade found
  patterns in `share/data.gitignore` that your data repo's `.gitignore` did
  not have, and the snapshot appended them under a dated comment and
  committed that edit on its own, before its own commit. Nothing is removed
  and nothing is reordered. The commit is skipped in two cases the run names:
  you had an uncommitted edit to `.gitignore` already, or something was
  staged in the data repo. Then the patterns are still appended and the file
  is reported as an uncommitted change until you commit it (the popup's
  Commit button offers `.gitignore`, or `omabackup push --confirm`). Only the
  snapshot and `setup --import` write this file; `status`, `drift` and `lint`
  never do.
  Two things are worth a look at the result, both of them a consequence of
  appending. A shipped line landing below a negation you wrote yourself
  shadows it, because git's last matching rule wins, so keep your own `!`
  lines at the end of the file or move them back down after a sync. And a
  shipped negation you had deliberately deleted (`!id_*.pub` is the only one)
  is re-added, which ignores less rather than more. Delete a re-added line
  again if you meant it, and commit that.
* **"timer.calendar: systemd-analyze not found..." (a `setup check` FAIL
  line, and `setup` itself refuses)**: `timer.calendar` and `timer.jitter`
  are checked against systemd's own grammar in `setup`, right before they
  reach a unit file. Without `systemd-analyze` neither value can be proved
  valid, so `setup` refuses to write an unvalidated unit file and `setup
  check` reports the same gap as a FAIL, rather than assuming the value is
  fine. Install `systemd` tooling, or run `omabackup setup --no-timers` to
  finish setup without a timer.

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
effect **only when `OMABACKUP_IN_SUITE=1` and `OMABACKUP_CONFIG` are both
set**: the suite exports the marker at its own top and every fixture points
`OMABACKUP_CONFIG` at its own throwaway config, while a real install sets
neither. The pair matters, because a marker on its own is one more exported
variable for whoever set the hook. `OMABACKUP_MIN_FILES` and
`OMABACKUP_MIN_ALLOWLIST` (the derived snapshot floors),
`OMABACKUP_MIN_RESTORE` (the floor `restore --configs` refuses below),
`OMABACKUP_NET=0` (skip the visibility probe entirely), and
`OMABACKUP_SKIP_ETC=1` / `OMABACKUP_SKIP_DROPINS=1`
(skip the `/etc` half of the drift scan). Without both, they are ignored and
`status` reports a problem naming every one it found, so the widget shows a
fault; the marker set without the redirection is reported on its own as
"OMABACKUP_IN_SUITE is set outside a test run". A `systemd --user` unit
inherits the user manager's environment, so any of these set once in
`~/.config/environment.d` or `.bashrc` would otherwise have reached the daily
timer forever with nothing saying so.

Design docs: [docs/superpowers/specs/2026-09-03-omabackup-design.md](docs/superpowers/specs/2026-09-03-omabackup-design.md),
the build plan it was built from
[docs/superpowers/plans/2026-09-03-omabackup-1.0.md](docs/superpowers/plans/2026-09-03-omabackup-1.0.md),
and what comes next in
[docs/superpowers/plans/2026-09-05-omabackup-1.0-roadmap.md](docs/superpowers/plans/2026-09-05-omabackup-1.0-roadmap.md).
Contribution principles: [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

What is planned for 1.0, and what was deliberately left out of 0.7.0, is
written down in
[docs/superpowers/plans/2026-09-05-omabackup-1.0-roadmap.md](docs/superpowers/plans/2026-09-05-omabackup-1.0-roadmap.md).

Not planned: syncing two machines, and sending anything anywhere but the
remote you configured. It is also not designed or tested to run as root.

## License

MIT, see `LICENSE`.
