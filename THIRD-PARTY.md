# Third-party software

OmaBackup bundles nothing. Every tool the README's Requirements tables name
ships with Omarchy or is an Arch package:

- the four hard requirements: git, rsync, jq, and util-linux (for flock);
- the optional ones: gum, systemd, curl, networkmanager, psmisc, python,
  xdg-terminal-exec, wl-clipboard, libnotify, github-cli;
- the manifest generators.

gum is optional: without it the wizard's text prompts take their default and
its yes/no gates answer no. gitleaks (MIT, https://github.com/gitleaks/gitleaks)
is optional too and gates pushes only.

OmaBackup's own license is MIT, see `LICENSE`. This note used to sit at the
bottom of that file; it lives here so `LICENSE` is the plain MIT text and
license detectors (GitHub's included) read it as MIT.
