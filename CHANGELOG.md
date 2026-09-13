# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog 1.1.0 and the project uses Semantic Versioning.

## [Unreleased]

### Changed

The triage verbs (`allow`, `ignore`, `resolve-gone`, `push`, `timer`, `open`)
honour `--json` like every other verb. They used to answer in JSON whether or
not you asked, because the popup is their main caller, which made all six of
them awkward to use by hand. Without `--json` each one now prints a single
plain line: `allowed ~/.config/mytool/mytool.conf`, `ignored
~/.cache/thing/** (reason: regenerable)`, `refused: already allowlisted:
.bashrc`. With `--json` the reply is byte for byte what it was, refusals
included, so the popup sees no change at all. Exit codes did not move.

`problems` is a list of sentences in every reply and in `status.json`. It was
strings from `status` and `health` and `{code, path, note}` objects from
`lint`, and the popup renders whatever it finds there as text, so one shape
had to win. `lint --json` keeps its records under a new `findings` key, with
the same contents as before, and its `problems` now holds the same lines the
plain `omabackup lint` prints. The human output of `lint` is unchanged.

`omabackup self-test` takes a few minutes instead of twelve. Its fixture
snapshots ran the real machine-fact tools (pacman, systemctl, npm, fprintd
and the rest) around 180 times; they now run stubs that print something
fixed, and the handful of groups that need the real tools still use them.
`self-test --real` puts every group on the real tools. The allowlist
guard's second-look wait (five seconds, so a file an Omarchy migration has
moved aside for a moment is not reported GONE) is now a suite-only knob,
`OMABACKUP_SECOND_LOOK`: outside a test run it is ignored and `status`
names it, like the other guard overrides.

The "new unbacked config" desktop notification is normal urgency, not
critical: new drift is news for the next triage, not an emergency. A failed
snapshot is still critical.

The popup's Triage button (and `t`) opens the drift report in a pager,
through the new `omabackup open --report`, instead of a bare shell in the
data repo. Plain `omabackup open` still opens the shell.

The bar shows a different glyph for each state: the warning triangle for a
fault, a disk with an alert mark while something waits on you, the plain
disk when all is well, and an outline before setup. Healthy, "attention
with nothing left to triage" and "not configured" used to share one.

The `.gitignore` top-up on an adopted or upgraded data repo now happens in
the snapshot, under the repo lock, and commits what it appended in a commit
of its own, so the first `status` after an upgrade reports a clean repo
instead of an edit for you to commit. It stands down, appending but not
committing, when you already had an uncommitted edit to `.gitignore` or
something staged; the run says which, and the popup's Commit button or
`push --confirm` is the way out, as before. `setup --import` does the same
when it adopts a repo. The read-only verbs (`status`, `drift`, `lint`, the
widget's refresh) no longer write to the data repo at all; they used to run
this sync outside the lock. `setup --import` holds the repo lock while it
writes the marker and runs the sync.

### Fixed

A data repo the engine cannot read is recorded, not just refused. `status`
checks the repo before it writes anything, so a marker lost to a bad merge, or
a `.git` that stopped being one, made the verb exit without touching
`status.json`, and the bar widget went on showing the last good run's green
for as long as the repo stayed broken. `status` and `health` now write a
status object with `"state": "fault"` and the reason in `problems` before they
exit, so the popup shows what broke. Both still exit 1, and no write verb is
any more willing to touch a repo in that state.

The popup's Commit button now commits every edit it counts. `status`
counted every uncommitted change in the data repo outside the snapshot's own
files, but the button staged only the four lists and `.gitignore`, so
anything else (a skill file kept in the repo through a symlink, say) showed
as "1 uncommitted" for good while the button ran and moved nothing. The two
now share one list. The confirm dialog names each file by its path, where it
used to show raw `git status` lines; the button stages exactly those paths
and never reads a name as a pattern; the staged secret scan still gates the
commit; and a list that changed after the dialog was drawn is shown again
instead of committed. `omabackup push --confirm` commits the same set. Past
1000 edits the button refuses and says how to commit by hand. status.json
gains `uncommitted_count`, `uncommitted_truncated` and `uncommitted_sig`, and
`uncommitted` now holds bare paths.

`/etc` reference copies keep their own permissions, capped at 0644. They
were staged 0644 whatever the source was, so a 0600 or 0640 file you can
read sat readable to everyone in the data repo's working tree, and
`modes.txt` recorded the wider mode as the real one. The next snapshot
tightens the copies already there. Git's history is unaffected, since git
only ever stores 644 or 755, and an executable `/etc` file is still stored
as a plain one.

A gitleaks false positive takes one line in the data repo's
`.gitleaksignore`. The staging-tree scan named a finding by an absolute path
under `.staging` and the staged scan by its path in the repo, so a
fingerprint satisfied one gate and not the other, and the line that
satisfied the staging scan carried this machine's own path. Both now name it
`<path in the repo>:<rule>:<line>`. The README's Troubleshooting says how to
record a false positive, and SECURITY.md why that is not a bypass.

Pressing Snapshot in the popup no longer brings back every row you had just
triaged. The button starts the snapshot unit and returns at once, and the
panel cleared its record of your decisions right away, so the next refresh
redrew them from the old report. It now keeps them until the run it started
has landed, says "Snapshot running…" meanwhile, and checks every 15 seconds.
status.json gains `last_attempt_at` and `last_attempt_ok`, the last
attempt's time and verdict, which is how it knows. A run that finds another
one holding the lock no longer leaves the last verdict cleared when it
stands down, so status stops saying a run is under way with none running.

`omabackup drift` lists GONE rows (allowlist entries that resolve to
nothing), as the popup always did. Only the snapshot used to write them, so
the command the login reminder names for "GONE = vanished" never showed one.

An ERROR row in the drift report no longer counts toward the paths to
triage. It is still a fault, with its reason in the popup; it has no
buttons, so the count it added could never come down.

The drift scan no longer reports the tool's own files, on any data repo:
the five systemd units setup writes (by their exact names; a hand-written
unit beside them, even one starting `omabackup-`, is still reported) and
`~/.config/omabackup`. The seed ignore list had a line for the units, but a
repo adopted from an older version has no such line, so the first popup
after adoption opened on seven rows about the tool itself. The config
directory is machine-local, `dataRepo` is an absolute path on this machine
and `remote.url` may carry credentials, so it is not backed up and not
offered for it; a restored machine gets its config from `setup`.

With no `manifests/.last-run` stamp (a fresh clone never has one), `status`
judged the backup's age by HEAD's commit time, so any commit that was not a
snapshot, the adoption marker, a list commit, the `.gitignore` sync's own,
made a stale backup read as fresh. The stand-in is now the last commit that
touched the snapshot's own output paths.

`notify: false` in the config now silences desktop notifications. The knob
has existed since 0.7.0 and the README now lists it, with the other config
keys and their defaults. The config reader used jq's `//` to supply a
default, and that operator treats `false` the same as a missing key, so a
configured `false` read back as nothing and the built-in default of `true`
took over. `remote.trusted` and `shellNag` went through the same reader and
were unaffected only because everything that reads them asks "is it true".

`verify` on a data repo with no `manifests/.last-run` stamp (a fresh clone,
which never has one, or a repo adopted from another machine) now treats the
last snapshot commit as "the last run", not HEAD. HEAD right after `setup
--import` is the adoption marker commit, so every live file edited between
the last snapshot and the import read as a fidelity problem. The run also
says when it is reasoning from a stand-in, and that a snapshot writes the
real stamp.

A snapshot that refuses now says so at once, instead of looking healthy for
two days. `manifests/.last-run` moves only when a run finishes, so a run that
refused left the previous run's timestamp standing and nothing was reported
until `staleDays` had passed. The panel could meanwhile say "Nothing unbacked.
Every allowlisted path is captured", because the drift scan runs before the
gates that refuse, so its report was accurate and its meaning was not. For a
tool whose promise is telling you what it is not backing up, that was the
wrong way to fail: it happened on a real machine for four hours, every run
stopped by the secret scan over a plan file that quoted a database password.

The outcome of the last attempt is now recorded alongside its time, and
`status` reports a refused run as a problem immediately, naming the reason
that stopped it, so the panel turns red on the first failure and tells you
what to fix rather than sending you to the journal. A dry run records nothing,
since it is an inspection and not a backup. A run the timer had to kill never
reaches the refusal path, so the `OnFailure=` hook files it instead, and it
never overwrites a reason the refusal already explained.

`snapshot --json` and `status --json` now report the same drift count. The
snapshot counted only rows matching `MODIFIED`, `NEW` and `GONE`, while
`status` counted every row a drift report can hold except `ERROR`, so a
report with a `TOOBIG` or `EXCLUDED` line (a file over `maxFileSize`, or one
the repo's `.gitignore` matches) made the two disagree about how many items
needed attention, on the same report at the same moment. Both now come from
one function, and the count means the same thing everywhere: every row the
popup can put an Ignore or Allow button on, which is every row but `ERROR`.

### Security

`setup` refuses a remote URL that carries a password, whether it arrives
as `--remote` or is already on the repo's origin, and says how to fix it
(an SSH remote, or HTTPS with a credential helper). The refusal, `setup
check` and every warning that prints a remote show any password as `***`.
Push URLs are checked too: `remote.origin.pushurl` overrides the fetch URL
for pushes only, so a clean fetch URL with a credential-bearing push URL
passed the guard entirely, and the push URL is the one a password would
actually be used on. The warning that names a mismatched push URL redacts it
as well. A password in a URL would otherwise sit in `.git/config`, in the
tool's config and in the log; raised by the Codex reviews on PRs 6 and 7.

The filename gate refuses the run when its walk of the staging tree fails.
The walk sat in one pipeline ending in `|| true`, put there for grep's
no-match exit, and that swallowed `find`'s exit too: a `find` that died on
an unreadable directory produced no names, nothing matched, and the gate
passed. `find`'s status is now checked on its own, and a gate that cannot
look does not pass.

### Added

The popup names the repository your backups go to. A new row under Pushed
reads `Backup repo`, showing `owner/repo` for a GitHub remote as a link
that opens it in your browser, or `host/path` as plain text for another
host. A local-only repo shows no row, since the line above already says
so. `b` does the same from the keyboard, and `omabackup open --remote`
from a terminal. The URL is built by the engine from a remote validated to
be exactly `owner/repo`, so nothing a git remote says can choose the host,
and it is never assembled in the widget: the popup launches nothing but
the command line, as it always has. Two new `status.json` fields,
`remote_label` and `remote_linkable`, carry it, and neither ever holds a
raw URL, because that is the one shape that can carry a password.

## [0.7.0] - 2026-09-06

If you have been running 0.2.0, this is the release where the plugin stops
being a status light for something else and becomes the thing that does the
work. Versions 0.1.0 and 0.2.0 were a bar widget reading a status file written
by a personal backup script that lived outside this repository, so anyone who
installed the plugin got the bar and nothing behind it.

### Added

The backup engine itself, as `bin/omabackup` over `lib/`. It is a plain bash
CLI with sixteen verbs, and it is the product: the popup calls those verbs and
holds no opinion of its own about what to back up, ignore or push.

Your config now lives in two places the engine owns. `~/.config/omabackup/config.json`
holds the settings, and a separate private git repository, the data repo, holds
your allowlist, your ignore list, the mirrored config and the generated
manifests. Nothing is hard coded to one machine any more. `omabackup setup`
walks you through creating both, or `setup --import` adopts a repo you already
have.

A daily snapshot on a systemd timer, which stages every allowlisted path,
records the machine's packages, services, plugins, printers and locale, checks
its floors and its secret gates, and commits. Alongside it, a scan that answers
the question an allowlist cannot: what under `$HOME` and the watched `/etc`
drop-in directories looks like config you wrote and is not covered by any
list. The popup groups that report by folder and gives every row a button, so
a decision is one click and is recorded with a date and a reason.

Restore, which is a dry run until you pass `--apply` and never removes anything
without copying it aside first. Verify, which restores the committed backup
into a throwaway directory and compares every file, symlink and mode against
the live one. Lint, for the hygiene of the four lists. And a weekly self-test:
the black-box suite end to end against throwaway fixtures, plus two groups that
run `lint` and `verify` against your actual data repo, so a guard that quietly
stopped firing is something you hear about.

### Changed

The bar widget is now a view over one state file, `status.json`, written by the
engine. It shows a quiet glyph when everything is healthy, a drift count when
something is waiting on your decision, and an alert triangle only when a guard
has actually fired. Those are three different things and they no longer look
the same.

If you adopted a data repo under an earlier version, the first run on 0.7.0
appends any ignore pattern this version ships that your repo's `.gitignore`
does not already have, under a dated comment, and tells you to commit it.
Nothing is ever removed or reordered, so lines you added yourself stay where
they are, but appending is not neutral in both directions and it is worth one
look at the result: a shipped line landing below a negation you wrote yourself
shadows it, because git's last matching rule wins, and a shipped negation you
had deleted on purpose (`!id_*.pub` is the only one) is put back, which
ignores less rather than more. Keep your own `!` lines at the end of the file.
The popup's Commit button now offers `.gitignore` alongside the four lists, so
that edit has somewhere to go.

Two more upgrade notes for an adopted repo. `setup` no longer lays down a
`.gitleaks.toml`: the content scan always runs with the plugin's own
`share/gitleaks.toml`, so the copy in the repo was never read and setting it
down said otherwise. A repo seeded by an earlier version still has one, it is
inert, and to be rid of it: `git -C <data repo> rm .gitleaks.toml && git -C
<data repo> commit -m "drop the inert gitleaks rules copy"`. And unlike
`.gitignore`, `drift-ignore.txt` is not topped up on an existing repo, so the
entries this version's seed list ships (omabackup's own systemd units among
them) are not added to a repo that predates them; add the ones you want from
`share/drift-ignore.example` by hand, or from the popup as they show up.

### Security

Nothing is pushed unless the engine can show the push is safe. A filename gate
always refuses credential-shaped names; gitleaks, when installed, scans both
the staging tree and the staged commit with a project rules file. For a GitHub
remote the engine asks the API whether the repository is public and refuses the
whole run if it is; for anything else it will not push at all until you mark
the remote trusted by hand. Without gitleaks, snapshots still commit locally
and simply never leave the machine.

Before this release was cut, the branch went through a five-lens expert review
(security, architecture, future proofing, usability and documentation) and
four rounds of fixes on top of it. That work closed, among others: normalize
rules that could execute a shell command out of the data repo; GitHub URL
spellings the visibility probe did not recognise, which the popup could then
have been asked to trust; filenames that split a drift report row so a triage
click widened the allowlist to a directory the scan never named; a
mass-disappearance guard that could not fire on a stock install; a self-test
timeout that would have raised a false alarm; and a data repo whose `.git`, the
whole backup in full history, was left group and other readable when the
directory already existed.

## Earlier versions

The personal bar widget these versions shipped is not comparable to the plugin
above and its notes are not carried forward.
