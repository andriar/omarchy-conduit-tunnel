import QtQuick
import qs.Commons
import qs.Commons as Commons

// Text button with three clear roles:
//   primary   : filled with the theme accent (the one main action of a view)
//   (default) : outlined, secondary
//   danger    : outlined in the urgent colour, for destructive actions
Rectangle {
  id: root

  property string text: ""
  property bool primary: false
  property bool danger: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property color tone: danger ? urgent : accent

  implicitHeight: Style.space(32)
  implicitWidth: label.implicitWidth + Style.space(28)
  radius: Style.cornerRadius
  opacity: enabled ? 1 : 0.45

  color: primary
    ? (mouse.pressed ? Qt.darker(accent, 1.2) : (mouse.containsMouse ? Qt.lighter(accent, 1.12) : accent))
    : (mouse.containsMouse ? Qt.rgba(tone.r, tone.g, tone.b, 0.14) : "transparent")
  border.width: primary ? 0 : 1
  border.color: danger
    ? urgent
    : Qt.rgba(foreground.r, foreground.g, foreground.b, mouse.containsMouse ? 0.65 : 0.38)

  Behavior on color { ColorAnimation { duration: Style.duration(120) } }

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.primary ? Commons.Color.background : (root.danger ? root.urgent : root.foreground)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.primary
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.enabled
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
