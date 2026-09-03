# Backup Status (`io.github.coreytyhurst.backup-status`)

A glanceable Omarchy bar widget for the
[hp-laptop-config](https://github.com/coreytyhurst/hp-laptop-config) backup
engine: a quiet glyph while everything is healthy, a drift count when paths
need triage, and the alert triangle when something fail-closed would flag.

This is deliberately a **thin view**. All judgment lives in
`bin/widget-helper.sh` inside the backup repo, where it is versioned,
shellchecked, lint-gated, and covered by self-test groups 50/51. The QML
renders that helper's JSON and shells back into its subcommands with argv
arrays; no shell strings are ever built in QML, and no backup logic lives here.

## What the popup does

- **Vitals**: last snapshot age, next timer run (with a pause/resume toggle),
  push state, pending repo edits.
- **Drift triage in place**: each `NEW` row has Allow (append to
  `allowlist.txt`) and Ignore (dated entry in `drift-ignore.txt`, optional
  one-line reason). `GONE` rows offer Remove and Mark-optional. Every write is
  validated against the current drift report, taken under the snapshot flock,
  and rolled back if `lint-lists.sh` rejects it.
- **Dynamic push button**: plain push when commits are waiting; when the
  repo's own scripts/lists are dirty it shows exactly which files would be
  committed and asks first. It stages exactly those paths, never `-A`.
- **Snapshot now** starts the systemd service; **Full triage** opens a
  terminal in the repo with the Claude `backup-triage` skill for the cases a
  button should not judge (MODIFIED, TOOBIG, ERROR).

## Keyboard

| Key | Action |
| --- | --- |
| `s` | Snapshot now |
| `p` | Push / open the commit confirmation |
| `t` | Full triage in a terminal |
| `r` | Refresh |
| `Esc` | Close |

Right-click the bar icon to refresh without opening the popup.

## Install (this machine)

```bash
scripts/dev-install.sh --enable
```

The widget reads `repoDir` from its bar-widget settings (default
`~/projects/hp-laptop-config`). It polls `widget-helper.sh status` every 10
minutes and on open.

## Note

This widget is specific to my backup engine and machine. The general idea
(and what a shareable version would take) is written up in the backup repo
under `docs/public-plugin.md`.

MIT © Corey Tyhurst
