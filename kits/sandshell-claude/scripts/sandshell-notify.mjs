// sandshell-notify: tell the person something, from inside a sandbox — a
// notification on the Mac running Sandshell, and on the Remote Control
// devices following the session. For "tell me when the build passes".
//
//   sandshell-notify [--title <title>] <message…>
//   <command> | sandshell-notify --title "Build log tail"
//
// The launch says where (SANDSHELL_NOTIFY_DIR: the workspace's
// .sandshell/notify, mounted from the Mac) and which session
// (SANDSHELL_SESSION). Sandshell picks the file up and removes it.
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

const usage = "usage: sandshell-notify [--title <title>] <message…>\n";
const args = process.argv.slice(2);
let title = null;
const words = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "-h" || a === "--help") { process.stdout.write(usage); process.exit(0); }
  else if (a === "--title" || a === "-t") title = args[++i] ?? null;
  else if (a === "--phone") {} // devices following the session always hear it
  else words.push(a);
}
let message = words.join(" ");
if (!message && !process.stdin.isTTY) {
  message = fs.readFileSync(0, "utf8");
}
message = message.trim();
if (!message && !title) { process.stderr.write(usage); process.exit(2); }

const dir = process.env.SANDSHELL_NOTIFY_DIR;
if (!dir) {
  process.stderr.write("sandshell-notify: this isn't a session Sandshell launched (no SANDSHELL_NOTIFY_DIR)\n");
  process.exit(1);
}
const note = {
  session: process.env.SANDSHELL_SESSION ?? null,
  title, message: message.slice(0, 2000), at: new Date().toISOString(),
};
try {
  fs.mkdirSync(dir, { recursive: true });
  const name = `${Date.now()}-${randomUUID()}`;
  const tmp = path.join(dir, `.${name}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(note));
  fs.renameSync(tmp, path.join(dir, `${name}.json`));
} catch (e) {
  process.stderr.write(`sandshell-notify: couldn't leave the notification in ${dir}: ${e.message}\n`);
  process.exit(1);
}
