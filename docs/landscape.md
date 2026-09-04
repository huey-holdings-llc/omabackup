# The landscape: backup and drift tools for Omarchy

Written 2026-09-03, before OmaBackup's public design was started. It records
what already exists, what each tool does well, where OmaBackup sits, and
what it borrows. Every claim was checked against the cited repository on
that date; the authors of those projects had no involvement in OmaBackup
and deserve none of the blame for it.

## The short version

Omarchy ships nothing for user-config backup. Its manual still recommends
GNU Stow, and its maintainer has written two design plans (dots, backup)
that are not implemented on any branch. In the meantime the community has
built at least two dozen tools in this space, eight of them in the last two
weeks. Four are bar widgets that back up your config to a private git repo,
which was going to be OmaBackup's pitch.

So OmaBackup's pitch is narrower: **it tells you, every day, what you are
not backing up, and it refuses to push when it cannot prove the backup is
safe.** No other tool in this list does that, and neither upstream plan
intends to. The backup itself is the boring part.

## Four things people call "drift"

The word is used for four different questions. It helps to know which one a
tool answers.

| Kind | Question | Who answers it |
| --- | --- | --- |
| Unbacked-file drift | Is there user config that nothing captures? | OmaBackup. omarchy-drift-detector and config-prism partly, inside the trees they look at. |
| Stock-vs-live drift | What have I changed from a fresh install? | omarchy-drift-detector (packages both ways, configs). OmaBackup for configs only. |
| Update drift | What did `omarchy update` change under me? | Nobody, as a running tool. The upstream dots plan would; config-prism's "newly packaged" class and a one-shot pre-upgrade script (omarchy-quattro-backup) get part way. Asked for in Omarchy discussions #5588 and #7534. |
| Plugin capability drift | Can this plugin do more than when I accepted it? | omaudit and Omaudit Status. |

Infrastructure drift (Terraform, driftctl, Kubernetes) shares the word and
nothing else.

## What exists

### Omarchy-native, closest to OmaBackup

**[omarchy-drift-detector](https://github.com/Abhishek-1804/omarchy-drift-detector)**
(Abhishek-1804, MIT). A bar widget that "answers one question: what have I
done to this machine that a fresh Omarchy install wouldn't have?" It diffs
installed packages against Omarchy's own install lists, in both directions,
and diffs config files against `/usr/share/omarchy`, then rebuilds a private
git repo from the result on every push. Three secret gates (path patterns,
content patterns, a pre-commit sweep that refuses the commit), a JSON pull
plan, and a fail-closed refusal to scan when the Omarchy baseline is missing
or implausibly small. By choice it has no timer ("The widget does no
background polling"), and by its own account the restore "has never run
against a genuinely fresh Omarchy install". No tests. A new config folder
outside its tracked roots is invisible to it. This is the closest neighbour
and the best tool on this list for the "what did I change" question.

**[omarchy-synchro](https://github.com/harel/omarchy-synchro)** (harel,
MIT in the manifest). The nearest thing to OmaBackup's capture model: an
explicit allowlist (`policy/allowlist.tsv` in your own repo), mandatory
exclusions by secret name and content, every entry marked portable or
device-specific, snapshot and restore "preview-first", restore a dry run by
default, and snapshot, commit and push as three separately confirmed steps.
No timer, by design, and no report of what the allowlist misses. Quiet since
2026-08-22.

**[config-sync](https://github.com/gladimdim/omarchy-config-sync-plugin)**
(gladimdim, MIT). Two-way sync of desktop settings between Omarchy machines,
from a five-tab bar popup: three-way classification of every file (local,
repo, both, added), per-file Keep or Take, and a per-keybinding cherry-pick
of `bindings.lua`. Fixed scope (Hyprland, Omarchy shell files, plugins,
terminals, `~/.local/bin`), no secret scanning, and a walkthrough that says
plainly why the repo must be private. 124 unit tests on filesystem-safety
invariants. It is a sync tool, and its author says so; the difference
between sync and backup is the whole reason OmaBackup exists.

**[omarchy-replicant](https://github.com/tymurbogach/omarchy-replicant)**
(tymurbogach, MIT). One private repo shared by several machines, with a
profile per machine and a shared-or-profile scope per file; restore replays
Omarchy's own commands (`omarchy theme set`, `omarchy plugin add`). It takes
the opposite stance on secrets: SSH keys and `.env` files are copied into
the repo at mode 600. Created 2026-09-02 and still moving.

**[config-prism](https://github.com/AdamMusa/omarchy-config-prism)**
(AdamMusa, MIT). Read-only: compares your Omarchy and Hyprland files with
the installed package defaults and classifies them as modified, user-only or
newly packaged. "It does not snapshot, restore, or overwrite files." The
"newly packaged" class is the cheap half of update drift and worth copying.

**[omarchy-backup](https://github.com/DigitalPals/omarchy-backup)**
(DigitalPals, MIT). A GTK app plus CLI that captures a "setup profile" into
a git repo through an allowlist, rejects known credential paths and secret
patterns before commit, delegates all write authentication to `gh` ("this
app never requests or stores a token"), and takes a local safety snapshot
before any restore. One day of history at the time of writing, no timer,
and no report of what the allowlist misses.

**[omarchy-backup-hub](https://github.com/IAMGREATER/omarchy-backup-hub)**
(IAMGREATER, MIT). A GTK4 backup and restore window over rsync and git,
with an external-drive target. The author's own repository and USB path are
hard-coded; there is no secrets handling.

**[omarchy-backup-history](https://github.com/POSO-PocketSolutions/omarchy-backup-history)**
(POSO Pocket Solutions, MIT). Not a backup tool: a bar widget that reads the
systemd journal for any oneshot backup service and draws a four-week,
GitHub-style day grid. "Backup-tool agnostic", "never touches your backup
credentials". It would sit happily on top of OmaBackup's timer.

**[omarchy-export](https://github.com/ekollof/omarchy-export)** (ekollof,
MIT). Packs keybinds, themes, plugins, hooks and package lists into a
checksummed archive for import on another machine. Export and import, not
capture and monitor.

### Omarchy-native, adjacent

**[omarchy-time-machine](https://github.com/jankeesvw/omarchy-time-machine)**
(jankeesvw, MIT). Scheduled restic backups of your home folder to a drive,
a NAS or a bucket, with a snapshot browser in the bar. The best-liked backup
widget in the marketplace by a wide margin, and a personal-files tool, not a
config tool; the two should coexist on one bar. Its README's explanation of
why the passphrase must live outside the backup is the clearest around.

**[omaudit](https://github.com/omarchy-forge/omaudit)** and
**[Omaudit Status](https://github.com/godhiraj-code/omarchy-omaudit-status)**
(MIT). A capability scanner for plugin source code and its bar shield. The
drift they track is plugin capabilities against an accepted baseline, so
they do not overlap with OmaBackup at all, but the design posture is the
closest relative on this list: bounded output before parsing, an error
state instead of a stale green, observation kept apart from mutation, a
written threat model. The author's essay is titled
["A Security Indicator Must Refuse to Lie"](https://www.dhirajdas.dev/blog/omaudit-status-omarchy-security-indicator).

**[syncshell](https://github.com/omarchy-QOL/syncshell)** (ilyaZar, MIT).
Syncthing from the bar. Adjacent by name only; already credited by
OmaRecorder for its service-and-panel split.

**[omadot](https://github.com/tomhayes/omadot)** (tomhayes, no license
file). A GNU Stow wrapper. Stow symlinks are the model Omarchy's own dots
plan refuses to support, because Omarchy migrations write through symlinks
and replace them with regular files; omadot's issue #3 ("Configs gone after
a restart") is what that looks like from the user's side.

**[Migrate](https://github.com/CyphrRiot/Migrate)** (CyphrRiot, MIT). A Go
TUI for whole-disk and home-directory backup to an external drive, run as
root. Listed in awesome-omarchy but not Omarchy-specific; the wrong layer
for config.

### Upstream Omarchy

Two plans by the Omarchy maintainer live in the repository and are not
implemented on any branch as of 2026-09-03:

* [plans/dots.md](https://github.com/omacom/omarchy/blob/quattro/plans/dots.md)
  (2026-08-15): `omarchy dots snapshot | log | diff | restore | push | pull |
  status` over a bare git repo, a hand-audited manifest of which files count
  ("The manifest is the deny line, nothing outside it is ever staged, and
  there is no command that stages more"), before-and-after snapshot pairs
  around every migration and refresh, an hourly-ish timer, and manual
  squash-publish for sync. It describes itself as "not a backup, the local
  repo dies with the disk", and it has no scan for files the manifest
  misses.
* [plans/backup.md](https://github.com/omacom/omarchy/blob/quattro/plans/backup.md)
  (2026-08-16): restic to S3-compatible storage for personal files under
  `$HOME`, "no include-list to curate", a bar panel driven by one state
  file. Configs are explicitly left to dots.

If dots lands as written, it will cover config history and sync for the
paths its manifest names. OmaBackup's scanner is the thing that would tell
you what that manifest misses, so the two are complementary rather than in
competition. Also relevant: [discussion #5588](https://github.com/omacom/omarchy/discussions/5588)
asking for `omarchy backup / restore / check` (open since May 2026, no
maintainer reply), and [PR #6965](https://github.com/omacom/omarchy/pull/6965)
proposing a git-based backup (open, no maintainer response).

### General dotfile managers

chezmoi, yadm, GNU Stow, aconfmgr, etckeeper, Ansible and their peers were
compared in detail before OmaBackup's engine was chosen, and re-checked for
this document. None detects a new config file that nothing manages: chezmoi
issues [#2298](https://github.com/twpayne/chezmoi/issues/2298) and
[#3776](https://github.com/twpayne/chezmoi/issues/3776) ask for it and the
maintainer has said it is not suitable for chezmoi. Every symlink-based
manager fails the write-then-rename case above. The copy-based ones
(chezmoi, aconfmgr) work, but each covers one layer and none scans for
omissions or refuses to push on an unverifiable check.

## Where OmaBackup sits

What it does that nothing else on this list does:

* **Reports what it is not backing up.** A daily scan compares the live
  machine against Omarchy's stock files and against the allowlist, and
  reports the residue: new files nothing captures, stock files you changed
  that are not captured, allowlisted files that vanished, files too large
  to keep. The scan ends with a completion marker; a scan that dies halfway
  cannot be mistaken for a clean report.
* **Allowlist plus scanner.** The allowlist is the secrets model (a denylist
  fails by disclosure, an allowlist fails by omission, and omission is
  recoverable). The scanner exists to cover the omission.
* **Refuses rather than guesses.** Cannot verify the remote is private:
  commit locally, do not push. Cannot take the lock, cannot read the last
  run, drift scan incomplete, repo mid-rebase: report it as loudly as a real
  failure. gitleaks runs twice, on the staging tree and on the staged
  commit, with rules for the token formats the default set misses.
* **Every guard is proven to fire.** A self-test suite runs weekly against a
  synthetic home and a local bare remote, and each guard has a test that
  makes it trip. The suite is mutation-tested: put a bug back and the tests
  go red.
* **Triage from the popup.** New paths grouped by folder; one click allows or
  ignores a folder, with an optional dated reason; every write is validated
  against the current report and rolled back if the list linter rejects it.
* **Unattended.** A daily timer with jitter, a deploy key scoped to one repo,
  churn suppression so theme and wallpaper rotation do not produce a commit
  every half hour.

What others do better, and OmaBackup should not pretend otherwise:

* omarchy-drift-detector's package drift (both directions, removals
  resolved through `pacman -T`) and its JSON pull plan.
* config-sync's two-machine sync and semantic diffs.
* DigitalPals' safety snapshots and `gh`-delegated auth.
* The dots plan's before-and-after pairs around migrations, which is the only
  design anywhere that answers update drift.

## Prior art and thanks (draft for the README)

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

## FAQ (draft for the README)

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
