// Run with: node tests/model.test.js
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const M = new Function(src + "\nreturn { newId, validate, clean, parsePoll, stateOf, isRunning, reasonKey, uptime, address, detectDrops, parseOnline, dueForAutostart, handledThisSession, parseSshCommand, looksLikeSsh, shellSplit };")();

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

// a tunnel that was running when the session started must stay stopped once it is stopped
{
  const a = { id: "aaaaaaaa", autostart: true }, b = { id: "bbbbbbbb", autostart: false };
  const up = { active: "active", listening: true }, down = { active: "inactive", listening: false };
  const tried = {};
  // poll 1: a is already up, b is not an autostart tunnel
  for (const id of M.handledThisSession([a, b], { aaaaaaaa: up, bbbbbbbb: up })) tried[id] = true;
  eq(Object.keys(tried), ["aaaaaaaa"], "only autostart tunnels that are doing something are marked");
  // poll 2: the user stopped it
  eq(M.dueForAutostart([a, b], { aaaaaaaa: down, bbbbbbbb: down }, true, tried), [], "up, then stopped: not started again");
  eq(M.handledThisSession([a], { aaaaaaaa: down }), [], "a down tunnel is not marked");
  eq(M.handledThisSession([a], {}), [], "no poll yet: nothing marked");
  eq(M.handledThisSession([a], { aaaaaaaa: { active: "failed", listening: false } }), ["aaaaaaaa"], "failed counts as handled");
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

// ---- pasting a whole ssh command ----
const P = (s) => M.parseSshCommand(s);
const okFields = (r) => r.ok ? { target: r.target, lp: r.localPort, rh: r.remoteHost, rp: r.remotePort } : r;
const dbOk = { target: "user@bastion.example.com", lp: 5433, rh: "db.example", rp: 5432 };

// the usual command, as copied from a chat or a doc
eq(okFields(P("ssh -L 0.0.0.0:5433:db.example:5432 -p 22 user@bastion.example.com")), dbOk, "paste: bind address, -p 22, user@host");
eq(okFields(P("ssh -N -L 5433:db.example:5432 user@bastion.example.com")), dbOk, "paste: plain -N -L");
eq(okFields(P("ssh -L5433:db.example:5432 -p22 user@bastion.example.com")), dbOk, "paste: attached -L5433... and -p22");
eq(okFields(P("ssh -fNL 5433:db.example:5432 user@bastion.example.com")), dbOk, "paste: clustered flags -fNL");
eq(okFields(P("ssh -L 5433:db.example:5432 -l user bastion.example.com")), dbOk, "paste: -l user host");
eq(okFields(P("ssh -L 5433:db.example:5432 -- user@bastion.example.com")), dbOk, "paste: -- before the host");
eq(okFields(P('ssh -L "5433:db.example:5432" \'user@bastion.example.com\'')), dbOk, "paste: quoted arguments");
eq(okFields(P("$ ssh -L 5433:db.example:5432 user@bastion.example.com")), dbOk, "paste: leading $ prompt");
eq(okFields(P("/usr/bin/ssh -L 5433:db.example:5432 user@bastion.example.com")), dbOk, "paste: full path to ssh");
eq(okFields(P("ssh \\\n  -L 5433:db.example:5432 \\\n  user@bastion.example.com")), dbOk, "paste: backslash line continuation");
eq(okFields(P("  ssh -L 5433:db.example:5432 user@bastion.example.com  \n")), dbOk, "paste: surrounding whitespace");
eq(P("ssh -L 5433:db.example:5432 my-alias").target, "my-alias", "paste: an ssh_config Host alias is a valid target");
eq(P("ssh -Nv -4 -C -L 5433:db.example:5432 user@host").ok, true, "paste: harmless flags are ignored");

// the widget listens on 127.0.0.1 only: a wider bind is noted, a loopback one is not
eq(P("ssh -L 0.0.0.0:5433:db.example:5432 user@host").notes, ["paste.note.bind"], "paste: 0.0.0.0 is noted");
eq(P("ssh -L *:5433:db.example:5432 user@host").notes, ["paste.note.bind"], "paste: * is noted");
eq(P("ssh -L [::1]:5433:db.example:5432 user@host").notes, ["paste.note.bind"], "paste: [::1] is noted");
eq(P("ssh -L 127.0.0.1:5433:db.example:5432 user@host").notes, [], "paste: 127.0.0.1 is not noted");
eq(P("ssh -L localhost:5433:db.example:5432 user@host").notes, [], "paste: localhost is not noted");
eq(P("ssh -L 5433:db.example:5432 user@host").notes, [], "paste: no bind address, no note");

// several forwards: the first one wins, and we say so
{
  const r = P("ssh -L 5433:db.example:5432 -L 6379:cache.example:6379 user@host");
  eq([r.ok, r.remoteHost, r.notes], [true, "db.example", ["paste.note.more"]], "paste: more than one -L keeps the first and notes it");
}

// a name is suggested from the remote host
eq(P("ssh -L 5433:mydb.abc123.ap-southeast-1.rds.amazonaws.com:5432 user@host").name, "mydb", "paste: name = first label of the host");
eq(P("ssh -L 5433:10.0.5.7:5432 user@host").name, "10.0.5.7", "paste: name = the IP for an IPv4 host");
eq(P("ssh -L 5433:" + "x".repeat(60) + ".example:5432 user@host").name.length, 40, "paste: suggested name is cut to 40 characters");

// anything that is not one plain ssh command
for (const bad of ["", "   ", "ls -la", "scp a b", "sshpass -p x ssh -L 5433:db:5432 host", "echo ssh -L 5433:db:5432 host"])
  eq(P(bad).error, "paste.err.notSsh", "paste: not an ssh command: " + JSON.stringify(bad));
for (const bad of [
  "ssh -L 5433:db:5432 host; rm -rf ~", "ssh -L 5433:db:5432 host && id", "ssh -L 5433:db:5432 host | tee x",
  "ssh -L 5433:$(id):5432 host", "ssh -L 5433:`id`:5432 host", "ssh -L 5433:$HOST:5432 host", 'ssh -L "5433:$HOST:5432" host',
  "ssh -L 5433:db:5432 host > /tmp/x", "ssh -L 5433:db:5432 host < /etc/passwd", "ssh -L 5433:db:5432 (host)",
  "ssh -L 5433:db:5432 'host", 'ssh -L 5433:db:5432 "host', "ssh -L 5433:db:5432 host #x", "ssh -L 5433:db:5432 host\\"])
  eq(P(bad).error, "paste.err.unsafe", "paste: refused as unsafe: " + JSON.stringify(bad));

// options we cannot honour are named, never dropped
for (const [cmd, opt] of [
  ["ssh -o ProxyCommand=evil -L 5433:db:5432 user@host", "-o"], ["ssh -oProxyCommand=evil -L 5433:db:5432 user@host", "-o"],
  ["ssh -J jump -L 5433:db:5432 user@host", "-J"], ["ssh -i key -L 5433:db:5432 user@host", "-i"],
  ["ssh -R 9000:localhost:80 user@host", "-R"], ["ssh -D 1080 user@host", "-D"], ["ssh -W db:5432 user@host", "-W"],
  ["ssh -F /tmp/cfg -L 5433:db:5432 user@host", "-F"], ["ssh -A -L 5433:db:5432 user@host", "-A"], ["ssh -Y -L 5433:db:5432 user@host", "-Y"],
  ["ssh -L 5433:db:5432 user@host -oLocalCommand=x", "-o"], ["ssh -fNo ProxyCommand=x -L 5433:db:5432 user@host", "-o"],
  ["ssh -L", "-L"], ["ssh -L 5433:db:5432 user@host -p", "-p"]])
  eq([P(cmd).error, P(cmd).arg], ["paste.err.option", opt], "paste: unsupported option " + opt + " in " + JSON.stringify(cmd));

eq([P("ssh -p 2222 -L 5433:db:5432 user@host").error, P("ssh -p 2222 -L 5433:db:5432 user@host").arg], ["paste.err.port", "2222"], "paste: SSH port other than 22 is refused");
eq(P("ssh -L 5433:db:5432 user@host ls").error, "paste.err.command", "paste: a remote command is refused");
eq(P("ssh -L 5433:db:5432 user@host extra").error, "paste.err.command", "paste: extra words after the host are refused");
eq(P("ssh -L 5433:db:5432").error, "paste.err.noHost", "paste: no host");
eq(P("ssh user@host").error, "paste.err.noForward", "paste: no -L");
for (const bad of ["5433:db", "5433", "db:5432", "x:5433:db:5432:9", "5433:db:port", "a:b:c:d:e"])
  eq(P("ssh -L " + bad + " user@host").error, "paste.err.forward", "paste: bad forward spec " + JSON.stringify(bad));

// a pasted value that starts with '-' must still be stopped by validate(), not by luck
{
  const r = P("ssh -L 5433:db.example:5432 -- -oProxyCommand=evil");
  eq(r.ok, true, "paste: '--' makes a dash-word a host name for the parser");
  eq(M.validate({ ...good, name: r.name, target: r.target, localPort: r.localPort, remoteHost: r.remoteHost, remotePort: r.remotePort }), "val.target", "paste: validate() still rejects a target that starts with '-'");
}
{
  const r = P("ssh -L 80:db.example:5432 user@host");
  eq(M.validate({ ...good, name: r.name, target: r.target, localPort: r.localPort, remoteHost: r.remoteHost, remotePort: r.remotePort }), "val.localPort", "paste: a privileged local port still fails validate()");
}
{
  const r = P("ssh -L 5433:db.example:5432 user@bastion.example.com");
  eq(M.validate({ id: "aaaaaaaa", name: r.name, target: r.target, localPort: r.localPort, remoteHost: r.remoteHost, remotePort: r.remotePort }, []), "", "paste: a good command gives a valid tunnel");
}

eq(P("$ $HOME/bin/ssh -L 5433:db:5432 user@host").error, "paste.err.unsafe", "paste: a $variable is not mistaken for a prompt");
eq(P("$ ").error, "paste.err.notSsh", "paste: a lone prompt is not ssh");
eq(P("> ssh -L 5433:db.example:5432 user@bastion.example.com").ok, true, "paste: leading > prompt");

// when to react to a paste
for (const yes of ["ssh -L 1:a:2 h", "  ssh -L 1:a:2 h", "$ ssh -L 1:a:2 h", "/usr/bin/ssh -L 1:a:2 h", "ssh\t-L 1:a:2 h", "ssh -N"])
  eq(M.looksLikeSsh(yes), true, "looksLikeSsh: " + JSON.stringify(yes));
for (const no of ["", "user@host", "bastion", "my-ssh-alias", "sshpass -p x ssh h", "ssh", "sshd -L", "user@ssh.example.com"])
  eq(M.looksLikeSsh(no), false, "not an ssh paste: " + JSON.stringify(no));
eq(M.shellSplit("a 'b c' \"d e\" f\\ g"), ["a", "b c", "d e", "f g"], "shellSplit: quotes and escaped space");
eq(M.shellSplit("a ''"), ["a", ""], "shellSplit: an empty quoted argument is kept");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
