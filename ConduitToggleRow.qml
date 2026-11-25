import QtQuick
import qs.Commons
import qs.Commons as Commons

// A setting row: title and one dim line of explanation on the left, a switch
// on the right. Set `width` where it is used.
Item {
  id: root

  property string title: ""
  property string subtitle: ""
  property bool checked: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal toggled()

  readonly property color dim: Qt.darker(foreground, 1.55)

  implicitHeight: Math.max(textColumn.implicitHeight, toggle.implicitHeight)

  Column {
    id: textColumn
    anchors.left: parent.left
    anchors.right: toggle.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      visible: root.subtitle !== ""
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.subtitle
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  ConduitSwitch {
    id: toggle
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: root.checked
    foreground: root.foreground
    onToggled: root.toggled()
  }
}
