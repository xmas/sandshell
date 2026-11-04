// Sandshell's wrapper around the Claude ACP adapter (run unchanged). The
// launch says where the adapter is installed ($SANDSHELL_ACP_DIR), so this
// file doesn't care which adapter version that is. It answers three extra
// requests on the adapter's own `_session/async_task/stop`: an asyncTaskId of
// `sandshell:<base64url JSON>` is ours, and the reply's _meta.sandshell is the
// answer — rewind (Claude Code's checkpoints), MCP status, reconnect, on/off,
// and the /context breakdown (getContextUsage).
import { pathToFileURL } from "node:url";
const dir = process.env.SANDSHELL_ACP_DIR;
if (!dir) throw new Error("sandshell-acp: SANDSHELL_ACP_DIR isn't set");
const adapter = (file) => pathToFileURL(dir + "/node_modules/@agentclientprotocol/claude-agent-acp/dist/" + file).href;
const { ClaudeAcpAgent } = await import(adapter("lib.js"));
const stop = ClaudeAcpAgent.prototype.stopAsyncTask;
ClaudeAcpAgent.prototype.stopAsyncTask = async function (params) {
  const id = String(params.asyncTaskId);
  if (!id.startsWith("sandshell:")) return stop.call(this, params);
  const req = JSON.parse(Buffer.from(id.slice(10), "base64url").toString());
  const q = this.sessions[params.sessionId]?.query;
  if (!q) throw new Error("No such session");
  let result;
  switch (req.op) {
    case "rewind": result = await q.rewindFiles(req.uuid, { dryRun: !!req.dryRun }); break;
    case "mcpStatus": result = await q.mcpServerStatus(); break;
    case "mcpReconnect": await q.reconnectMcpServer(req.name); result = await q.mcpServerStatus(); break;
    case "mcpToggle": await q.toggleMcpServer(req.name, !!req.enabled); result = await q.mcpServerStatus(); break;
    case "contextUsage": result = await q.getContextUsage({ detail: req.detail === "summary" ? "summary" : "full" }); break;
    default: throw new Error("Unknown Sandshell request " + req.op);
  }
  return { stopped: false, _meta: { sandshell: result ?? null } };
};
await import(adapter("index.js"));
