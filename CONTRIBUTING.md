# Contributing to OmaBackup

Thank you for looking at this. OmaBackup is a part-time hobby project, built
with AI assistance by someone who is not a professional developer. Pull
requests from people who know this territory better are the best thing that
can happen to it. Issues and pull requests are handled as time allows, so
please be patient, and feel free to fork if you would rather move at your own
pace.

## Principles

These are the rules the project has followed so far. A pull request that
keeps to them is easy to merge; one that breaks them will get a conversation
first.

1. **Base Omarchy first.** The engine should work on a fresh Omarchy install
   with nothing extra added. The four it cannot start without (git, rsync,
   jq, `flock`) all ship with Omarchy, as do the ones it uses when they are
   there: gum for the wizard's prompts, systemd for the timers. The one
   exception is gitleaks, an Arch extra package: it gates a push, never a
   local commit, and setup names it explicitly rather than assuming it is
   there.
2. **Simplicity and efficiency over features.** No daemons, no polling, no
   background work the user did not ask for. The shell watches one small
   status file; the timer runs the CLI once a day and exits. A feature that
   costs idle CPU or a permanent process needs a very good reason.
3. **Follow Omarchy's design and theming.** Use the shell's `qs.Ui` kit
   (`Panel`, `Button`, `Dropdown`, `TextField`, `ConfirmDialog`, and so on)
   and the theme tokens (`Color.*`, `Style.*`, `bar.foreground` and friends)
   rather than hard-coded colours, fonts or sizes. Every surface must look
   right in every Omarchy theme, light or dark, and every action must be
   reachable from the keyboard with the shortcut shown on screen.
4. **The CLI is the product; QML is a view.** Anything the popup can do must
   be an `omabackup` verb first, with a test in `tests/engine.test.sh`. QML
   files render state and call commands; they hold no judgment about what to
   back up, ignore, or push that a script could not reach.
5. **Fail closed.** "Cannot verify" is reported the same way a failure is,
   never treated as a pass by default. If a guard cannot fire under some
   condition, that is a bug, not an edge case to leave alone; every guard in
   `lib/` has a group in `tests/engine.test.sh` that proves it actually
   fires.
6. **Data is never code.** Paths, reasons and remote URLs travel as argument
   arrays and `jq --arg`, never as an interpolated shell string, a `jq`
   filter or a systemd unit body. `tests/lint.sh` greps for `bash -c` and
   `/tmp` in the QML and will fail the build if either appears.
7. **Say what it does.** A button that says "Ignore" must never delete
   anything. A README sentence must describe what the code does today, not
   what is planned. If you change behaviour, change the README and the
   CHANGELOG in the same pull request. No em dashes anywhere user-facing:
   commit messages, docs, UI strings, notifications.
8. **Read the user's Omarchy, Hyprland and shell config; never write it.**
   The engine writes only to the data repo it owns, its own config and state
   directories, and the user's systemd user directory during setup. A
   feature that would edit `~/.config/hypr` or any other live config to make
   backup easier does not belong in this project.

## Practical bits

* **Dev loop**: `scripts/dev-install.sh --enable`, then `omarchy-restart-shell`
  for QML changes. `bash tests/engine.test.sh` and `bash tests/lint.sh` must
  both pass. CI runs the lint script and the whole suite in an Arch
  container. Fixture snapshots use stub machine-fact tools (pacman,
  systemctl and the rest print something fixed), which keeps a run to a few
  minutes; `OMABACKUP_TEST_REAL_MANIFESTS=1` puts every group on the real
  ones, and `omabackup self-test --real` does that for you. Group 04
  (idempotency) is the one group that runs the real tools, and a red run on
  a real machine names the manifest that moved; check whether the machine
  changed between runs (a plugin updated, a package installed, a connection
  added) before treating it as a bug.
* **Tests first** for CLI changes. The harness is plain bash (`check`, `eq`,
  `fails`, `has`); each group builds a throwaway fixture (home directory,
  stock-config stand-in, data repo, bare remote) and drives `bin/omabackup`
  directly, never `lib/` internals, so any library behind the same verbs can
  be swapped in later and the suite still decides.
* Every guard in `lib/` has a group in `tests/engine.test.sh` that proves it
  fires. Reintroduce a bug and the suite must go red; if it does not, the
  test is the bug.
* **Small pull requests** with one change each merge faster than one big
  one.
* **Second-model review**: larger pull requests get a review from OpenAI
  Codex, requested by the maintainer with a `@codex review` comment. Treat
  its findings as a starting point for the discussion, not as a verdict
  either way. (The review instructions live in an `AGENTS.md` that is kept out
  of git by `.gitignore`, so a clone of this repository does not carry one:
  the Omarchy marketplace does not allow agent-instruction files in a
  distributed plugin, since an install is a plain git clone, and
  `scripts/dev-install.sh` excludes the file from the deployed tree as well.)
* **Style**: bash with `set -euo pipefail` and shellcheck clean; QML in the
  style of the existing files; plain, direct English in docs and messages.
* **Reporting a bug**: include `omabackup setup check --json`, the relevant
  lines of `~/.local/state/omabackup/omabackup.log`, and the output of
  `omabackup drift`. Never paste the contents of your allowlist,
  drift-ignore reasons, or anything else you would not want public; describe
  the shape of the problem instead.

## Help wanted

Pull requests are welcome anywhere, but these are the areas where the project
most needs someone who knows more than its author:

* **Other git hosts and their visibility checks.** The remote probe knows
  how to ask GitHub whether a repository is public. GitLab, Codeberg,
  Bitbucket and self-hosted Gitea or Forgejo instances all have their own
  APIs for the same question, and right now anything other than GitHub falls
  back to an explicit trust flag. A probe for even one more host, with tests
  against a fake response, would help a lot of people.
* **Restore on fresh hardware.** Restore is staged and dry-run by default,
  which is the safe default, but it has only really been exercised against
  the fixtures. Someone who restores onto an actual fresh Omarchy install
  and reports what breaks (or does not) would close a real gap in
  confidence.
* **Drift categories for tools not in the seed lists.** The allowlist and
  drift-ignore seeds cover the author's own machine. Anyone running a
  desktop environment, terminal, or shell tool that is not in the seeds yet
  is well placed to say what its config, cache and state directories
  actually look like, so the classification table in `docs/triage.md` keeps
  matching reality.
* **Accessibility of the popup.** Keyboard reach is a stated requirement and
  has been checked by hand, but screen reader behaviour and contrast under
  every Omarchy theme have not.
* **A second reviewer for `share/gitleaks.toml`.** The custom rules there
  each carry a proof of what they catch, but secret-detection rules are easy
  to get subtly wrong in both directions (missing a real secret, or flagging
  something harmless often enough that people learn to ignore the warning).
  A second set of eyes from someone who works with gitleaks regularly would
  be valuable.

## Ideas that fit

Anything on the [issue tracker](https://github.com/huey-holdings-llc/omabackup/issues),
better remote-visibility coverage, more drift categories, accessibility, and
anything that makes the code simpler without changing what it does. Ideas
that do not fit: cloud services other than the user's own git remote,
features that need a resident process, or anything that writes to config the
engine is meant to only read.

## License

By contributing you agree that your contribution is licensed under the MIT
license, like the rest of the project.
