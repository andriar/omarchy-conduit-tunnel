import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// SSH tunnel manager for the bar. Each tunnel is an `ssh -N -L` port forward run as a
// transient systemd --user service (see scripts/tunnel-ctl.sh), so it survives the
// shell restarting and is restarted by systemd when it drops. Design rules: DESIGN.md
// in omarchy-conduit-vpn.
//
//   bar icon      : open the list
//   row switch    : start / stop the tunnel
//   row copy icon : copy 127.0.0.1:<port> (tunnel is up)
//   row gear      : edit or delete
//   header +      : add a tunnel
Panel {
  id: root
  moduleName: "conduit.tunnel"
  ipcTarget: "conduit.tunnel"
  manageIpc: false

  readonly property int refreshSec: Math.max(1, Number(setting("refreshIntervalSec", 3)))

  // [{ id, name, target, localPort, remoteHost, remotePort }] saved in tunnels.json
  property var tunnels: []
  // id -> { active, sub, restarts, since, listening, reason } from the status script
  property var states: ({})
  property double nowMs: 0
  property string busyId: ""

  // "list" | "edit"
  property string view: "list"
  property string editId: ""
  property string formError: ""
  property bool saving: false
  property bool confirmDelete: false
  property bool startAfterSave: false

  property string statusText: ""
  property bool statusError: false

  // For "tunnel dropped" notifications: only a tunnel that was up and that the user
  // did not stop on purpose counts.
  property var prevState: ({})
  property var manualStop: ({})

  readonly property string i18nDir: String(Qt.resolvedUrl("i18n")).replace(/^qs:\/\//, "")
  readonly property string scriptsDir: String(Qt.resolvedUrl("scripts")).replace(/^file:\/\//, "")
  Commons.Translations { id: strings; directory: root.i18nDir }

  readonly property Item nameFieldItem: panel.loadedContent ? panel.loadedContent.nameField : null
  readonly property Item serverFieldItem: panel.loadedContent ? panel.loadedContent.serverField : null
  readonly property Item localFieldItem: panel.loadedContent ? panel.loadedContent.localField : null
  readonly property Item hostFieldItem: panel.loadedContent ? panel.loadedContent.hostField : null
  readonly property Item portFieldItem: panel.loadedContent ? panel.loadedContent.portField : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var upNames: {
    var names = []
    for (var i = 0; i < tunnels.length; i++)
      if (Model.stateOf(states[tunnels[i].id]) === "up") names.push(tunnels[i].name)
    return names
  }
  readonly property bool anyUp: upNames.length > 0
  readonly property bool anyConnecting: {
    for (var i = 0; i < tunnels.length; i++)
      if (Model.stateOf(states[tunnels[i].id]) === "connecting") return true
    return false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- helpers -------------------------------------------------------------

  function tunnelById(id) {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].id === id) return tunnels[i]
    return null
  }

  // A tunnel by id or by exact name (for the IPC commands below).
  function findTunnel(key) {
    for (var i = 0; i < tunnels.length; i++)
      if (tunnels[i].id === key || tunnels[i].name === key) return tunnels[i]
    return null
  }

  function stateOfId(id) {
    return Model.stateOf(states[id])
  }

  function setStatus(text, isError) {
    root.statusText = text
    root.statusError = isError
  }

  function reasonText(t, s) {
    var key = Model.reasonKey(s ? s.reason : "")
    if (key === "") return ""
    if (key === "reason.hostKey") return strings.t(key).arg(t.target)
    if (key === "reason.generic") return strings.t(key).arg(s.reason)
    return strings.t(key)
  }

  function uptimeText(s) {
    var u = Model.uptime(Math.floor(root.nowMs / 1000), s ? s.since : 0)
    if (!u) return ""
    var text = strings.t(u.key)
    if (u.a !== undefined) text = text.arg(u.a)
    if (u.b !== undefined) text = text.arg(u.b)
    return text
  }

  // The second line of a row, and whether it is a problem.
  function subtitleOf(t) {
    var s = root.states[t.id]
    var st = Model.stateOf(s)
    var addr = Model.address(t)
    if (st === "up") {
      var parts = [strings.t("state.connected"), addr]
      var up = root.uptimeText(s)
      if (up !== "") parts.push(up)
      return parts.join(" · ")
    }
    var why = root.reasonText(t, s)
    if (st === "failed") return why !== "" ? why : strings.t("state.failed")
    if (st === "conflict") return strings.t("state.portBusy").arg(t.localPort)
    if (st === "connecting") return why !== "" ? why : strings.t("state.connecting") + " · " + addr
    return strings.t("state.stopped") + " · " + addr
  }

  function isProblem(t) {
    var st = root.stateOfId(t.id)
    if (st === "failed" || st === "conflict") return true
    return st === "connecting" && root.reasonText(t, root.states[t.id]) !== ""
  }

  // ---- status polling ------------------------------------------------------

  function refresh() {
    if (pollProc.running || !root.loaded) return
    var specs = []
    for (var i = 0; i < tunnels.length; i++) specs.push(tunnels[i].id + ":" + tunnels[i].localPort)
    pollProc.environment = { "SPECS": specs.join(" ") }
    pollProc.running = true
  }

  property bool loaded: false

  function onPolled(text) {
    root.states = Model.parsePoll(text)
    root.nowMs = Date.now()
    var dropped = Model.detectDrops(root.tunnels, root.states, root.prevState, root.manualStop, root.busyId)
    for (var i = 0; i < dropped.length; i++) {
      var t = root.tunnelById(dropped[i])
      Quickshell.execDetached(["notify-send", "-u", "critical", strings.t("notice.droppedTitle"),
        strings.t("notice.dropped").arg(t.name).arg(root.reasonText(t, root.states[t.id]))])
    }
  }

  // ---- start / stop --------------------------------------------------------

  function runCtl(act, t) {
    if (ctlProc.running || !t) return
    root.busyId = t.id
    setStatus("", false)
    root.manualStop[t.id] = act === "stop"
    ctlProc.command = ["bash", root.scriptsDir + "/tunnel-ctl.sh", act]
    ctlProc.environment = {
      "TID": t.id, "TARGET": t.target, "LP": String(t.localPort),
      "RH": t.remoteHost, "RP": String(t.remotePort)
    }
    ctlProc.running = true
  }

  function toggleTunnel(t) {
    runCtl(Model.isRunning(root.stateOfId(t.id)) ? "stop" : "start", t)
  }

  function copyAddress(t) {
    var addr = Model.address(t)
    Quickshell.execDetached(["wl-copy", addr])
    Quickshell.execDetached(["notify-send", "-t", "2000", "Conduit", strings.t("notice.copied").arg(addr)])
  }

  // ---- add / edit ----------------------------------------------------------

  function openEdit(id) {
    root.editId = id
    root.formError = ""
    root.confirmDelete = false
    root.view = "edit"
    Qt.callLater(function() { root.fillForm(id) })
  }

  function fillForm(id) {
    if (root.view !== "edit") return
    if (!nameFieldItem || !serverFieldItem || !localFieldItem || !hostFieldItem || !portFieldItem) {
      Qt.callLater(function() { root.fillForm(id) })
      return
    }
    var t = id !== "" ? root.tunnelById(id) : null
    nameFieldItem.text = t ? t.name : ""
    serverFieldItem.text = t ? t.target : ""
    localFieldItem.text = t ? String(t.localPort) : ""
    hostFieldItem.text = t ? t.remoteHost : ""
    portFieldItem.text = t ? String(t.remotePort) : ""
    nameFieldItem.forceActiveFocus()
  }

  function closeEdit() {
    root.view = "list"
    root.confirmDelete = false
    root.formError = ""
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  function summaryText() {
    if (!nameFieldItem) return ""
    var server = String(serverFieldItem.text).trim()
    var host = String(hostFieldItem.text).trim()
    if (server === "" || host === "" || String(localFieldItem.text) === "" || String(portFieldItem.text) === "") return ""
    return strings.t("form.summary").arg(localFieldItem.text).arg(host).arg(portFieldItem.text).arg(server)
  }

  function saveForm(startAfter) {
    if (saveProc.running || !nameFieldItem) return
    var candidate = {
      id: root.editId !== "" ? root.editId : Model.newId(),
      name: String(nameFieldItem.text).trim(),
      target: String(serverFieldItem.text).trim(),
      localPort: String(localFieldItem.text).trim(),
      remoteHost: String(hostFieldItem.text).trim(),
      remotePort: String(portFieldItem.text).trim()
    }
    var key = Model.validate(candidate, root.tunnels)
    if (key !== "") {
      root.formError = key === "val.portTaken" ? strings.t(key).arg(candidate.localPort) : strings.t(key)
      return
    }
    candidate.localPort = Number(candidate.localPort)
    candidate.remotePort = Number(candidate.remotePort)

    var list = root.tunnels.slice()
    var found = false
    for (var i = 0; i < list.length; i++) if (list[i].id === candidate.id) { list[i] = candidate; found = true }
    if (!found) list.push(candidate)

    root.formError = ""
    root.saving = true
    root.tunnels = list
    root.startAfterSave = startAfter === true
    root.pendingStart = candidate.id
    root.persist()
  }

  property string pendingStart: ""

  function persist() {
    saveProc.environment = { "TUNNELS_JSON": JSON.stringify(root.tunnels, null, 2) }
    saveProc.running = true
  }

  function deleteFromForm() {
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    var t = root.tunnelById(root.editId)
    if (!t) { closeEdit(); return }
    // Stop it first so no orphan service keeps a port open.
    root.manualStop[t.id] = true
    stopThenForget.environment = { "TID": t.id }
    stopThenForget.running = true
  }

  // ---- reopen -------------------------------------------------------------

  onOpenedChanged: if (opened) {
    view = "list"
    setStatus("", false)
    refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Component.onCompleted: loadProc.running = true

  // ---- processes -----------------------------------------------------------

  Process {
    id: loadProc
    command: ["bash", "-c", "cat \"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-conduit-tunnel/tunnels.json\" 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = []
        try { raw = JSON.parse(String(text) || "[]") } catch (e) { raw = [] }
        root.tunnels = Model.clean(raw)
        root.loaded = true
        root.refresh()
      }
    }
  }

  Process {
    id: saveProc
    // The file holds hostnames, so it is private to the user (umask 077) and replaced atomically.
    command: [
      "bash", "-c",
      "umask 077; d=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-conduit-tunnel\"; mkdir -p \"$d\" && " +
      "tmp=$(mktemp \"$d/.tunnels.XXXXXX\") && printf '%s\\n' \"$TUNNELS_JSON\" > \"$tmp\" && mv \"$tmp\" \"$d/tunnels.json\""
    ]
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        Quickshell.execDetached(["notify-send", "-u", "critical", "Conduit", strings.t("notice.saveFailed")])
        loadProc.running = true
        return
      }
      var id = root.pendingStart
      root.pendingStart = ""
      root.closeEdit()
      var t = root.tunnelById(id)
      if (t && (root.startAfterSave || Model.isRunning(root.stateOfId(id)))) {
        // A running tunnel is restarted so the new settings take effect.
        root.runCtl("restart", t)
      }
      root.refresh()
    }
  }

  Process {
    id: stopThenForget
    command: ["bash", "-c", "bash \"$1/tunnel-ctl.sh\" stop", "_", root.scriptsDir]
    onExited: function(exitCode) {
      root.tunnels = root.tunnels.filter(function(t) { return t.id !== root.editId })
      root.persist()
      root.closeEdit()
      root.refresh()
    }
  }

  Process {
    id: pollProc
    command: ["bash", root.scriptsDir + "/tunnel-status.sh"]
    stdout: StdioCollector {
      onStreamFinished: root.onPolled(text)
    }
  }

  Process {
    id: ctlProc
    stderr: StdioCollector {
      id: ctlErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var id = root.busyId
      root.busyId = ""
      if (exitCode !== 0) {
        var t = root.tunnelById(id)
        var msg = strings.t("notice.startFailed").arg(t ? t.name : id).arg(String(ctlErr.text).trim().substring(0, 160))
        root.setStatus(msg, true)
        Quickshell.execDetached(["notify-send", "-u", "critical", "Conduit", msg])
      }
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Command line and keybinding access:
  //   omarchy-shell conduit.tunnel start "<name or id>"
  //   omarchy-shell conduit.tunnel stop "<name or id>"
  //   omarchy-shell conduit.tunnel status
  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function start(key: string): string {
      var t = root.findTunnel(key)
      if (!t) return "unknown tunnel: " + key
      root.runCtl("start", t)
      return "starting " + t.name
    }

    function stop(key: string): string {
      var t = root.findTunnel(key)
      if (!t) return "unknown tunnel: " + key
      root.runCtl("stop", t)
      return "stopping " + t.name
    }

    function status(): string {
      var lines = []
      for (var i = 0; i < root.tunnels.length; i++) {
        var t = root.tunnels[i]
        lines.push(t.id + "\t" + t.name + "\t" + root.stateOfId(t.id) + "\t" + Model.address(t))
      }
      return lines.join("\n")
    }
  }

  // ---- bar icon ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.anyUp
    activeColor: Commons.Color.accent
    opacity: root.busyId !== "" || root.anyConnecting ? 0.5 : (root.anyUp ? 1.0 : 0.7)
    tooltipText: root.anyUp
      ? strings.t("bar.up").arg(root.upNames.join(", "))
      : (root.anyConnecting ? strings.t("bar.connecting") : strings.t("bar.down"))
    onPressed: function(buttonCode) { root.toggle() }
  }

  // ---- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias nameField: nameField
      property alias serverField: serverField
      property alias localField: localField
      property alias hostField: hostField
      property alias portField: portField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      // The text fields own the keyboard while the form is open.
      blocked: root.view !== "list"
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)
        // Shared horizontal inset so the title, rows and buttons line up.
        property int inset: Style.space(10)

        // ================= list view =================

        Item {
          visible: root.view === "list"
          width: parent.width
          height: Math.max(listTitle.implicitHeight, addButton.implicitHeight) + Style.space(2)

          Text {
            id: listTitle
            anchors.left: parent.left
            anchors.leftMargin: column.inset
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: strings.t("list.title")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          PanelActionButton {
            id: addButton
            anchors.right: parent.right
            anchors.rightMargin: column.inset - Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: strings.t("tip.add")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openEdit("")
          }
        }

        Text {
          visible: root.view === "list" && root.statusText !== ""
          textFormat: Text.PlainText
          width: parent.width
          leftPadding: column.inset
          rightPadding: column.inset
          wrapMode: Text.WordWrap
          color: root.statusError ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.statusText
        }

        Text {
          visible: root.view === "list" && root.tunnels.length === 0
          textFormat: Text.PlainText
          width: parent.width
          leftPadding: column.inset
          rightPadding: column.inset
          bottomPadding: Style.space(6)
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: strings.t("list.empty")
        }

        Column {
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.tunnels

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property string st: root.stateOfId(modelData.id)
              readonly property bool isUp: st === "up"
              readonly property bool isBusy: root.busyId === modelData.id || st === "connecting"

              width: parent.width
              height: Style.space(52)
              radius: Style.cornerRadius
              color: row.isUp
                ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12)
                : (rowMouse.containsMouse
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                    : "transparent")

              // An up tunnel carries an accent bar on the left edge.
              Rectangle {
                visible: row.isUp
                width: Style.space(3)
                height: parent.height
                radius: width / 2
                color: Commons.Color.accent
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.toggleTunnel(row.modelData)
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: column.inset
                anchors.right: controls.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: row.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.isUp
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.subtitleOf(row.modelData)
                  color: row.isUp ? Commons.Color.accent : (root.isProblem(row.modelData) ? root.urgent : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Row {
                id: controls
                anchors.right: parent.right
                anchors.rightMargin: column.inset
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: strings.t("tip.copy")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: row.isUp
                  onClicked: root.copyAddress(row.modelData)
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: strings.t("tip.settings")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openEdit(row.modelData.id)
                }

                ConduitSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: row.isUp || row.st === "connecting"
                  busy: row.isBusy
                  foreground: root.foreground
                  onToggled: root.toggleTunnel(row.modelData)
                }
              }
            }
          }
        }

        // ================= add / edit view =================

        Row {
          visible: root.view === "edit"
          width: parent.width
          spacing: Style.space(8)

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: strings.t("tip.back")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.closeEdit()
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            width: parent.width - Style.space(40)
            elide: Text.ElideRight
            text: root.editId !== "" && root.tunnelById(root.editId) ? root.tunnelById(root.editId).name : strings.t("form.titleNew")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Column {
          visible: root.view === "edit"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("form.name")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: nameField
            width: parent.width
            enabled: !root.saving
            placeholderText: strings.t("form.namePlaceholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: serverField.forceActiveFocus()
            Keys.onEscapePressed: root.closeEdit()
          }
        }

        Column {
          visible: root.view === "edit"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("form.server")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: serverField
            width: parent.width
            enabled: !root.saving
            placeholderText: strings.t("form.serverPlaceholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: localField.forceActiveFocus()
            Keys.onEscapePressed: root.closeEdit()
          }
        }

        // local port | remote host | remote port: reads like 127.0.0.1:[port] -> [host]:[port]
        Row {
          id: endpoints
          visible: root.view === "edit"
          width: parent.width
          spacing: Style.space(8)
          readonly property real portWidth: Style.space(92)

          Column {
            width: endpoints.portWidth
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: strings.t("form.localPort")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: localField
              width: parent.width
              enabled: !root.saving
              placeholderText: "5432"
              inputMethodHints: Qt.ImhDigitsOnly
              maximumLength: 5
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onAccepted: hostField.forceActiveFocus()
              Keys.onEscapePressed: root.closeEdit()
            }
          }

          Column {
            width: parent.width - endpoints.portWidth * 2 - endpoints.spacing * 2
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: strings.t("form.remoteHost")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: hostField
              width: parent.width
              enabled: !root.saving
              placeholderText: strings.t("form.remoteHostPlaceholder")
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onAccepted: portField.forceActiveFocus()
              Keys.onEscapePressed: root.closeEdit()
            }
          }

          Column {
            width: endpoints.portWidth
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: strings.t("form.remotePort")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: portField
              width: parent.width
              enabled: !root.saving
              placeholderText: "5432"
              inputMethodHints: Qt.ImhDigitsOnly
              maximumLength: 5
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              onAccepted: root.saveForm(true)
              Keys.onEscapePressed: root.closeEdit()
            }
          }
        }

        Text {
          visible: root.view === "edit" && root.summaryText() !== ""
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.summaryText()
        }

        Text {
          visible: root.view === "edit" && root.formError !== ""
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.formError
        }

        Row {
          visible: root.view === "edit"
          spacing: Style.space(8)

          ConduitButton {
            text: root.saving ? strings.t("form.saving") : strings.t("form.saveStart")
            primary: true
            enabled: !root.saving
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveForm(true)
          }

          ConduitButton {
            text: strings.t("form.save")
            enabled: !root.saving
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveForm(false)
          }
        }

        // Destructive action, kept apart from the save buttons (existing tunnels only).
        Rectangle {
          visible: root.view === "edit" && root.editId !== ""
          width: parent.width
          height: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
        }

        Item {
          visible: root.view === "edit" && root.editId !== ""
          width: parent.width
          height: deleteButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: strings.t("form.deleteLabel")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ConduitButton {
            id: deleteButton
            anchors.right: parent.right
            text: root.confirmDelete ? strings.t("form.deleteConfirm") : strings.t("form.delete")
            danger: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.deleteFromForm()
          }
        }
      }
    }
  }
}
