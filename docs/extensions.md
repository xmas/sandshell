# Extensions

Features like the Canvas, an iOS Simulator runner and an Android emulator
runner have two halves on two sides of the sandbox wall:

- **What the agent knows and can call**, in the sandbox — any agent: Claude,
  Codex, Gemini, Cursor, OpenCode… never one harness's plugin format.
- **What actually runs**, on the Mac — the sandbox is a Linux VM: no Xcode,
  no Simulator, no hardware-accelerated emulator, no Sandshell window.

MCP is the one extension point every agent shares, and **sbx already
bridges it**: a stdio MCP server registered with `sbx mcp add NAME --command
<executable>` runs on the Mac, and `sbx mcp load NAME --sandbox <sandbox>`
(or `sbx create --static-mcp NAME`) serves it inside the sandbox through
sbx's MCP gateway (`$MCP_GATEWAY_URL`, bearer `$MCP_SENTINEL_TOKEN_NAME`),
which each agent's kit wires into its agent.

Spike (sbx 0.51, 2026-11-04): a Python stdio server registered that way,
loaded into a shell sandbox, answered `tools/list` and `tools/call` through
the gateway from inside the sandbox — `uname Darwin, cwd /Users/xmas`: the
tool ran on the Mac. Plain HTTP to the Mac (`host.docker.internal`) is
refused by sbx's proxy (403), so the gateway is the way across.

## Shape

```
agent (any, in the sandbox) ──MCP──▶ sbx gateway ──stdio──▶ sandshell-mcp (on the Mac) ──▶ Sandshell.app
                                                                                   │
                                                              extensions: Canvas, iOS Simulator, Android…
```

- **`sandshell-mcp`**: a small executable in the app bundle that sbx runs on
  the Mac. It speaks MCP on stdio and forwards to the running app (a local
  socket, as the `sandshell` CLI's Apple Events do today), so tools act on
  the app's windows, panes and boards. Registered once (`sbx mcp add sandshell
  --command …/Contents/MacOS/sandshell-mcp`), loaded into every sandbox
  Sandshell makes.
- **`SandshellExtension`** (Swift): an id; MCP tools (name, JSON schema, an
  async handler on the main actor); MCP `instructions` and prompts (the
  "skill" text and slash commands, in a form every agent reads); optionally
  a pane kind, menu items and settings. The app's MCP server is the union.
- **Chats**: Sandshell's ACP chats point their agent at the gateway in
  `session/new` (`mcpServers`, HTTP) — needed where Sandshell points the
  agent's config at the host's (`CLAUDE_CONFIG_DIR`), so the kit's own
  gateway registration isn't read. Terminals get it from the agent's kit.

## Extensions

- **Canvas**: the instructions now in the Claude-only plugin move here
  (the plugin goes); tools: open a board beside the chat, screenshot an
  artboard, read the user's notes, list boards.
- **iOS Simulator**: build the workspace's app with Xcode on the Mac (same
  folder), boot a simulator, install, launch, screenshot, tap/swipe/type,
  read logs; a pane showing the simulator live.
- **Android**: the same over `adb` and the emulator on the Mac.

## Open questions

- Which sandbox (and which chat) is calling: sbx runs one server process per
  load — what does it tell the process (env, args)? Else the app passes the
  session in the tool call (the chat's id in the instructions).
- Does the gateway forward a server's `instructions` and prompts, or only
  tools? If only tools, instructions go in a `guide` tool's description and
  the agent context.
- Approval: sbx asks before running an environment's host MCP command;
  a registered one ran without asking here — confirm for `--static-mcp`.
- Tool name collisions across servers (`mcp.useServerNamePrefixes`).
