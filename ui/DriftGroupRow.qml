import QtQuick
import qs.Commons
import qs.Ui

// A folder of drifting NEW files, triaged as one decision: Allow backs up the
// directory (allowlist recurses), Ignore records a dated path/** entry. The
// caret expands the individual files for anyone who wants to look first, or
// to pick out single files instead of taking the whole folder.
Column {
  id: root
  property string path: ""            // "~/dir/" (trailing slash = folder)
  property var entries: []
  property bool busy: false
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  signal allowRequested(string path)
  signal ignoreRequested(string path)
  signal goneRequested(string path, string verb)

  property bool expanded: false
  readonly property int shownChildren: 100

  spacing: Style.spacing.xxs

  Item {
    width: parent.width
    implicitHeight: Math.max(caret.implicitHeight, actions.implicitHeight)

    AccessibleActionButton {
      id: caret
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.expanded ? "󰅀" : "󰅂"
      tooltipText: root.expanded ? "Collapse" : "Show the files in this folder"
      foreground: root.dimColor
      fontFamily: root.fontFamily
      onClicked: root.expanded = !root.expanded
    }

    Text {
      anchors.left: caret.right
      anchors.leftMargin: Style.spacing.xxs
      anchors.right: actions.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: root.path + " · " + root.entries.length + " files"
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideMiddle
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      AccessibleActionButton {
        enabled: !root.busy
        iconText: "󰐕"
        tooltipText: "Allowlist " + root.path + " so every file in it, now and later, is backed up (" + root.entries.length + " here today)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.allowRequested(root.path)
      }
      AccessibleActionButton {
        enabled: !root.busy
        iconText: "󰈉"
        tooltipText: "Never back up anything under " + root.path + ", now or later (records a dated " + root.path + "** decision)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.ignoreRequested(root.path)
      }
    }
  }

  Column {
    visible: root.expanded
    width: parent.width
    spacing: Style.spacing.xxs
    Repeater {
      model: root.expanded ? root.entries.slice(0, root.shownChildren) : []
      delegate: DriftRow {
        required property var modelData
        width: parent.width
        leftInset: caret.width + Style.spacing.xxs
        entry: modelData
        busy: root.busy
        foreground: root.foreground
        dimColor: root.dimColor
        urgent: root.urgent
        fontFamily: root.fontFamily
        onAllowRequested: function(path) { root.allowRequested(path) }
        onIgnoreRequested: function(path) { root.ignoreRequested(path) }
        onGoneRequested: function(path, verb) { root.goneRequested(path, verb) }
      }
    }
    Text {
      visible: root.entries.length > root.shownChildren
      width: parent.width
      text: "… and " + (root.entries.length - root.shownChildren) + " more in this folder"
      color: root.dimColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
