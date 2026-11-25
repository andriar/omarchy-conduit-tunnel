// Run with: node tests/model.test.js
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const M = new Function(src + "\nreturn { newId, validate, clean, parsePoll, stateOf, isRunning, reasonKey, uptime, address, detectDrops, parseOnline, dueForAutostart };")();

let pass = 0, fail = 0;
const eq = (a, b, m) => { const ok = JSON.stringify(a) === JSON.stringify(b); ok ? pass++ : fail++; console.log((ok ? "PASS " : "FAIL ") + m + (ok ? "" : `  got ${JSON.stringify(a)} want ${JSON.stringify(b)}`)); };

const good = { id: "aaaaaaaa", name: "Staging DB", target: "user@bastion.example.com", localPort: 5432, remoteHost: "db.internal.example", remotePort: 5432 };
const v = (over, others) => M.validate({ ...good, ...over }, others);

// validation
eq(v({}), "", "valid tunnel");
eq(v({ target: "bastion" }), "", "ssh_config alias is fine");
eq(v({ name: "  " }), "val.name", "blank name");
eq(v({ name: "x".repeat(41) }), "val.name", "name too long");
for (const bad of ["-oProxyCommand=evil", "--help", "a b", "a;b", "$(id)", "a`b`", "a|b", "", "user@host:22 -o X=y", "@@"])
  eq(v({ target: bad }), "val.target", "target rejected: " + JSON.stringify(bad));
for (const ok of ["host", "user@host", "user@10.0.0.5", "my-alias", "user@host.example.com"])
  eq(v({ target: ok }), "", "target accepted: " + ok);
eq(v({ localPort: 80 }), "val.localPort", "privileged local port");
eq(v({ localPort: 1023 }), "val.localPort", "1023 rejected");
eq(v({ localPort: 1024 }), "", "1024 accepted");
eq(v({ localPort: 65535 }), "", "65535 accepted");
eq(v({ localPort: 65536 }), "val.localPort", "65536 rejected");
eq(v({ localPort: "54x" }), "val.localPort", "non-numeric port");
eq(v({ localPort: "" }), "val.localPort", "empty port");
for (const bad of ["db host", "db/host", "db;rm", "", "-x y", "$(x)"]) eq(v({ remoteHost: bad }), "val.remoteHost", "remote host rejected: " + JSON.stringify(bad));
eq(v({ remotePort: 0 }), "val.remotePort", "remote port 0");
eq(v({ remotePort: 70000 }), "val.remotePort", "remote port too big");
eq(v({ remotePort: 22 }), "", "remote port 22 fine");
eq(v({ localPort: 5432 }, [{ id: "bbbbbbbb", localPort: 5432 }]), "val.portTaken", "two tunnels, same local port");
eq(v({ localPort: 5432 }, [{ id: "aaaaaaaa", localPort: 5432 }]), "", "editing a tunnel does not clash with itself");

// clean(): only valid entries survive, ports become numbers
const cleaned = M.clean([good, { ...good, id: "zzzz" }, { ...good, id: "bbbbbbbb", target: "-oX=y" }, null, { ...good, id: "cccccccc", localPort: "6543", remotePort: "5432", name: " Prod " }, "x"]);
eq(cleaned.map(t => t.id), ["aaaaaaaa", "cccccccc"], "clean() drops invalid entries");
eq([cleaned[1].localPort, cleaned[1].name], [6543, "Prod"], "clean() coerces ports and trims names");
eq(M.clean({ not: "an array" }), [], "clean() of a non-array");

// ids
const ids = new Set(Array.from({ length: 200 }, M.newId));
eq([...ids].every(i => /^[0-9a-f]{8}$/.test(i)) && ids.size > 190, true, "newId() is 8 hex chars and varies");

// status script output
const poll = M.parsePoll("T\taaaaaaaa\tactive\trunning\t0\t1700000000\t1\t\nT\tbbbbbbbb\tfailed\tfailed\t5\t0\t0\tPermission denied (publickey).\nbad line\nT\tshort\nT\tnothex!!\tactive\trunning\t0\t0\t0\t\n");
eq(Object.keys(poll), ["aaaaaaaa", "bbbbbbbb"], "parsePoll skips malformed lines");
eq(poll.bbbbbbbb.reason, "Permission denied (publickey).", "parsePoll keeps the reason");
eq(poll.aaaaaaaa.listening, true, "parsePoll reads listening");

// states
eq(M.stateOf(poll.aaaaaaaa), "up", "active + listening = up");
eq(M.stateOf({ active: "active", listening: false }), "connecting", "active, not listening = connecting");
eq(M.stateOf({ active: "activating", listening: false }), "connecting", "auto-restart = connecting");
eq(M.stateOf(poll.bbbbbbbb), "failed", "failed");
eq(M.stateOf({ active: "inactive", listening: false }), "down", "inactive = down");
eq(M.stateOf({ active: "inactive", listening: true }), "conflict", "inactive but port busy = conflict");
eq(M.stateOf(undefined), "down", "unknown = down");
eq([M.isRunning("up"), M.isRunning("connecting"), M.isRunning("down"), M.isRunning("failed")], [true, true, false, false], "isRunning");

// reasons
const rk = (s) => M.reasonKey(s);
eq(rk("Host key verification failed."), "reason.hostKey", "host key");
eq(rk("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"), "reason.hostKey", "host key changed");
eq(rk("user@host: Permission denied (publickey)."), "reason.auth", "auth");
eq(rk("ssh: Could not resolve hostname bastion: Name or service not known"), "reason.resolve", "resolve");
eq(rk("bind [127.0.0.1]:5432: Address already in use"), "reason.portBusy", "port busy");
eq(rk("ssh: connect to host x port 22: Connection refused"), "reason.unreachable", "refused");
eq(rk("ssh: connect to host x port 22: Connection timed out"), "reason.unreachable", "timeout");
eq(rk("something odd"), "reason.generic", "generic");
eq(rk(""), "", "no reason");

// uptime
eq(M.uptime(1000, 0), null, "no start time");
eq(M.uptime(1030, 1000), { key: "time.justNow" }, "under a minute");
eq(M.uptime(1000 + 11 * 60, 1000), { key: "time.minutes", a: 11 }, "minutes");
eq(M.uptime(1000 + 3 * 3600 + 5 * 60, 1000), { key: "time.hoursMinutes", a: 3, b: "05" }, "hours");
eq(M.uptime(1000 + 50 * 3600, 1000), { key: "time.daysHours", a: 2, b: 2 }, "days");
eq(M.address(good), "127.0.0.1:5432", "address");

// autostart flag survives clean(), and only a real `true` counts
eq(M.clean([{ ...good, autostart: true }])[0].autostart, true, "clean() keeps autostart: true");
eq(M.clean([good])[0].autostart, false, "autostart defaults to false");
eq(M.clean([{ ...good, autostart: "true" }])[0].autostart, false, 'autostart "true" (a string) is not true');

// askPassword flag: same strictness as autostart
eq(M.clean([{ ...good, askPassword: true }])[0].askPassword, true, "clean() keeps askPassword: true");
eq(M.clean([good])[0].askPassword, false, "askPassword defaults to false");
eq(M.clean([{ ...good, askPassword: "true" }])[0].askPassword, false, 'askPassword "true" (a string) is not true');
eq(M.clean([{ ...good, askPassword: 1 }])[0].askPassword, false, "askPassword 1 is not true");

// the online line of the status script
eq(M.parseOnline("T\taaaaaaaa\tactive\trunning\t0\t0\t1\t\nN\t1\n"), true, "online = 1");
eq(M.parseOnline("N\t0\n"), false, "online = 0");
eq(M.parseOnline("T\taaaaaaaa\tactive\trunning\t0\t0\t1\t\n"), false, "no N line means offline");

// a tunnel that asks for a password never starts by itself, even if autostart is set
{
  const pw = { id: "dddddddd", autostart: true, askPassword: true }, key = { id: "eeeeeeee", autostart: true, askPassword: false };
  const down = { active: "inactive", listening: false };
  eq(M.dueForAutostart([pw, key], { dddddddd: down, eeeeeeee: down }, true, {}), ["eeeeeeee"], "askPassword tunnels are never autostarted");
}

// what to start automatically
{
  const a = { id: "aaaaaaaa", autostart: true }, b = { id: "bbbbbbbb", autostart: false }, c = { id: "cccccccc", autostart: true };
  const down = { active: "inactive", listening: false };
  const st = { aaaaaaaa: down, bbbbbbbb: down, cccccccc: down };
  eq(M.dueForAutostart([a, b, c], st, true, {}), ["aaaaaaaa", "cccccccc"], "autostart tunnels that are down, in list order");
  eq(M.dueForAutostart([a, b, c], st, false, {}), [], "nothing while offline");
  eq(M.dueForAutostart([a, b, c], {}, true, {}), [], "nothing before the first poll");
  eq(M.dueForAutostart([a, b, c], st, true, { aaaaaaaa: true }), ["cccccccc"], "a tunnel tried this session is not tried again");
  eq(M.dueForAutostart([a], { aaaaaaaa: { active: "active", listening: true } }, true, {}), [], "already up: leave it");
  eq(M.dueForAutostart([a], { aaaaaaaa: { active: "activating", listening: false } }, true, {}), [], "already connecting: leave it");
  eq(M.dueForAutostart([a], { aaaaaaaa: { active: "failed", listening: false } }, true, {}), [], "failed (gave up): do not loop");
  eq(M.dueForAutostart([a], { aaaaaaaa: { active: "inactive", listening: true } }, true, {}), [], "port taken by another program: do not start");
}

// drop detection
{
  const tn = [{ id: "aaaaaaaa" }, { id: "bbbbbbbb" }];
  const up = { aaaaaaaa: { active: "active", listening: true }, bbbbbbbb: { active: "active", listening: true } };
  const prev = {}, manual = {};
  eq(M.detectDrops(tn, up, prev, manual, ""), [], "first poll: nothing dropped");
  const half = { aaaaaaaa: { active: "activating", listening: false }, bbbbbbbb: up.bbbbbbbb };
  eq(M.detectDrops(tn, half, prev, manual, ""), ["aaaaaaaa"], "up -> connecting is a drop");
  eq(M.detectDrops(tn, half, prev, manual, ""), [], "a drop is reported once");
  const failed = { aaaaaaaa: { active: "failed", listening: false }, bbbbbbbb: up.bbbbbbbb };
  eq(M.detectDrops(tn, failed, prev, manual, ""), [], "connecting -> failed is not a second drop");
  M.detectDrops(tn, up, prev, manual, "");
  manual.bbbbbbbb = true; const gone = { aaaaaaaa: up.aaaaaaaa };
  eq(M.detectDrops(tn, gone, prev, manual, ""), [], "stopped by the user: no notification");
  M.detectDrops(tn, up, prev, manual, "");
  eq(M.detectDrops(tn, gone, prev, manual, "bbbbbbbb"), [], "an action on it is running: no notification");
  M.detectDrops(tn, up, prev, manual, "");
  eq(M.detectDrops(tn, {}, prev, manual, ""), ["aaaaaaaa", "bbbbbbbb"], "unit vanished: both dropped");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
