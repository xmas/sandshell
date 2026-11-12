// sandshell-hold: keeps a chat's ACP agent running when Sandshell goes away
// (quits, crashes, the Mac's `sbx exec` drops), so a turn in progress
// finishes, and lets the next launch take the chat up where it is.
//
//   sandshell-hold [--attach <sessionId>] -- <agent command…>
//     Speak ACP on stdio, through the held agent for <sessionId> if one is
//     running here, else through a new one (started for <agent command>).
//   sandshell-hold --list          held agents, one JSON line each
//   sandshell-hold --wait <id>     return once the held agent for <id> exits
//   sandshell-hold --stop <id>     end it
//
// The agent runs under a daemon (its own session, outside `sbx exec`'s) that
// listens on a socket in $SANDSHELL_HOLD_DIR, named for the ACP session once
// it's open. One client at a time is attached: the daemon passes ACP between
// it and the agent, renumbering requests so a new client's ids can't meet an
// old one's replies. It keeps what a new client needs to catch up: the
// `initialize` and session results, every `session/update` since the session
// opened (text chunks joined, prompts recorded as the user's chunks, as a
// `session/load` replays them) and the agent's unanswered requests. Asked to
// load the held session, it answers from that instead of the agent.
//
// Left alone with no turn running it ends: the next launch loads the
// conversation from its transcript as usual. A turn that ends while nobody's
// attached ends it too.
//
// To the client: `o <json>` (the agent's stdout), `e <line>` (its stderr),
// `x <status>` (it exited). From the client, the first line says what it
// wants (`{"hold":"attach"|"status"|"wait"|"stop"}`); after an attach, ACP.
// Its first message to an attached client is `_sandshell/hold`: the launch
// tag the agent carries (to reap it by), whether a turn is running, and
// whether this is a reattach. `_sandshell/turnEnded` tells a client that
// attached mid-turn when that turn ends.
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const DIR = process.env.SANDSHELL_HOLD_DIR || "/tmp/sandshell-hold";
const SELF = fileURLToPath(import.meta.url);

function lines(stream, onLine) {
  let buf = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (line) onLine(line);
    }
  });
  stream.on("end", () => { if (buf) onLine(buf); buf = ""; });
}

function sockFor(id) { return path.join(DIR, encodeURIComponent(id) + ".sock"); }

/// Connect to `sock` and say `hold`; null when nothing's listening there.
function connect(sock, hold) {
  return new Promise((resolve) => {
    const c = net.connect(sock);
    c.once("connect", () => { c.write(JSON.stringify({ hold }) + "\n"); resolve(c); });
    c.once("error", () => resolve(null));
  });
}

// MARK: - Client

async function client(argv) {
  let attach = null;
  const sep = argv.indexOf("--");
  const opts = sep < 0 ? argv : argv.slice(0, sep);
  const cmd = sep < 0 ? [] : argv.slice(sep + 1);
  for (let i = 0; i < opts.length; i++) {
    const a = opts[i];
    if (a === "--attach") attach = opts[++i] || null;
    else if (a === "--list") return list();
    else if (a === "--wait" || a === "--stop") return control(a.slice(2), opts[++i]);
    else { process.stderr.write(`sandshell: sandshell-hold: unknown option ${a}\n`); process.exit(2); }
  }
  if (!cmd.length) { process.stderr.write("sandshell: sandshell-hold: no agent command\n"); process.exit(2); }
  fs.mkdirSync(DIR, { recursive: true, mode: 0o700 });
  let conn = attach ? await connect(sockFor(attach), "attach") : null;
  if (!conn) conn = await startDaemon(cmd);
  if (!conn) { process.stderr.write("sandshell: the chat's agent didn't start (sandshell-hold)\n"); process.exit(1); }
  let status = 0;
  lines(conn, (line) => {
    const tag = line[0], rest = line.slice(2);
    if (tag === "o") process.stdout.write(rest + "\n");
    else if (tag === "e") process.stderr.write(rest + "\n");
    else if (tag === "x") status = Number(rest) || 0;
  });
  process.stdin.on("data", (d) => conn.write(d));
  // Sandshell went (or closed our stdin): detach; the agent stays with the daemon.
  process.stdin.on("end", () => conn.end());
  conn.on("close", () => process.exit(status));
  conn.on("error", () => {});
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => { conn.destroy(); process.exit(0); });
}

async function startDaemon(cmd) {
  // Earlier daemons' logs, after a day; their sockets, once nothing listens.
  for (const n of fs.readdirSync(DIR)) {
    const f = path.join(DIR, n);
    try { if (n.endsWith(".log") && Date.now() - fs.statSync(f).mtimeMs > 24 * 3600 * 1000) fs.unlinkSync(f); } catch {}
  }
  const sock = path.join(DIR, "d-" + randomUUID() + ".sock");
  const log = fs.openSync(sock.replace(/\.sock$/, ".log"), "a");
  spawn(process.execPath, [SELF, "--daemon", sock, "--", ...cmd], {
    detached: true, stdio: ["ignore", "ignore", log], env: { ...process.env, SANDSHELL_HOLD: "1" },
  }).unref();
  fs.closeSync(log);
  for (let waited = 0; waited < 20000; waited += 50) {
    const c = fs.existsSync(sock) ? await connect(sock, "attach") : null;
    if (c) return c;
    await new Promise((r) => setTimeout(r, 50));
  }
  return null;
}

/// Held agents, one JSON line each ({session, running, attached, pid}).
async function list() {
  let names = [];
  try { names = fs.readdirSync(DIR).filter((n) => n.startsWith("d-") && n.endsWith(".sock")); } catch {}
  for (const name of names) {
    const c = await connect(path.join(DIR, name), "status");
    if (!c) { try { fs.unlinkSync(path.join(DIR, name)); } catch {} continue; }
    const line = await new Promise((resolve) => {
      let got = "";
      lines(c, (l) => { got = got || l; c.end(); });
      c.on("close", () => resolve(got));
      c.on("error", () => resolve(got));
    });
    if (line) process.stdout.write(line + "\n");
  }
}

/// --wait: return when it's gone; --stop: end it.
async function control(what, id) {
  if (!id) { process.stderr.write(`sandshell: sandshell-hold --${what} needs a session id\n`); process.exit(2); }
  const c = await connect(sockFor(id), what);
  if (!c) return;
  c.resume();
  await new Promise((resolve) => { c.on("close", resolve); c.on("error", resolve); });
}

// MARK: - Daemon

function daemon(sock, cmd) {
  const launch = process.env.SANDSHELL_LAUNCH ?? null;
  const agent = spawn(cmd[0], cmd.slice(1), { stdio: ["pipe", "pipe", "pipe"], detached: true });
  let client = null;          // the attached socket
  // Whether it's had what it missed: until a client that attached to a held
  // session loads it, what the agent says goes only into the log (the load
  // replays it, in order).
  let synced = false;
  let everAttached = false;
  let nextID = 1;
  const outstanding = new Map();   // our id → { conn, id, method, params }
  const agentRequests = new Map(); // the agent's unanswered requests, by id
  const waiters = new Set();
  let init = null;                 // `initialize`'s result
  let session = null, opened = null; // the held session, and what opening it returned
  let opening = false;
  let log = [];                    // `session/update`s since the session opened
  let turn = null;                 // our id for the running `session/prompt`
  let named = null;
  let detachedAt = null;
  let ending = false;

  const send = (conn, tag, text) => { if (conn && !conn.destroyed) conn.write(`${tag} ${text}\n`); };
  const toClient = (msg) => send(client, "o", JSON.stringify(msg));
  const live = (line) => { if (synced) send(client, "o", line); };
  const toAgent = (msg) => { if (agent.stdin.writable) agent.stdin.write(JSON.stringify(msg) + "\n"); };
  const reply = (conn, id, result) => send(conn, "o", JSON.stringify({ jsonrpc: "2.0", id, result }));

  function name() {
    if (!session || named === session) return;
    const link = sockFor(session);
    try { fs.unlinkSync(link); } catch {}
    try { fs.symlinkSync(path.basename(sock), link); named = session; } catch {}
  }

  function end(why) {
    if (ending) return;
    ending = true;
    process.stderr.write(`sandshell-hold: ending (${why})\n`);
    try { process.kill(-agent.pid, "SIGTERM"); } catch {}
    setTimeout(() => { try { process.kill(-agent.pid, "SIGKILL"); } catch {} finish(0); }, 3000).unref();
  }

  function finish(status) {
    send(client, "x", String(status ?? 0));
    client?.end();
    for (const w of waiters) w.end();
    try { fs.unlinkSync(sock); } catch {}
    try { if (named && fs.readlinkSync(sockFor(named)) === path.basename(sock)) fs.unlinkSync(sockFor(named)); } catch {}
    setTimeout(() => process.exit(0), 100);
  }

  /// Nobody's attached: end now unless a turn's running (it ends when that does).
  function settle() {
    if (client || turn !== null) return;
    end(session ? "detached with no turn running" : "detached before a session opened");
  }

  // A long-lost client's turn still waiting on it (a question nobody can
  // answer) ends after a day.
  setInterval(() => {
    if (!client && detachedAt && Date.now() - detachedAt > 24 * 3600 * 1000) end("detached for a day");
  }, 60 * 1000).unref();

  function record(msg) {
    if (msg.method !== "session/update" || !(session || opening)) return;
    const u = msg.params?.update;
    const kind = u?.sessionUpdate;
    const last = log[log.length - 1]?.params?.update;
    if ((kind === "agent_message_chunk" || kind === "agent_thought_chunk") && u.content?.type === "text"
        && last?.sessionUpdate === kind && last.messageId === u.messageId && last.content?.type === "text") {
      last.content.text += u.content.text;
      return;
    }
    // Only the latest of these matters.
    if (["usage_update", "available_commands_update", "current_mode_update", "config_option_update"].includes(kind)) {
      log = log.filter((m) => m.params?.update?.sessionUpdate !== kind);
    }
    log.push(msg);
  }

  /// What the person said, as a `session/load` would replay it.
  function recordPrompt(sessionId, blocks) {
    for (const b of blocks ?? []) {
      if (b?.type !== "text" || typeof b.text !== "string" || b.text.startsWith("[Sandshell:")) continue;
      log.push({ jsonrpc: "2.0", method: "session/update",
                 params: { sessionId, update: { sessionUpdate: "user_message_chunk", content: { type: "text", text: b.text } } } });
    }
  }

  function fromClient(conn, line) {
    let msg;
    try { msg = JSON.parse(line); } catch { if (agent.stdin.writable) agent.stdin.write(line + "\n"); return; }
    if (msg.method && msg.id !== undefined) {
      const p = msg.params ?? {};
      if (msg.method === "initialize" && init) return reply(conn, msg.id, init);
      if ((msg.method === "session/load" || msg.method === "session/resume") && opened && p.sessionId === session) {
        for (const m of log) send(conn, "o", JSON.stringify(m));
        reply(conn, msg.id, opened);
        for (const r of agentRequests.values()) send(conn, "o", JSON.stringify(r));
        synced = true;
        return;
      }
      if (msg.method === "session/new" || msg.method === "session/load") { opening = true; log = []; synced = true; }
      if (msg.method === "session/prompt") recordPrompt(p.sessionId, p.prompt);
      const id = nextID++;
      outstanding.set(id, { conn, id: msg.id, method: msg.method, params: p });
      if (msg.method === "session/prompt") turn = id;
      return toAgent({ ...msg, id });
    }
    if (msg.id !== undefined && !msg.method) agentRequests.delete(JSON.stringify(msg.id));
    toAgent(msg);
  }

  function answered(o, msg) {
    const r = msg.result;
    switch (o.method) {
      case "initialize": if (r) init = r; break;
      case "session/new":
      case "session/load":
        opening = false;
        if (r) { session = o.method === "session/new" ? r.sessionId : o.params.sessionId; opened = r; name(); }
        else log = [];
        break;
      case "session/set_mode":
        if (r && opened?.modes) opened.modes.currentModeId = o.params.modeId;
        break;
      case "session/set_model":
        if (r && opened?.models) opened.models.currentModelId = o.params.modelId;
        break;
      case "_session/steering":
        // (Taken back if the turn had just ended: it comes again as a prompt.)
        if (r && r.outcome !== "promptRequired") recordPrompt(o.params.sessionId, o.params.prompt);
        break;
      case "session/set_config_option":
        if (r?.configOptions && opened) opened.configOptions = r.configOptions;
        break;
    }
  }

  function fromAgent(line) {
    let msg;
    try { msg = JSON.parse(line); } catch { return live(line); }
    if (msg.id !== undefined && !msg.method) {
      const o = outstanding.get(msg.id);
      if (!o) return;
      outstanding.delete(msg.id);
      answered(o, msg);
      const wasTurn = msg.id === turn;
      if (wasTurn) turn = null;
      if (o.conn === client && client && !client.destroyed) {
        toClient({ ...msg, id: o.id });
      } else if (wasTurn && client && synced) {
        toClient({ jsonrpc: "2.0", method: "_sandshell/turnEnded",
                   params: { stopReason: msg.result?.stopReason ?? null, error: msg.error?.message ?? null } });
      }
      if (wasTurn) settle();
      return;
    }
    if (msg.method && msg.id !== undefined) agentRequests.set(JSON.stringify(msg.id), msg);
    else record(msg);
    live(line);
  }

  lines(agent.stdout, fromAgent);
  lines(agent.stderr, (line) => send(client, "e", line));
  agent.stdin.on("error", () => {});
  agent.on("exit", (code, signal) => {
    process.stderr.write(`sandshell-hold: agent exited (${code ?? signal})\n`);
    finish(code ?? (signal ? 128 : 0));
  });
  agent.on("error", (e) => {
    send(client, "e", `sandshell: couldn't start the chat's agent: ${e.message}`);
    finish(127);
  });

  const server = net.createServer((conn) => {
    conn.on("error", () => {});
    let mode = null;
    lines(conn, (line) => {
      if (mode === "attach") return fromClient(conn, line);
      if (mode) return;
      try { mode = JSON.parse(line).hold; } catch { mode = "attach"; }
      if (mode === "status") {
        conn.end(JSON.stringify({ session, running: turn !== null, attached: !!client, pid: process.pid, launch }) + "\n");
      } else if (mode === "wait") {
        waiters.add(conn);
        conn.on("close", () => waiters.delete(conn));
      } else if (mode === "stop") {
        waiters.add(conn);
        end("asked to stop");
      } else {
        mode = "attach";
        if (client) client.destroy();
        client = conn;
        synced = !session;
        detachedAt = null;
        toClient({ jsonrpc: "2.0", method: "_sandshell/hold",
                   params: { launch, session, running: turn !== null, reattached: everAttached } });
        everAttached = true;
        conn.on("close", () => {
          if (client !== conn) return;
          client = null;
          detachedAt = Date.now();
          settle();
        });
      }
    });
  });
  server.on("error", (e) => {
    process.stderr.write(`sandshell-hold: can't listen on ${sock}: ${e.message}\n`);
    try { process.kill(-agent.pid, "SIGKILL"); } catch {}
    process.exit(1);
  });
  server.listen(sock);
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => end(sig));
}

const argv = process.argv.slice(2);
if (argv[0] === "--daemon") {
  const sep = argv.indexOf("--");
  daemon(argv[1], argv.slice(sep + 1));
} else {
  await client(argv);
}
