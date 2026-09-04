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

Any way to get a file outside the allowlist into the data repo; any push to
a remote the probe reported public; any write outside the data repo and the
engine's own config and state directories; a guard that can be made to pass
without actually running (a check that always reports success, or one that
can be skipped and still leaves the pipeline looking healthy); shell strings
built from paths or reasons instead of passed as arguments.

## Scope notes

Omarchy's shell, git itself, and gitleaks are separate projects; issues in
them should go upstream, though a report here that helps route the problem
is still welcome.
