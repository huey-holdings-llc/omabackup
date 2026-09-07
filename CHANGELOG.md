# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog 1.1.0 and the project uses Semantic Versioning.

## [Unreleased]

### Fixed

`notify: false` in the config now silences desktop notifications. The knob
has existed since 0.7.0 and the README now lists it, with the other config
keys and their defaults. The config reader used jq's `//` to supply a
default, and that operator treats `false` the same as a missing key, so a
configured `false` read back as nothing and the built-in default of `true`
took over. `remote.trusted` and `shellNag` went through the same reader and
were unaffected only because everything that reads them asks "is it true".

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
