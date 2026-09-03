import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// One drift line with its inline triage actions. NEW rows offer Allow/Ignore,
// GONE rows offer Remove/Optional; everything else is information for the
// Full-triage escape hatch. `verdict` marks a decision already taken this
// session (the row stays until the next snapshot rewrites drift.txt).
Column {
  id: root
  property var entry: ({})
  property string verdict: ""          // "", "allowlisted", "ignored", "resolved"
  property bool busy: false
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  signal allowRequested(string path)
  signal ignoreRequested(string path, string reason)
  signal goneRequested(string path, string verb)

  readonly property bool isNew: !verdict && entry.type === "NEW"
  readonly property bool isGone: !verdict && entry.type === "GONE"
  property bool reasonOpen: false

  spacing: Style.spacing.xxs

  Item {
    width: parent.width
    implicitHeight: Math.max(tag.implicitHeight, actions.implicitHeight)

    Text {
      id: tag
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.verdict ? root.verdict.toUpperCase() : (root.entry.type || "")
      color: root.verdict ? root.dimColor
           : root.entry.type === "NEW" ? Color.accent
           : root.entry.type === "GONE" ? root.urgent : root.dimColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !root.verdict
    }

    Text {
      anchors.left: tag.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: actions.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: (root.entry.path || "") + (root.entry.note ? "  (" + root.entry.note + ")" : "")
      textFormat: Text.PlainText
      color: root.verdict ? root.dimColor : root.foreground
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
        tooltipText: "Ignore (record a dated decision not to back this up)"
        foreground: root.reasonOpen ? Color.accent : root.foreground
        fontFamily: root.fontFamily
        onClicked: { root.reasonOpen = !root.reasonOpen; if (root.reasonOpen) Qt.callLater(function() { reasonField.forceActiveFocus() }) }
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

  Row {
    visible: root.reasonOpen
    width: parent.width
    spacing: Style.spacing.sm
    TextField {
      id: reasonField
      width: parent.width
      placeholderText: "why this is not worth backing up · Enter records it, Esc cancels"
      foreground: root.foreground
      font.family: root.fontFamily
      onAccepted: { root.reasonOpen = false; root.ignoreRequested(root.entry.path, text.trim()) }
      Keys.onEscapePressed: root.reasonOpen = false
    }
  }
}
