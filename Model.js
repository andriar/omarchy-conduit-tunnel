.pragma library

// Pure logic for the tunnel list: validation, parsing the status script output,
// and mapping states and errors to catalog keys. No QML objects in here, so it
// runs under plain `node` in tests/model.test.js.

// `taken` are ids already in use: a new id never repeats one of them.
function newId(taken) {
  var used = taken || []
  var s
  do {
    s = ""
    for (var i = 0; i < 8; i++) s += Math.floor(Math.random() * 16).toString(16)
  } while (used.indexOf(s) >= 0)
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
  if (name === "" || name.length > 40 || /[\u0000-\u001f\u007f]/.test(name)) return "val.name"
  // After the "@" the host may not start with "-" either (it could be read as an option by older ssh).
  if (!/^[A-Za-z0-9._][A-Za-z0-9._:-]*(@[A-Za-z0-9._:][A-Za-z0-9._:-]*)?$/.test(String(t.target))) return "val.target"
  if (!isPort(t.localPort, 1024, 65535)) return "val.localPort"
  if (!/^[A-Za-z0-9._-]+$/.test(String(t.remoteHost))) return "val.remoteHost"
  if (!isPort(t.remotePort, 1, 65535)) return "val.remotePort"
  var list = others || []
  for (var i = 0; i < list.length; i++)
    if (list[i].id !== t.id && Number(list[i].localPort) === Number(t.localPort)) return "val.portTaken"
  // Names must be unique: the command line and IPC pick a tunnel by name.
  for (var j = 0; j < list.length; j++)
    if (list[j].id !== t.id && String(list[j].name).trim() === name) return "val.nameTaken"
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
    // Only a hand-edited file can hold the same id or local port twice: keep the first, and the
    // caller backs the file up because entries were dropped. Names are not checked here, so an
    // older file with two equal names keeps working (it is only refused on the next edit).
    var clash = false
    for (var k = 0; k < out.length; k++)
      if (out[k].id === t.id || out[k].localPort === t.localPort) clash = true
    if (clash) continue
    if (validate(t, []) !== "") continue
    out.push(t)
  }
  return out
}

// ---- Pasting a whole `ssh -L ...` command into the form ----
// The pasted text is only READ into fields. It is never run and never reaches a shell, and
// every field still goes through validate() before anything is saved. What the widget cannot
// represent (-o, -J, -i, -R, -D, a remote command, an SSH port other than 22) is refused by
// name, never dropped silently.

// Does this look like the start of an ssh command? (A leading "$ " from a copied prompt is fine.)
function looksLikeSsh(text) {
  return /^\s*(\$\s+)?(\S*\/)?ssh\s/.test(String(text === undefined ? "" : text))
}

// Split text the way a shell would (quotes, backslash escapes) but expand nothing.
// null when something a shell would act on appears ($var, `cmd`, ; | & < > ( ) { } ! #),
// or when a quote is left open. That is one command, pasted on its own, or nothing.
function shellSplit(s) {
  var out = [], cur = "", has = false, q = ""
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i)
    if (q === "'") { if (c === "'") q = ""; else cur += c; continue }
    if (q === '"') {
      if (c === '"') q = ""
      else if (c === "$" || c === "`") return null
      else if (c === "\\" && (s.charAt(i + 1) === '"' || s.charAt(i + 1) === "\\")) { cur += s.charAt(i + 1); i++ }
      else cur += c
      continue
    }
    if (c === "'" || c === '"') { q = c; has = true; continue }
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      if (has || cur !== "") { out.push(cur); cur = ""; has = false }
      continue
    }
    if (c === "\\") {
      var n = s.charAt(i + 1)
      if (n === "\n" || n === "\r") { i++; continue }  // line continuation
      if (n === "") return null
      cur += n; has = true; i++
      continue
    }
    if ("$`;|&<>(){}!#".indexOf(c) >= 0) return null
    cur += c
  }
  if (q !== "") return null
  if (has || cur !== "") out.push(cur)
  return out
}

function suggestName(host) {
  var n = /^[0-9.]+$/.test(host) ? host : String(host).split(".")[0]
  return n.length > 40 ? n.slice(0, 40) : n
}

// -> { ok: true, target, localPort, remoteHost, remotePort, name, notes: [catalog keys] }
//  | { ok: false, error: catalog key, arg?: text to show in the message }
function parseSshCommand(text) {
  // A prompt that came along with the copy ("$ ssh ...") is dropped. "$HOME" is not a prompt.
  var toks = shellSplit(String(text === undefined ? "" : text).trim().replace(/^[$>](\s+|$)/, ""))
  if (toks === null) return { ok: false, error: "paste.err.unsafe" }
  if (!toks.length || !/^(.*\/)?ssh$/.test(toks[0])) return { ok: false, error: "paste.err.notSsh" }

  var IGNORED = "NfqvTnx46Cg"          // flags that change nothing we care about
  var forwards = [], positional = [], loginUser = "", port = "22", ended = false
  for (var i = 1; i < toks.length; i++) {
    var tok = toks[i]
    if (ended || tok.charAt(0) !== "-" || tok === "-") { positional.push(tok); continue }
    if (tok === "--") { ended = true; continue }
    for (var j = 1; j < tok.length; j++) {
      var ch = tok.charAt(j)
      if (IGNORED.indexOf(ch) >= 0) continue
      if (ch === "L" || ch === "p" || ch === "l") {
        var arg = tok.slice(j + 1)
        if (arg === "") {
          i++
          arg = toks[i]
          if (arg === undefined) return { ok: false, error: "paste.err.option", arg: "-" + ch }
        }
        if (ch === "L") forwards.push(arg)
        else if (ch === "p") port = arg
        else loginUser = arg
        break
      }
      return { ok: false, error: "paste.err.option", arg: "-" + ch }
    }
  }

  if (port !== "22") return { ok: false, error: "paste.err.port", arg: port }
  if (positional.length === 0) return { ok: false, error: "paste.err.noHost" }
  if (positional.length > 1) return { ok: false, error: "paste.err.command" }
  var target = positional[0]
  if (loginUser !== "" && target.indexOf("@") < 0) target = loginUser + "@" + target
  if (forwards.length === 0) return { ok: false, error: "paste.err.noForward" }

  var m = /^(?:(\[[^\]]+\]|[^:\[\]]*):)?([0-9]+):(\[[^\]]+\]|[^:\[\]]+):([0-9]+)$/.exec(forwards[0])
  if (!m) return { ok: false, error: "paste.err.forward", arg: forwards[0] }

  // The widget listens on 127.0.0.1 only. A wider bind address is not carried over.
  var notes = []
  var bind = m[1]
  if (bind !== undefined && bind !== "" && bind !== "127.0.0.1" && bind !== "localhost") notes.push("paste.note.bind")
  if (forwards.length > 1) notes.push("paste.note.more")
  return {
    ok: true, target: target, localPort: Number(m[2]), remoteHost: m[3], remotePort: Number(m[4]),
    name: suggestName(m[3]), notes: notes
  }
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

// Autostart gives a tunnel that failed only because the server could not be reached (no route,
// timeout, name not resolved yet: typical right after login or a resume) a few more tries.
// `retry` maps the ids autostart started to { n: tries so far, at: ms of the last try }.
// Waits 30 s, 60 s, 2 min, 4 min, 8 min and then gives up (a wrong key or a taken port never
// retries: that would not change by waiting). Returns the first id due, or "".
var AUTOSTART_RETRIES = 5
function retryDue(tunnels, states, online, retry, now) {
  if (!online) return ""
  for (var i = 0; i < tunnels.length; i++) {
    var t = tunnels[i]
    var r = retry[t.id]
    if (!r || t.autostart !== true || t.askPassword === true || states[t.id] === undefined) continue
    if (stateOf(states[t.id]) !== "failed") continue
    var key = reasonKey(states[t.id].reason)
    if (key !== "reason.unreachable" && key !== "reason.resolve") continue
    if (r.n >= AUTOSTART_RETRIES) continue
    if (now - r.at >= 30000 * Math.pow(2, r.n)) return t.id
  }
  return ""
}

// Autostart tunnels that are already doing something (running, connecting, failed, in the way).
// The session has dealt with them: if one is stopped later, by hand or from outside, it must
// stay stopped. Without this, a tunnel that was already up when the shell started could be
// switched off and then come back on the next poll.
function handledThisSession(tunnels, states) {
  var ids = []
  for (var i = 0; i < tunnels.length; i++) {
    var t = tunnels[i]
    if (t.autostart === true && states[t.id] !== undefined && stateOf(states[t.id]) !== "down") ids.push(t.id)
  }
  return ids
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
