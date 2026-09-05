import QtQuick
import qs.Commons
import qs.Ui

// One drift line with its inline triage actions. NEW and MODIFIED rows offer
// Allow/Ignore, GONE rows offer Remove and (unless the entry is already
// optional) Mark optional. TOOBIG, EXCLUDED and ERROR rows cannot be acted on
// from a button, so each says why and where to go instead of rendering as a
// bare line with nothing to read. Whether Ignore asks for a note first is the
// panel's business (the shared note field), not this row's.
Column {
  id: root
  property var entry: ({})
  property bool busy: false
  property real leftInset: 0
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  signal allowRequested(string path)
  signal ignoreRequested(string path)
  signal goneRequested(string path, string verb)

  readonly property bool isNew: entry.type === "NEW"
  readonly property bool isGone: entry.type === "GONE"
  // The engine accepts allow and ignore for MODIFIED as well as NEW
  // (lib/widget.sh), and docs/triage.md tells you to allow a stock file you
  // have edited on purpose, so the row withholding both buttons was the only
  // place saying otherwise.
  readonly property bool isActionable: entry.type === "NEW" || entry.type === "MODIFIED"
  // An entry that is already optional cannot be marked optional again: the
  // engine refuses it now, and the button that always did nothing goes away.
  readonly property bool alreadyOptional: entry.optional === true

  readonly property string explainText:
      entry.type === "TOOBIG"   ? "too many files to scan; allowlist the folder or ignore it"
    : entry.type === "EXCLUDED" ? "matched by .gitignore; edit the allowlist entry"
    : entry.type === "ERROR"    ? "part of the scan failed; see omabackup status"
    : ""

  spacing: 0

  Item {
    width: parent.width
    implicitHeight: Math.max(tag.implicitHeight, actions.implicitHeight)

    Text {
      id: tag
      anchors.left: parent.left
      anchors.leftMargin: root.leftInset
      anchors.verticalCenter: parent.verticalCenter
      text: root.entry.type || ""
      color: root.entry.type === "NEW" ? Color.accent
           : root.entry.type === "GONE" ? root.urgent : root.dimColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      anchors.left: tag.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: actions.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: (root.entry.path || "") + (root.entry.note ? "  (" + root.entry.note + ")" : "")
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      AccessibleActionButton {
        visible: root.isActionable
        enabled: !root.busy
        iconText: "󰐕"
        tooltipText: "Add to allowlist (back this up)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.allowRequested(root.entry.path)
      }
      AccessibleActionButton {
        visible: root.isActionable
        enabled: !root.busy
        iconText: "󰈉"
        tooltipText: "Ignore (records a dated decision not to back this up)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.ignoreRequested(root.entry.path)
      }
      AccessibleActionButton {
        visible: root.isGone
        enabled: !root.busy
        iconText: "󰆴"
        tooltipText: "Remove its allowlist entry (path is gone for good)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.goneRequested(root.entry.path, "remove")
      }
      AccessibleActionButton {
        visible: root.isGone && !root.alreadyOptional
        enabled: !root.busy
        iconText: "󰘥"
        tooltipText: "Mark optional (may come back; a missing path stops warning)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.goneRequested(root.entry.path, "optional")
      }
    }
  }

  Text {
    visible: root.explainText.length > 0
    width: parent.width
    leftPadding: root.leftInset
    text: root.explainText
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
}
