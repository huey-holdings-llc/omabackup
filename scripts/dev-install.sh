#!/usr/bin/env bash
# Mirror this checkout into the Omarchy plugin directory, validate, symlink the
# CLI, and rescan. The plugin tree may not contain symlinks (validator rule),
# so we rsync and put the CLI symlink in ~/.local/bin instead.
#   scripts/dev-install.sh            # sync + validate + symlink + rescan
#   scripts/dev-install.sh --enable   # also enable the bar widget (right section)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ID=$(jq -r .id "$HERE/manifest.json")
DEST="$HOME/.config/omarchy/plugins/$ID"

mkdir -p "$DEST"
rsync -a --delete --exclude .git --exclude 'tests/tmp' --exclude AGENTS.md --exclude .claude "$HERE/" "$DEST/"
chmod +x "$DEST/bin/omabackup" "$DEST/scripts/"*.sh "$DEST/tests/"*.sh

if command -v omarchy-plugin-validate >/dev/null; then omarchy-plugin-validate "$DEST"; fi

mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/bin/omabackup" "$HOME/.local/bin/omabackup"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if [[ "${1:-}" == "--enable" ]]; then omarchy-plugin-enable "$ID" --section right || true; fi
echo "installed: $DEST (CLI: ~/.local/bin/omabackup)"
