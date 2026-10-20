# Remote Control

Drive Sandshell's chats from another device — an iPhone, a Windows PC, another
Mac — the way Claude Code's Remote Control drives a local session from
claude.ai. Chat only; terminals stay on the Mac.

## Shape

Sandshell is the server. Nothing runs in the sandbox for it and nothing in
the sandbox is exposed: a remote device talks to the app, and the app drives
its agents exactly as its own window does (`sbx exec -i`, ACP over stdio).
Agent credentials stay with sbx on the Mac.

```
iPhone / PC / work Mac ──HTTP(S)──▶ Sandshell (RemoteServer → RemoteHub) ──▶ ChatSession ──▶ sbx exec -i ──▶ agent
```

- **RemoteHub** (`Sandshell/Remote/RemoteHub.swift`): the chats remote devices
  may see — every window's chats with Remote Control on, plus (DEBUG) the
  check session — as wire snapshots; each change bumps the session's sequence
  number and goes out to subscribers. Commands call the same `ChatSession`
  methods the window does: `submit`, `cancel`, `answerPermission`,
  `answerQuestion`, `setMode`.
- **RemoteServer** (`Sandshell/Remote/RemoteServer.swift`, `HTTPServer.swift`):
  a small HTTP/1.1 server on Network.framework — no dependencies. The web
  client's files, a JSON API, and one Server-Sent Events stream per client
  (`EventSource` reconnects by itself and sends `Last-Event-ID`, so a client
  that drops picks up where it left off).
- **Wire protocol** (`Sandshell/Remote/RemoteProtocol.swift`): `ChatItem` and
  the chat's state as Codable values. Images travel as separate downloads.
- **Web client** (`remote/web/`): one page, no build step, served by the app.
  Phone-first, with a two-column layout on a desktop browser.
- **Per-session switch**: a session shows up remotely only with Remote Control
  on (`Session.isRemote`, the pane strip's antenna button) — like Claude's
  per-session toggle. The server runs while any session has it on.

## Reaching the Mac

| Device | Route | Notes |
|---|---|---|
| This Mac | `http://127.0.0.1:47820` | Phase 1 binds loopback only |
| iPhone, Windows PC | Tailscale (`tailscale serve` → HTTPS on the tailnet) | Real certificate: push alerts, Home Screen install. Works away from home |
| Work Mac | Home network (`http://Rowan-Mentor-Pro.local:47820`, Bonjour `_sandshell._tcp`) | Opt-in; plain HTTP on the LAN. The work Mac can't join the tailnet |

Every device pairs once (QR code on the phone, a 6-digit code elsewhere) and
gets a revocable token (an HttpOnly cookie). A hosted relay and public tunnels
(ngrok, cloudflared, Funnel) are out of v1.

### Pairing and who gets in (built)

- **This Mac is trusted**: a request that arrives on loopback, for a loopback
  name, with no proxy headers (`X-Forwarded-For`, `Forwarded`,
  `Tailscale-User-Login`). An SSH tunnel's far end counts — SSH did the
  sign-in.
- **Everything else needs a paired device's cookie** (`sandshell_device`,
  HttpOnly, SameSite=Strict, a year; Secure behind HTTPS). The Mac keeps only
  its SHA-256 (`RemoteDevices`, in the app's defaults). Revoking closes the
  device's open streams.
- **Pairing** (`RemotePairing`): Remote Control Devices… (or the popover's
  Pair a Device…) opens a 5-minute, one-device offer: a 6-digit code to type,
  and a link — `/pair#<secret>`, the secret in the fragment so it never
  reaches logs or history — as a QR code or by AirDrop. Five wrong codes end it.
- **Home network** (the popover's switch, `remoteHomeNetwork`): the server
  listens beyond loopback, advertises `_sandshell._tcp` (once macOS's Local
  Network permission is given), and accepts this Mac's `.local` name and its
  Wi-Fi/Ethernet IPs in `Host`. Off, it's loopback only.
- Static files (the client) are public; every `/api` call but `/api/pair`
  needs a caller.

## Testing on every device, all the time

1. **Fake agent** (`remote/fake-acp-agent.py`, DEBUG): a scripted ACP agent
   run on the Mac without a sandbox — replies on cue, sends an image, asks a
   permission, streams a long answer. Deterministic, fast, no tokens.
2. **`remote` self-test**: acts as a remote device against the real app over
   loopback (later also `.local` and the tailnet address).
3. **`/check` page**: the same flow inside any device's real browser, reported
   back to the Mac (Settings ▸ Remote and `scripts/run-remote-checks.sh`).
4. **Re-run on every build**: devices with `/check` open re-run when a new
   Debug build starts.
5. **Scripted browsers** where possible: Playwright (this Mac, work Mac,
   Windows), Safari in the iOS Simulator, Safari Remote Automation on the iPhone.

## Phases

1. Hub, protocol, server (loopback), per-session switch, fake agent, `remote` self-test.
2. Web client: transcript (Markdown, images, tool calls, diffs, plan),
   permission prompts and questions, composer with photo/file attach, mode
   chooser, Stop; `/check` and re-run on build.
3. Pairing (QR + code), device list and revoke in Settings ▸ Remote.
4. Home network: bind beyond loopback, Bonjour, the work Mac.
5. Tailscale: `tailscale serve`, iPhone Home Screen app, Web Push.
6. Keep-awake while on (plugged in), menu bar indicator.

Not in v1: terminals, Undo/rewind, MCP, background tasks, Files, model and
effort choosers (a Claude model change relaunches the agent — the pane's job),
starting new sessions remotely.
