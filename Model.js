.pragma library

// Pure logic for the tunnel list: validation, parsing the status script output,
// and mapping states and errors to catalog keys. No QML objects in here, so it
// runs under plain `node` in tests/model.test.js.

function newId() {
  var s = ""
  for (var i = 0; i < 8; i++) s += Math.floor(Math.random() * 16).toString(16)
  return s
}

function isPort(v, min, max) {
  return /^[0-9]+$/.test(String(v)) && Number(v) >= min && Number(v) <= max
}

// "" when the tunnel is valid, otherwise a catalog key. `others` are the other
// saved tunnels, used to catch a local port that two tunnels would fight over.
// These patterns are deliberately strict: the values end up on an ssh command line.
function validate(t, others) {
  var name = String(t.name === undefined ? "" : t.name).trim()
  if (name === "" || name.length > 40) return "val.name"
  if (!/^[A-Za-z0-9._][A-Za-z0-9._:-]*(@[A-Za-z0-9._:-]+)?$/.test(String(t.target))) return "val.target"
  if (!isPort(t.localPort, 1024, 65535)) return "val.localPort"
  if (!/^[A-Za-z0-9._-]+$/.test(String(t.remoteHost))) return "val.remoteHost"
  if (!isPort(t.remotePort, 1, 65535)) return "val.remotePort"
  var list = others || []
  for (var i = 0; i < list.length; i++)
    if (list[i].id !== t.id && Number(list[i].localPort) === Number(t.localPort)) return "val.portTaken"
  return ""
}

// What came out of tunnels.json -> a safe list. Anything invalid is dropped.
function clean(raw) {
  if (!Array.isArray(raw)) return []
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var r = raw[i] || {}
    var t = {
      id: String(r.id || ""),
      name: String(r.name === undefined ? "" : r.name).trim(),
      target: String(r.target === undefined ? "" : r.target),
      localPort: Number(r.localPort),
      remoteHost: String(r.remoteHost === undefined ? "" : r.remoteHost),
      remotePort: Number(r.remotePort),
      autostart: r.autostart === true,
      askPassword: r.askPassword === true
    }
    if (!/^[0-9a-f]{8}$/.test(t.id)) continue
    if (validate(t, []) !== "") continue
    out.push(t)
  }
  return out
}

// Lines from tunnel-status.sh: T <id> <active> <sub> <restarts> <since> <listening> <reason>
function parsePoll(text) {
  var states = {}
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    if (f[0] !== "T" || f.length < 7 || !/^[0-9a-f]{8}$/.test(f[1])) continue
    states[f[1]] = {
      active: f[2], sub: f[3], restarts: parseInt(f[4]) || 0,
      since: parseInt(f[5]) || 0, listening: f[6] === "1", reason: f.slice(7).join("\t")
    }
  }
  return states
}

// The `N <0|1>` line of tunnel-status.sh: is there a default route (a network at all)?
function parseOnline(text) {
  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t")
    if (f[0] === "N") return f[1] === "1"
  }
  return false
}

// Tunnels to start now: marked "start automatically", not running, polled at least once,
// the network is up, and not tried yet this session (so a failing tunnel is not retried in a
// loop, and one you stopped yourself is not started again). A tunnel that asks for a password
// never starts by itself: a dialog out of nowhere at login would be a surprise.
// Returns ids, in list order.
function dueForAutostart(tunnels, states, online, tried) {
  var due = []
  if (!online) return due
  for (var i = 0; i < tunnels.length; i++) {
    var t = tunnels[i]
    if (t.autostart === true && t.askPassword !== true && !tried[t.id] && states[t.id] !== undefined && stateOf(states[t.id]) === "down")
      due.push(t.id)
  }
  return due
}

// "up" | "connecting" | "failed" | "conflict" | "down"
function stateOf(p) {
  if (!p) return "down"
  if (p.active === "failed") return "failed"
  if (p.active === "active" && p.listening) return "up"
  if (p.active === "active" || p.active === "activating" || p.active === "reloading") return "connecting"
  // Not ours, yet something is listening on the port.
  if (p.listening) return "conflict"
  return "down"
}

function isRunning(state) {
  return state === "up" || state === "connecting"
}

// Catalog key for the last ssh error line ("" when there is none).
function reasonKey(line) {
  var s = String(line || "")
  if (s === "") return ""
  if (/Host key verification failed|IDENTIFICATION HAS CHANGED/i.test(s)) return "reason.hostKey"
  if (/Permission denied/i.test(s)) return "reason.auth"
  if (/Could not resolve|Name or service not known/i.test(s)) return "reason.resolve"
  if (/Address already in use|Could not request local forwarding|bind/i.test(s)) return "reason.portBusy"
  if (/Connection refused|timed out|No route to host|Network is unreachable/i.test(s)) return "reason.unreachable"
  return "reason.generic"
}

// Time online, as { key, a, b } for the "time.*" catalog entries.
function uptime(nowSec, sinceSec) {
  if (!sinceSec) return null
  var s = Math.max(0, nowSec - sinceSec)
  if (s < 60) return { key: "time.justNow" }
  var m = Math.floor(s / 60)
  if (m < 60) return { key: "time.minutes", a: m }
  var h = Math.floor(m / 60)
  m = m % 60
  if (h < 24) return { key: "time.hoursMinutes", a: h, b: (m < 10 ? "0" : "") + m }
  return { key: "time.daysHours", a: Math.floor(h / 24), b: h % 24 }
}

function address(t) {
  return "127.0.0.1:" + t.localPort
}

// Which tunnels just dropped? One that was "up" on the previous poll and is not now,
// unless the user stopped it on purpose or an action on it is still running.
// `prev` (id -> last state) and `manual` (id -> stopped by the user) are updated in place.
function detectDrops(tunnels, states, prev, manual, busyId) {
  var dropped = []
  for (var i = 0; i < tunnels.length; i++) {
    var id = tunnels[i].id
    var st = stateOf(states[id])
    if (st === "up") manual[id] = false
    if (prev[id] === "up" && st !== "up" && !manual[id] && busyId !== id) dropped.push(id)
    prev[id] = st
  }
  return dropped
}
