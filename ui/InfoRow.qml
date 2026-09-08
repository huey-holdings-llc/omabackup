import QtQuick
import qs.Commons

// One vitals line: dim label on the left, value on the right.
//
// Optionally the value acts as a link: set `activatable` and handle
// `activated()`. The row itself knows nothing about what it opens -- no URL,
// no command -- so the one place that decides is the panel, which routes it
// through the CLI like every other action.
Item {
  id: root
  property string label: ""
  property string value: ""
  property bool activatable: false
  // What a screen reader announces for the link; falls back to the value.
  property string activateName: ""
  signal activated()
  // Empty string = inherit foreground; set (e.g. urgent) to colour the value.
  property string valueColor: ""
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  implicitHeight: labelText.implicitHeight

  Text {
    id: labelText
    anchors.left: parent.left
    text: root.label
    color: root.dimColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Text {
    id: valueText
    anchors.right: parent.right
    anchors.left: labelText.right
    anchors.leftMargin: Style.spacing.sm
    horizontalAlignment: Text.AlignRight
    text: root.value
    textFormat: Text.PlainText
    // A link reads as one: underlined, and dimmed a little while the pointer
    // is on it, the same alpha shift ThinScrollBar uses for hover.
    font.underline: root.activatable
    color: root.valueColor ? root.valueColor
         : root.activatable && linkArea.containsMouse ? Qt.darker(root.foreground, 1.25)
         : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideLeft

    Accessible.role: root.activatable ? Accessible.Link : Accessible.StaticText
    Accessible.name: root.activatable && root.activateName ? root.activateName : root.value

    MouseArea {
      id: linkArea
      anchors.fill: parent
      enabled: root.activatable
      visible: root.activatable
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activated()
    }
  }
}
