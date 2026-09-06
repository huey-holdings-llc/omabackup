import QtQuick
import qs.Commons
import qs.Ui

// One drift line with its inline triage actions. Every class the engine's
// allow/ignore gate accepts -- NEW, MODIFIED, TOOBIG, EXCLUDED -- offers
// Allow/Ignore; GONE rows offer Remove and (unless the entry is already
// optional) Mark optional; only ERROR is button-less, because there is
// nothing to decide about a scan that did not finish. The classes that need
// explaining carry one line above the buttons. Whether Ignore asks for a note
// first is the panel's business (the shared note field), not this row's.
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

  readonly property bool isGone: entry.type === "GONE"
  // EXACTLY the classes lib/widget.sh's gate accepts for allow and ignore.
  // docs/triage.md tells you to allow a stock file you have edited on
  // purpose, and a collapsed ">2000 files" TOOBIG row is the single case the
  // subtree-ignore shape exists for, so a row without those buttons was the
  // only place saying they could not be taken.
  readonly property bool isActionable: entry.type === "NEW" || entry.type === "MODIFIED"
                                    || entry.type === "TOOBIG" || entry.type === "EXCLUDED"
  // An entry that is already optional cannot be marked optional again: the
  // engine refuses it now, and the button that always did nothing goes away.
  readonly property bool alreadyOptional: entry.optional === true
  // The report's trailing slash, which the JSON path no longer carries. Allow
  // on a folder decides for everything put in it later, and "back this up"
  // does not say that.
  readonly property bool isDir: entry.dir === true

  readonly property string explainText:
      entry.type === "TOOBIG"   ? "too many files to scan; allowlist the folder or ignore it"
    : entry.type === "EXCLUDED" ? "matched by .gitignore; edit the allowlist entry"
    : entry.type === "ERROR"    ? "part of the scan failed; see omabackup status"
    : ""

  spacing: 0

  // Above the line it explains, and therefore above the buttons: a reader
  // meets the reason before the two irreversible-looking things they can do
  // about it.
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
        tooltipText: root.isDir
          ? "Back up this folder and everything under it, now and later"
          : "Add to allowlist (back this up)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.allowRequested(root.entry.path)
      }
      AccessibleActionButton {
        visible: root.isActionable
        enabled: !root.busy
        iconText: "󰈉"
        tooltipText: root.isDir
          ? "Never back up anything under this folder (records a dated decision)"
          : "Ignore (records a dated decision not to back this up)"
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
}
