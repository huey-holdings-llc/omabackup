import QtQuick
import qs.Commons
import qs.Ui

// One drift line with its inline triage actions. NEW rows offer Allow/Ignore,
// GONE rows offer Remove/Optional; everything else is information for the
// Full-triage escape hatch. Whether Ignore asks for a note first is the
// panel's business (the shared note field), not this row's.
Item {
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
      visible: root.isNew
      enabled: !root.busy
      iconText: "󰐕"
      tooltipText: "Add to allowlist (back this up)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.allowRequested(root.entry.path)
    }
    AccessibleActionButton {
      visible: root.isNew
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
      visible: root.isGone
      enabled: !root.busy
      iconText: "󰘥"
      tooltipText: "Mark optional (may come back; a missing path stops warning)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.goneRequested(root.entry.path, "optional")
    }
  }
}
