import QtQuick
import qs.Commons
import qs.Commons as Commons

// On/off switch whose ON state is unmistakable: the whole track takes the
// theme accent, and the knob flips to the background colour.
Item {
  id: root

  property bool checked: false
  property bool busy: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal toggled()

  implicitWidth: Style.space(40)
  implicitHeight: Style.space(22)

  Rectangle {
    id: track
    anchors.fill: parent
    radius: height / 2
    color: root.checked
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
    border.width: 1
    border.color: root.checked
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, mouse.containsMouse ? 0.6 : 0.32)

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Rectangle {
      id: knob
      width: track.height - Style.space(8)
      height: width
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? track.width - width - Style.space(4) : Style.space(4)
      color: root.checked ? Commons.Color.background : root.foreground
      opacity: root.busy ? 0.45 : 1

      Behavior on x {
        NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (!root.busy) root.toggled()
  }
}
