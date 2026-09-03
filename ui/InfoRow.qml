import QtQuick
import qs.Commons

// One vitals line: dim label on the left, value on the right.
Item {
  id: root
  property string label: ""
  property string value: ""
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
    anchors.right: parent.right
    anchors.left: labelText.right
    anchors.leftMargin: Style.spacing.sm
    horizontalAlignment: Text.AlignRight
    text: root.value
    textFormat: Text.PlainText
    color: root.valueColor ? root.valueColor : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideLeft
  }
}
