# Security

OmaBackup pushes a copy of your config to a git remote and can print files it
finds along the way, so security reports get priority over everything else.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security tab, "Report a vulnerability") rather than a public issue, so a fix
can ship before the details are out. If you cannot use that, open an issue
saying only that you have a security report and how to reach you.

You can expect an acknowledgement within a few days. This is a part-time
project, but a confirmed vulnerability will be fixed and released ahead of
any other work.

## What counts

Five things can go wrong here that cannot be undone. A way to cause any of
them is a vulnerability, whether or not it needs an unusual config, a
hand-edited list or an unlucky filename to reach.

1. **A secret reaches the data repo.** A credential-shaped file getting past
   the filename gate, or a token inside an allowlisted file getting past the
   content scan, or either gate being made to pass without running. Once it
   is committed it is in the local history and in every later clone, whether
   or not it was ever pushed.
2. **A push to a remote whose visibility was not actually proven.** Not only
   "the probe said public and it pushed anyway": also the probe never running,
   answering about a different repository than the one git pushes to, or a
   trust flag standing in for a proof it was never asked to give.
3. **A file outside the allowlists reaches the repo.** Nothing under `$HOME`
   outside `allowlist.txt`, and nothing under `/etc` outside
   `etc-allowlist.txt`, is meant to be staged. A path that gets in anyway,
   through a glob, a symlink, a rename or a report the triage verbs read
   differently from the scanner, counts.
4. **User data destroyed, or its permissions weakened.** Restore and setup are
   the two paths that write outside the data repo, and the README's "What it
   writes, and what it only reads" is the whole list of places they are
   allowed to touch: the data repo, `~/.config/omabackup`, the state
   directory, the five unit files in `~/.config/systemd/user`, the
   `~/.local/bin/omabackup` symlink, the login check in `~/.bashrc`, and
   `$HOME` itself under `restore --apply`. A write outside that list, a file
   removed without the `.bak.<epoch>` copy first, or a mode replay that
   loosens a file (or reaches one through a symlinked parent), all count.
5. **Code execution out of the data repo or the environment.** Nothing in the
   data repo is ever interpreted as a program: not the normalize rules, not
   the ignore globs, not `modes.txt`, not a manifest line handed to another
   tool. Paths and reasons travel as arguments, never as an interpolated
   shell string, a `jq` filter or a systemd unit body. Guards must not be
   weakenable from the ambient environment either, since a `systemd --user`
   unit inherits it.

## Scope notes

Omarchy's shell, git itself, and gitleaks are separate projects; issues in
them should go upstream, though a report here that helps route the problem
is still welcome.

A fingerprint in the data repo's `.gitleaksignore`, or a `gitleaks:allow`
comment on a line, tells the content scan that one finding is not a secret.
The rules file stays pinned to the plugin, so the repo cannot turn a rule
off; it can only record a decision about one finding, tied to a path, a rule
and a line. That is the user's recorded judgement, not a way round the gate.
