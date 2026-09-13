import QtQuick
import qs.Ui

// PanelActionButton renders only a glyph, so a screen reader has nothing to
// announce. The tooltip is the label; the trailing "(key)" hint is dropped.
//
// pathLabel is the row this button acts on. Without it a popup of thirty
// drift rows announced thirty identical "Add to allowlist" buttons, with
// nothing to say which file each one was about, so the name becomes
// "<verb>, <path>" whenever a row passes its path down. A typed string that
// defaults to empty, never undefined, so a button with no path to give keeps
// the old behaviour.
PanelActionButton {
  property string pathLabel: ""
  readonly property string accessibleVerb: (tooltipText || "").replace(/\s*\([^)]*\)\s*$/, "")
  Accessible.role: Accessible.Button
  Accessible.name: pathLabel.length > 0 ? accessibleVerb + ", " + pathLabel : accessibleVerb
}
