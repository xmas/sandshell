// Sandshell Remote Control — the web client a phone, PC or another Mac loads
// from the Mac. One event stream (/api/events) brings the session list and,
// for the open chat, its state then patches; commands are POSTs.
"use strict";

const $ = (id) => document.getElementById(id);
// Inside Sandshell's own window (ChatWebView): the app hands this page the
// chat's events and takes its commands; no server, no pairing, no list.
const native = window.webkit?.messageHandlers?.sandshell;
if (native) document.documentElement.classList.add("embedded");
// A chat's transcript in Sandshell's own window (ChatWebTranscript): the
// window has the composer and cards; this page is the conversation.
const transcriptOnly = !!native && document.documentElement.classList.contains("transcript-only");
const el = {
  app: $("app"), listPane: $("list-pane"), chatPane: $("chat-pane"), checkPane: $("check-pane"), placeholder: $("placeholder"),
  host: $("host"), conn: $("conn"), sessions: $("sessions"), empty: $("empty"),
  back: $("back"), title: $("chat-title"), sub: $("chat-sub"), mode: $("mode"),
  transcript: $("transcript"), cards: $("cards"), composer: $("composer"), input: $("input"),
  send: $("send"), file: $("file"), attachments: $("attachments"), status: $("status"),
  checkBack: $("check-back"), checkRun: $("check-run"), checkResults: $("check-results"),
  pairPane: $("pair-pane"), pairForm: $("pair-form"), pairHost: $("pair-host"), pairCode: $("pair-code"),
  pairName: $("pair-name"), pairSubmit: $("pair-submit"), pairError: $("pair-error"),
};

const state = {
  sessions: [],
  current: null,          // session id the chat pane shows
  items: new Map(),       // id -> item
  order: [],              // item ids in order
  nodes: new Map(),       // id -> element
  status: null,
  omitted: 0,
  pending: [],            // images to attach: {name, mimeType, data, url}
  stream: null,
  rev: null,              // the revision shown (state and patches carry one)
  openGroups: new Set(),  // runs of tool calls opened (by their first call's id)
  openMessages: new Set(), // long messages of yours opened (More)
  resyncing: false,
  listeners: new Set(),   // (event, data) => void, for /check
};

// ---------- Routing ----------

function route() {
  const path = location.pathname;
  const m = path.match(/^\/s\/([0-9A-Fa-f-]{36})$/);
  const check = path === "/check";
  const id = m ? m[1].toUpperCase() : null;
  el.chatPane.hidden = !id;
  el.checkPane.hidden = !check;
  el.listPane.hidden = !!(id || check);
  el.placeholder.hidden = !!(id || check);
  if (id !== state.current || !state.stream) open(id);
  if (check) runChecks();
  renderList();
}

function go(path) {
  if (location.pathname !== path) history.pushState(null, "", path);
  route();
}

window.addEventListener("popstate", route);
el.back.addEventListener("click", () => go("/"));
el.checkBack.addEventListener("click", () => go("/"));

// ---------- The event stream ----------

// `keep`: leave what's shown until the state replaces it (a resync).
function open(id, keep = false) {
  if (state.stream) state.stream.close();
  state.current = id;
  if (!keep) resetTranscript();
  if (native) {
    state.stream = { close() {} };
    setConn("on");
    native.postMessage({ name: "ready" });
    return;
  }
  const url = "/api/events" + (id ? "?session=" + encodeURIComponent(id) : "");
  const stream = new EventSource(url);
  state.stream = stream;
  setConn("connecting");
  stream.onopen = () => setConn("on");
  stream.onerror = () => {
    const closed = stream.readyState === EventSource.CLOSED;
    setConn(closed ? "off" : "connecting");
    // Refused (unpaired, or revoked on the Mac): pair. Otherwise try again soon.
    if (closed && state.stream === stream) {
      checkPaired().then((ok) => { if (ok && state.stream === stream) setTimeout(() => open(state.current), 3000); });
    }
  };
  for (const name of ["hello", "sessions", "state", "patch", "gone", "alert"]) {
    stream.addEventListener(name, (e) => {
      const data = JSON.parse(e.data);
      handle(name, data);
      for (const listen of state.listeners) listen(name, data);
    });
  }
}

// The app's events, as the stream's would arrive.
window.sandshellReceive = (name, data) => {
  handle(name, data);
  for (const listen of state.listeners) listen(name, data);
};

function setConn(how) {
  el.conn.className = "conn " + (how === "on" ? "on" : how === "off" ? "off" : "");
  el.conn.title = how === "on" ? "Connected" : how === "off" ? "Disconnected" : "Connecting…";
}

// A patch that doesn't follow on from what's shown, or one that didn't apply,
// would leave the page wrong from then on: ask for everything instead.
function handle(name, data) {
  try {
    receive(name, data);
  } catch (err) {
    console.error("Sandshell: couldn't apply the " + name, err);
    resync();
  }
}

function resync() {
  if (state.resyncing) return;
  state.resyncing = true;
  // Again within a moment (the state itself wouldn't apply): not in a tight loop.
  const soon = Date.now() - (state.lastResync || 0) < 2000;
  state.lastResync = Date.now();
  setTimeout(() => {
    if (native) native.postMessage({ name: "resync" });
    else open(state.current, true);   // a new stream starts with the state
  }, soon ? 1000 : 0);
}

function receive(name, data) {
  switch (name) {
    case "hello":
      el.host.textContent = data.host;
      document.title = "Sandshell — " + data.host;
      setSessions(data.sessions);
      break;
    case "sessions":
      setSessions(data);
      break;
    case "state":
      if (data.session.id !== state.current) return;
      resetTranscript();
      state.rev = data.rev ?? null;
      state.resyncing = false;
      state.omitted = data.omitted;
      for (const item of data.items) { state.items.set(item.id, item); state.order.push(item.id); }
      state.status = data.status;
      renderAll(true);
      break;
    case "patch":
      if (data.session !== state.current) return;
      if (state.resyncing) return;   // the state on its way covers it
      if (data.base != null && state.rev != null && data.base !== state.rev) { resync(); return; }
      applyPatch(data);
      if (data.rev != null) state.rev = data.rev;
      break;
    case "alert":
      showAlert(data);
      break;
    case "config":
      configure(data);
      break;
    case "gone":
      if (data.session === state.current) {
        state.status = { ...(state.status || {}), phase: "closed", closedReason: "Remote Control is off for this chat on the Mac, or it closed." };
        renderStatus();
      }
      break;
  }
}

// An agent's note (sandshell-notify): a banner, tapped to open its chat; a
// system notification too where the browser allows one and the page is hidden.
function showAlert(a) {
  if (native) return;   // the Mac shows its own
  const name = state.sessions.find((s) => s.id === a.session)?.name;
  if (document.hidden && "Notification" in window && Notification.permission === "granted") {
    const n = new Notification(a.title, { body: a.message, tag: "note-" + a.session });
    n.onclick = () => { window.focus(); go("/s/" + a.session); n.close(); };
  }
  navigator.vibrate?.(120);
  const b = document.createElement("button");
  b.className = "alert";
  b.type = "button";
  const t = document.createElement("strong");
  t.textContent = a.title;
  const m = document.createElement("span");
  m.textContent = a.message;
  b.append(t, m);
  if (name && name !== a.title) { const s = document.createElement("small"); s.textContent = name; b.append(s); }
  b.addEventListener("click", () => { b.remove(); go("/s/" + a.session); });
  document.body.append(b);
  setTimeout(() => b.remove(), 12000);
}

function setSessions(list) {
  state.sessions = list;
  renderList();
  const s = list.find((x) => x.id === state.current);
  if (s) { el.title.textContent = s.name; el.sub.textContent = s.agentName + " · " + s.folder; }
}

// ---------- Session list ----------

function renderList() {
  el.sessions.replaceChildren(...state.sessions.map((s) => {
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.href = "/s/" + s.id;
    if (s.id === state.current) a.className = "current";
    a.addEventListener("click", (e) => { e.preventDefault(); go("/s/" + s.id); });
    a.append(
      span("name", s.name),
      span("badge " + s.phase, phaseLabel(s.phase)),
      span("meta", s.agentName + " · " + s.folder));
    if (s.waiting) a.append(span("waiting", "Waiting for you: " + s.waiting));
    li.append(a);
    return li;
  }));
  el.empty.hidden = state.sessions.length > 0;
}

function phaseLabel(phase) {
  return { starting: "Starting", ready: "Ready", running: "Working", closed: "Closed" }[phase] || phase;
}

function span(cls, text) {
  const s = document.createElement("span");
  s.className = cls;
  s.textContent = text;
  return s;
}

// ---------- Transcript ----------

function resetTranscript() {
  state.rev = null;
  state.items = new Map();
  state.order = [];
  state.nodes = new Map();
  state.status = null;
  state.omitted = 0;
  el.transcript.replaceChildren();
  el.cards.replaceChildren();
  renderStatus();
}

function applyPatch(p) {
  const stick = nearBottom();
  // The runs' lines aren't items: off while the items take their places.
  for (const h of el.transcript.querySelectorAll(":scope > .tool-group")) h.remove();
  for (const item of p.upserts) {
    if (!state.items.has(item.id) && !p.order) state.order.push(item.id);
    state.items.set(item.id, item);
    const old = state.nodes.get(item.id);
    const node = renderItem(item);
    state.nodes.set(item.id, node);
    if (old) old.replaceWith(node);
  }
  if (p.order) {
    state.order = p.order;
    const keep = new Set(p.order);
    for (const id of [...state.items.keys()]) if (!keep.has(id)) { state.items.delete(id); state.nodes.get(id)?.remove(); state.nodes.delete(id); }
  }
  // Put every node in order (cheap: only moves what's out of place).
  let prev = el.transcript.querySelector(".omitted");
  for (const id of state.order) {
    let node = state.nodes.get(id);
    if (!node) { const item = state.items.get(id); if (!item) continue; node = renderItem(item); state.nodes.set(id, node); }
    const want = prev ? prev.nextSibling : el.transcript.firstChild;
    if (node !== want) el.transcript.insertBefore(node, want);
    prev = node;
  }
  if (p.status) state.status = p.status;
  groupTools();
  artboardStrips();
  renderCards();
  renderStatus();
  if (stick) scrollToBottom();
}

function renderAll(scroll) {
  const nodes = [];
  if (state.omitted > 0) {
    const o = document.createElement("div");
    o.className = "item omitted";
    o.textContent = state.omitted + " earlier messages aren’t shown here.";
    nodes.push(o);
  }
  for (const id of state.order) {
    const node = renderItem(state.items.get(id));
    state.nodes.set(id, node);
    nodes.push(node);
  }
  el.transcript.replaceChildren(...nodes);
  groupTools();
  artboardStrips();
  renderCards();
  renderStatus();
  if (scroll) scrollToBottom();
}

function nearBottom() {
  const t = el.transcript;
  return t.scrollHeight - t.scrollTop - t.clientHeight < 120;
}

function scrollToBottom() {
  requestAnimationFrame(() => { el.transcript.scrollTop = el.transcript.scrollHeight; });
}

function renderItem(item) {
  const div = buildItem(item);
  if (transcriptOnly) decorate(item, div);
  if (div.querySelector(".bubble.folded")) requestAnimationFrame(() => unfoldIfShort(div));
  return div;
}

// Folded past this many lines (`.folded .said` in style.css).
const foldLines = 6;

// Whether a message of yours may run past `foldLines`: generously (a narrow
// phone wraps sooner); one that turns out to fit is unfolded once drawn.
function mayFold(text) {
  if (!text) return false;
  let lines = 0;
  for (const line of text.split("\n")) lines += Math.max(1, Math.ceil(line.length / 40));
  return lines > foldLines;
}

function unfoldIfShort(div) {
  const bubble = div.querySelector(".bubble.folded");
  const said = bubble?.querySelector(".said");
  if (!said || !div.isConnected) return;
  if (said.scrollHeight <= said.clientHeight + 1) {
    bubble.classList.remove("folded");
    bubble.querySelector(".more")?.remove();
  }
}

function buildItem(item) {
  const div = document.createElement("div");
  div.className = "item " + item.kind;
  div.dataset.id = item.id;
  switch (item.kind) {
    case "user": {
      const bubble = document.createElement("div");
      bubble.className = "bubble";
      const said = document.createElement("div");
      said.className = "said";
      said.textContent = item.text || "";
      bubble.append(said);
      // A long message shows its first lines, More for the rest.
      if (mayFold(item.text)) {
        const open = state.openMessages.has(item.id);
        bubble.classList.toggle("folded", !open);
        bubble.append(actionButton("more", open ? "Less" : "More", open ? "Show Less" : "Show All of It"));
      }
      if (item.attachments?.length) {
        const chips = document.createElement("div");
        chips.className = "chips";
        for (const a of item.attachments) chips.append(span("chip", "📎 " + a));
        bubble.append(chips);
      }
      div.append(bubble);
      break;
    }
    case "text":
      div.innerHTML = markdown(item.text || "");
      break;
    case "thought": {
      const d = document.createElement("details");
      const s = document.createElement("summary");
      s.textContent = "Thinking";
      const body = document.createElement("div");
      body.className = "body";
      body.textContent = item.text || "";
      d.append(s, body);
      div.append(d);
      break;
    }
    case "tool":
      div.append(renderTool(item));
      if (item.tool) div.classList.add(item.tool.status);
      break;
    case "plan": {
      const box = document.createElement("div");
      box.className = "plan";
      const h = document.createElement("h4");
      h.textContent = "Plan";
      const ul = document.createElement("ul");
      for (const e of item.plan || []) {
        const li = document.createElement("li");
        li.className = e.status;
        li.textContent = e.content;
        ul.append(li);
      }
      box.append(h, ul);
      const plan = item.plan || [];
      box.setAttribute("aria-label", "Plan: " + plan.filter((e) => e.status === "completed").length + " of " + plan.length + " done");
      div.append(box);
      break;
    }
    case "notice":
      div.textContent = item.text || "";
      if (item.isError) div.classList.add("error");
      break;
    case "image": {
      const img = document.createElement("img");
      img.loading = "lazy";
      img.alt = "Image from the agent";
      img.src = item.image;
      div.append(img);
      break;
    }
    case "changes":
      div.textContent = (item.restored ? "Restored " : "Changed ") + (item.paths || []).length + " file"
        + ((item.paths || []).length === 1 ? "" : "s") + ": " + (item.paths || []).map(basename).join(", ");
      break;
  }
  return div;
}

function renderTool(item) {
  const t = item.tool || { title: "Tool", status: "", input: "", output: "", diffs: [], images: [] };
  const d = document.createElement("details");
  const s = document.createElement("summary");
  const dot = document.createElement("span");
  dot.className = "dot";
  const title = document.createElement("span");
  title.className = "title";
  title.innerHTML = inline(escapeHTML(t.title || t.kind || "Tool"));
  s.append(dot, title);
  d.append(s);
  // Built when opened: a long run of tools stays cheap.
  d.addEventListener("toggle", () => {
    if (!d.open || d.querySelector(".body")) return;
    const body = document.createElement("div");
    body.className = "body";
    if (t.input && t.input !== t.title) body.append(pre(t.input));
    for (const diff of t.diffs || []) {
      const p = document.createElement("div");
      p.className = "diff-path";
      p.textContent = diff.path;
      body.append(p, renderDiff(diff));
    }
    if (t.output) body.append(pre(t.output));
    for (const src of t.images || []) {
      const img = document.createElement("img");
      img.loading = "lazy";
      img.src = src;
      body.append(img);
    }
    d.append(body);
  }, { once: false });
  return d;
}

function renderDiff(diff) {
  const oldLines = diff.oldText ? diff.oldText.replace(/\n$/, "").split("\n") : [];
  const newLines = diff.newText.replace(/\n$/, "").split("\n");
  const p = document.createElement("pre");
  p.className = "diff";
  for (const [op, line] of lineDiff(oldLines, newLines)) {
    p.append(diffLine(op === "-" ? "del" : op === "+" ? "add" : "", op + " " + line));
  }
  return p;
}

// Lines kept, removed (-) and added (+), in order: a longest-common-subsequence
// diff, or (for a very big edit) everything old out and everything new in.
function lineDiff(a, b) {
  const n = a.length, m = b.length;
  if (n * m > 250000) return [...a.map((l) => ["-", l]), ...b.map((l) => ["+", l])];
  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  }
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { out.push([" ", a[i]]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) out.push(["-", a[i++]]);
    else out.push(["+", b[j++]]);
  }
  while (i < n) out.push(["-", a[i++]]);
  while (j < m) out.push(["+", b[j++]]);
  return out;
}

function diffLine(cls, text) {
  const s = document.createElement("span");
  if (cls) s.className = cls;
  s.textContent = text + "\n";
  return s;
}

function pre(text) {
  const p = document.createElement("pre");
  p.textContent = text;
  return p;
}

function basename(path) { return path.split("/").pop(); }

// ---------- Markdown (escaped first, then a small safe subset) ----------

function escapeHTML(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function inline(s) {
  // `code` first, so nothing inside it is formatted.
  const codes = [];
  s = s.replace(/`([^`\n]+)`/g, (_, c) => { codes.push(c); return "\u0000" + (codes.length - 1) + "\u0000"; });
  s = s.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, text, url) => {
    const href = url.replace(/&amp;/g, "&");
    return /^(https?:|mailto:)/i.test(href) ? `<a href="${url}" target="_blank" rel="noopener noreferrer">${text}</a>` : m;
  });
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (_, pre, url) => `${pre}<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^_\w])_([^_\n]+)_(?!\w)/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => "<code>" + codes[+i] + "</code>");
}

function markdown(src) {
  const out = [];
  const parts = src.split(/^```[^\n]*\n?/m);
  // Odd parts are inside a fence (an unclosed one runs to the end).
  parts.forEach((part, i) => {
    if (i % 2 === 1) { out.push("<pre><code>" + escapeHTML(part.replace(/\n$/, "")) + "</code></pre>"); return; }
    out.push(blocks(escapeHTML(part)));
  });
  return out.join("");
}

// A table's delimiter row: | --- | :--: | ---: | (outer pipes optional).
const delimiterRow = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;

// A row's cells: split on pipes that aren't escaped, without the outer ones.
function cells(row) {
  let r = row.trim();
  if (r.startsWith("|")) r = r.slice(1);
  if (r.endsWith("|") && !r.endsWith("\\|")) r = r.slice(0, -1);
  return r.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
}

// A table starts at a row with a pipe whose next line is a delimiter row
// (so a header streamed in alone stays text until its delimiter arrives).
function tableAt(lines, i) {
  const head = lines[i], next = lines[i + 1];
  if (next === undefined || !head.includes("|") || !delimiterRow.test(next) || !next.includes("-")) return null;
  const header = cells(head);
  if (header.length < 2 && !head.trim().startsWith("|")) return null;
  const align = cells(next).map((c) => c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : "");
  const rows = [];
  let j = i + 2;
  while (j < lines.length && lines[j].trim() && lines[j].includes("|") && !delimiterRow.test(lines[j])) rows.push(cells(lines[j++]));
  const cell = (tag, text, k) => `<${tag}${align[k] ? ` style="text-align:${align[k]}"` : ""}>` + inline(text).replace(/&lt;br\s*\/?&gt;/gi, "<br>") + `</${tag}>`;
  const html = '<div class="table-wrap"><table><thead><tr>' + header.map((h, k) => cell("th", h, k)).join("") + "</tr></thead><tbody>"
    + rows.map((r) => "<tr>" + header.map((_, k) => cell("td", r[k] ?? "", k)).join("") + "</tr>").join("") + "</tbody></table></div>";
  return { html, end: j };
}

function blocks(text) {
  const lines = text.split("\n");
  const html = [];
  let para = [], list = null, quote = [];
  const flushPara = () => { if (para.length) { html.push("<p>" + inline(para.join("<br>")) + "</p>"); para = []; } };
  const flushList = () => { if (list) { html.push(`<${list.tag}>` + list.items.map((x) => "<li>" + inline(x) + "</li>").join("") + `</${list.tag}>`); list = null; } };
  // A quote holds blocks of its own (a table, a list).
  const flushQuote = () => { if (quote.length) { html.push("<blockquote>" + blocks(quote.join("\n")) + "</blockquote>"); quote = []; } };
  const flushAll = () => { flushPara(); flushList(); flushQuote(); };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let m;
    if ((m = line.match(/^&gt;\s?(.*)$/))) { flushPara(); flushList(); quote.push(m[1]); continue; }
    flushQuote();
    if (!line.trim()) { flushAll(); continue; }
    const table = tableAt(lines, i);
    if (table) { flushAll(); html.push(table.html); i = table.end - 1; continue; }
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { flushAll(); const n = Math.min(m[1].length + 1, 4); html.push(`<h${n}>` + inline(m[2]) + `</h${n}>`); continue; }
    if ((m = line.match(/^\s*[-*+]\s+(.*)$/))) { flushPara(); if (!list || list.tag !== "ul") { flushList(); list = { tag: "ul", items: [] }; } list.items.push(m[1]); continue; }
    if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) { flushPara(); if (!list || list.tag !== "ol") { flushList(); list = { tag: "ol", items: [] }; } list.items.push(m[1]); continue; }
    if (/^\s*([-*_])\s*\1\s*\1[\s\1]*$/.test(line)) { flushAll(); html.push("<hr>"); continue; }
    if (list) { list.items[list.items.length - 1] += " " + line.trim(); continue; }
    para.push(line);
  }
  flushAll();
  return html.join("");
}

// ---------- Cards: permission and question ----------

function renderCards() {
  const s = state.status;
  const cards = [];
  if (s?.permission) cards.push(permissionCard(s.permission));
  if (s?.question) cards.push(questionCard(s.question));
  // Keep a card someone is typing in.
  const key = JSON.stringify([s?.permission?.id, s?.question?.id]);
  if (el.cards.dataset.key === key) return;
  el.cards.dataset.key = key;
  el.cards.replaceChildren(...cards);
}

function permissionCard(p) {
  const card = document.createElement("div");
  card.className = "card";
  const h = document.createElement("h3");
  h.innerHTML = inline(escapeHTML(p.title));
  const actions = document.createElement("div");
  actions.className = "actions";
  for (const o of p.options) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = o.name;
    if (o.kind === "allow_once") b.className = "primary";
    if (o.kind.startsWith("reject")) b.className = "danger";
    b.addEventListener("click", () => command("permission", { permission: p.id, option: o.id }, b));
    actions.append(b);
  }
  card.append(h, actions);
  return card;
}

function questionCard(q) {
  const card = document.createElement("form");
  card.className = "card";
  const h = document.createElement("h3");
  h.innerHTML = inline(escapeHTML(q.message));
  card.append(h);
  const actions = document.createElement("div");
  actions.className = "actions";
  if (q.url) {
    const a = document.createElement("a");
    a.href = q.url; a.target = "_blank"; a.rel = "noopener noreferrer";
    a.textContent = "Open " + new URL(q.url).host;
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Opens on this device — the agent waits until you say you're done.";
    card.append(a, p);
    actions.append(button("Done", "primary", () => command("question", { question: q.id, action: "accept", content: {} })),
      button("Cancel", "", () => command("question", { question: q.id, action: "cancel" })));
    card.append(actions);
    return card;
  }
  const inputs = [];
  for (const f of q.fields) {
    const wrap = document.createElement("div");
    wrap.className = "field";
    if (f.title || !f.companionOf) wrap.append(span("label", f.title || (f.companionOf ? "" : f.id)));
    if (f.detail) wrap.append(span("detail", f.detail));
    const name = "f-" + f.id;
    if (f.kind === "choice" || f.kind === "multiChoice") {
      for (const o of f.options || []) {
        const row = document.createElement("label");
        row.className = "option";
        const input = document.createElement("input");
        input.type = f.kind === "choice" ? "radio" : "checkbox";
        input.name = name; input.value = o.id;
        row.append(input, document.createTextNode(o.name));
        wrap.append(row);
      }
      inputs.push(() => {
        const checked = [...card.querySelectorAll(`input[name="${CSS.escape(name)}"]:checked`)].map((i) => i.value);
        return f.kind === "choice" ? checked[0] : checked;
      });
    } else if (f.kind === "toggle") {
      const row = document.createElement("label");
      row.className = "option";
      const input = document.createElement("input");
      input.type = "checkbox";
      row.append(input, document.createTextNode("Yes"));
      wrap.append(row);
      inputs.push(() => input.checked);
    } else {
      const input = document.createElement("input");
      input.type = f.kind === "number" ? "number" : f.secret ? "password" : "text";
      wrap.append(input);
      inputs.push(() => (f.kind === "number" ? (input.value === "" ? undefined : Number(input.value)) : input.value || undefined));
    }
    card.append(wrap);
  }
  actions.append(button("Submit", "primary", () => {
    const content = {};
    q.fields.forEach((f, i) => { const v = inputs[i](); if (v !== undefined && !(Array.isArray(v) && !v.length)) content[f.id] = v; });
    command("question", { question: q.id, action: "accept", content });
  }), button("Skip", "", () => command("question", { question: q.id, action: "decline" })));
  card.append(actions);
  card.addEventListener("submit", (e) => e.preventDefault());
  return card;
}

function button(text, cls, onClick) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = text;
  if (cls) b.className = cls;
  b.addEventListener("click", onClick);
  return b;
}

// ---------- Status, mode ----------

function renderStatus() {
  const s = state.status;
  const working = s?.phase === "running";
  el.send.classList.toggle("stop", working && !el.input.value.trim() && !state.pending.length);
  el.send.setAttribute("aria-label", el.send.classList.contains("stop") ? "Stop" : "Send");
  el.send.disabled = !s || s.phase === "closed" || (!working && !el.input.value.trim() && !state.pending.length);
  const left = document.createElement("span");
  if (!s) left.textContent = state.current ? "Connecting…" : "";
  else if (s.phase === "starting") left.textContent = "Starting…";
  else if (working) { left.className = "working"; left.textContent = "Working…" + (s.queued ? ` · ${s.queued} queued` : ""); }
  else if (s.phase === "closed") { left.className = "error"; left.textContent = s.closedReason || "Closed"; }
  const right = document.createElement("span");
  if (s?.usage?.size) {
    right.textContent = Math.round((s.usage.used / s.usage.size) * 100) + "% context" + (s.usage.cost != null ? " · $" + s.usage.cost.toFixed(2) : "");
  }
  el.status.replaceChildren(left, right);
  const modes = s?.modes || [];
  el.mode.hidden = modes.length < 2;
  if (modes.length >= 2) {
    const key = modes.map((m) => m.id).join("|");
    if (el.mode.dataset.key !== key) {
      el.mode.dataset.key = key;
      el.mode.replaceChildren(...modes.map((m) => new Option(m.name, m.id)));
    }
    el.mode.value = s.currentMode || modes[0].id;
  }
}

el.mode.addEventListener("change", () => command("mode", { mode: el.mode.value }));

// ---------- Composer ----------

const touch = matchMedia("(pointer: coarse)").matches;

el.input.addEventListener("input", () => { autosize(); renderStatus(); });
el.input.addEventListener("keydown", (e) => {
  // Enter sends on a keyboard computer; on a phone it's a new line (the send button sends).
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing && (!touch || e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    submit();
  }
});
el.composer.addEventListener("submit", (e) => { e.preventDefault(); submit(); });

function autosize() {
  el.input.style.height = "auto";
  el.input.style.height = Math.min(el.input.scrollHeight, innerHeight * 0.4) + "px";
}

async function submit() {
  const text = el.input.value.trim();
  if (!text && !state.pending.length) {
    if (state.status?.phase === "running") command("cancel", {});
    return;
  }
  const images = state.pending.map(({ name, mimeType, data }) => ({ name, mimeType, data }));
  const ok = await command("send", { text, images });
  if (ok) {
    el.input.value = "";
    state.pending = [];
    renderAttachments();
    autosize();
    renderStatus();
    scrollToBottom();
  }
}

el.file.addEventListener("change", async () => {
  await attach([...el.file.files]);
  el.file.value = "";
});

// Images pasted into the message box (a screenshot, a copied photo) attach;
// text pastes as usual.
el.input.addEventListener("paste", (e) => {
  const images = [...(e.clipboardData?.items || [])]
    .filter((item) => item.kind === "file" && item.type.startsWith("image/"))
    .map((item) => item.getAsFile())
    .filter(Boolean);
  if (!images.length) return;
  e.preventDefault();
  const text = e.clipboardData.getData("text/plain");
  if (text) document.execCommand("insertText", false, text);
  attach(images);
});

// …and images dropped anywhere on the chat.
el.chatPane.addEventListener("dragover", (e) => {
  if ([...(e.dataTransfer?.items || [])].some((i) => i.kind === "file")) e.preventDefault();
});
el.chatPane.addEventListener("drop", (e) => {
  const files = [...(e.dataTransfer?.files || [])].filter((f) => f.type.startsWith("image/"));
  if (!files.length) return;
  e.preventDefault();
  attach(files);
});

async function attach(files) {
  for (const file of files) {
    try { state.pending.push(await shrink(file)); } catch { flash("Couldn’t read " + (file.name || "the image")); }
  }
  renderAttachments();
  renderStatus();
  el.input.focus();
}

// Photos from a phone are big: send at most 2048 px, as JPEG.
function shrink(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 2048 / Math.max(img.naturalWidth, img.naturalHeight));
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(img.naturalWidth * scale);
      canvas.height = Math.round(img.naturalHeight * scale);
      canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height);
      const keepPNG = file.type === "image/png" && scale === 1;
      const type = keepPNG ? "image/png" : "image/jpeg";
      const dataURL = canvas.toDataURL(type, 0.85);
      URL.revokeObjectURL(url);
      // A pasted image has a generic name ("image.png"): call it what it is.
      const name = !file.name || /^image\.\w+$/.test(file.name) ? "Pasted image" : file.name;
      resolve({ name, mimeType: type, data: dataURL.split(",")[1], url: dataURL });
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("not an image")); };
    img.src = url;
  });
}

function renderAttachments() {
  el.attachments.hidden = !state.pending.length;
  el.attachments.replaceChildren(...state.pending.map((p, i) => {
    const t = document.createElement("div");
    t.className = "thumb";
    const img = document.createElement("img");
    img.src = p.url;
    img.alt = p.name;
    const x = document.createElement("button");
    x.type = "button";
    x.textContent = "×";
    x.setAttribute("aria-label", "Remove " + p.name);
    x.addEventListener("click", () => { state.pending.splice(i, 1); renderAttachments(); renderStatus(); });
    t.append(img, x);
    return t;
  }));
}

// ---------- Commands ----------

async function command(name, body, button, session = state.current) {
  if (!session) return false;
  if (button) button.disabled = true;
  try {
    if (native) {
      const r = await native.postMessage({ name, body: JSON.stringify(body ?? {}) });
      if (r.status >= 300) { flash((JSON.parse(r.body || "{}")).error || "Sandshell said no (" + r.status + ")"); return false; }
      return true;
    }
    const r = await post(`/api/sessions/${session}/${name}`, body);
    if (!r.ok) { flash((await r.json().catch(() => ({}))).error || "The Mac said no (" + r.status + ")"); return false; }
    return true;
  } catch (err) {
    flash("Couldn’t reach the Mac");
    return false;
  } finally {
    if (button) button.disabled = false;
  }
}

function post(url, body) {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Sandshell": "1" },
    body: JSON.stringify(body),
  });
}

function flash(message) {
  const s = document.createElement("span");
  s.className = "error";
  s.textContent = message;
  el.status.replaceChildren(s);
  setTimeout(renderStatus, 4000);
}

// ---------- /check: the flow, in this device's browser ----------

let checking = false;

async function runChecks() {
  if (checking) return;
  checking = true;
  el.checkResults.replaceChildren();
  const results = [];
  const report = (name, ok, detail = "") => {
    results.push({ name, ok, detail });
    const li = document.createElement("li");
    li.className = ok ? "pass" : "fail";
    li.append(span("mark", ok ? "✓" : "✕"), span("name", name));
    if (detail) li.append(span("detail", detail));
    el.checkResults.append(li);
  };
  const started = Date.now();
  try {
    const info = await (await fetch("/api/info")).json();
    report("Reached " + info.host, true);
    const check = info.sessions.find((s) => s.isCheck);
    if (!check) {
      report("Check session", false, "Turn on Help ▸ Remote Check Session on the Mac (a Debug build).");
      return;
    }
    await withSession(check.id, async (watch) => {
      await watch.until("state", () => true, 10000, "the check session's state");
      report("Opened the check session", true);
      await waitReady(watch);

      await command("send", { text: "hello from " + deviceName(), images: [] }, null, check.id);
      const pong = await watch.untilItem((i) => i.kind === "text" && /pong: hello from/.test(i.text || ""), 15000, "a pong");
      report("Sent a message and got the reply", !!pong, pong?.text || "");
      await waitReady(watch);

      await command("send", { text: "image please", images: [] }, null, check.id);
      const image = await watch.untilItem((i) => i.kind === "image", 15000, "an image");
      let loaded = false;
      if (image) loaded = await loadImage(image.image);
      report("Received an image", !!image && loaded, image ? image.image : "");
      await waitReady(watch);

      const photo = await tinyPhoto();
      await command("send", { text: "", images: [photo] }, null, check.id);
      const got = await watch.untilItem((i) => i.kind === "text" && /I got 1 image/.test(i.text || ""), 15000, "the image acknowledged");
      report("Sent an image", !!got);
      await waitReady(watch);

      await command("send", { text: "ask permission", images: [] }, null, check.id);
      const perm = await watch.until("status", (s) => s?.permission, 15000, "a permission prompt");
      report("A permission prompt arrived", !!perm, perm?.permission?.title || "");
      if (perm) {
        await command("permission", { permission: perm.permission.id, option: "allow_once" }, null, check.id);
        const answered = await watch.untilItem((i) => i.kind === "text" && /Permission: allow_once/.test(i.text || ""), 15000, "the answer");
        report("Answered it (Allow)", !!answered);
      }
      await waitReady(watch);

      await command("send", { text: "ask a question", images: [] }, null, check.id);
      const q = await watch.until("status", (s) => s?.question, 15000, "a question");
      report("A question arrived", !!q, q?.question?.message || "");
      if (q) {
        await command("question", { question: q.question.id, action: "accept", content: { colour: "green" } }, null, check.id);
        const answered = await watch.untilItem((i) => i.kind === "text" && /Answer: accept green/.test(i.text || ""), 15000, "the answer");
        report("Answered it (green)", !!answered);
      }
      await waitReady(watch);

      await command("send", { text: "slow", images: [] }, null, check.id);
      const busy = await watch.until("status", (s) => s?.phase === "running", 10000, "working");
      await command("cancel", {}, null, check.id);
      const stopped = await watch.until("status", (s) => s?.phase === "ready", 10000, "stopped");
      report("Stopped a turn", !!busy && !!stopped);
    });
  } catch (err) {
    report("Unexpected error", false, String(err && err.message || err));
  } finally {
    const failed = results.filter((r) => !r.ok).length;
    const li = document.createElement("li");
    li.className = failed ? "fail" : "pass";
    li.append(span("mark", failed ? "✕" : "✓"), span("summary", failed ? failed + " failed" : "All passed"),
      span("detail", ((Date.now() - started) / 1000).toFixed(1) + " s · " + deviceName()));
    el.checkResults.append(li);
    post("/api/check", { device: deviceName(), userAgent: navigator.userAgent, results }).catch(() => {});
    checking = false;
  }
}

el.checkRun.addEventListener("click", () => runChecks());

function deviceName() {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Windows/.test(ua)) return "Windows";
  if (/Macintosh/.test(ua)) return "Mac";
  return "Browser";
}

// A second event stream for the check session, with ways to wait on it.
async function withSession(id, body) {
  const stream = new EventSource("/api/events?session=" + encodeURIComponent(id));
  const items = new Map();
  let status = null, gotState = false;
  const waiters = new Set();
  const notify = () => { for (const w of [...waiters]) w(); };
  for (const name of ["state", "patch"]) {
    stream.addEventListener(name, (e) => {
      const d = JSON.parse(e.data);
      if (name === "state") { gotState = true; items.clear(); for (const i of d.items) items.set(i.id, i); status = d.status; }
      else { for (const i of d.upserts) items.set(i.id, i); if (d.status) status = d.status; }
      notify();
    });
  }
  const wait = (test, timeout) => new Promise((resolve) => {
    const check = () => { const v = test(); if (v) { waiters.delete(check); clearTimeout(timer); resolve(v); } };
    const timer = setTimeout(() => { waiters.delete(check); resolve(null); }, timeout);
    waiters.add(check);
    check();
  });
  const seen = new Set();
  const watch = {
    until: (what, test, timeout) => wait(() => (what === "state" ? gotState : test(status)) && { status, permission: status?.permission, question: status?.question }, timeout),
    // An item that wasn't there before this call.
    untilItem: (test, timeout) => {
      const before = new Set(items.keys());
      return wait(() => { for (const [id, i] of items) if (!before.has(id) && !seen.has(id) && test(i)) { seen.add(id); return i; } return null; }, timeout);
    },
  };
  try { await body(watch); } finally { stream.close(); }
}

async function waitReady(watch) { await watch.until("status", (s) => s?.phase === "ready" && !s.permission && !s.question, 15000); }

function loadImage(src) {
  return new Promise((resolve) => { const i = new Image(); i.onload = () => resolve(i.naturalWidth > 0); i.onerror = () => resolve(false); i.src = src; });
}

async function tinyPhoto() {
  const c = document.createElement("canvas");
  c.width = 32; c.height = 32;
  const g = c.getContext("2d");
  g.fillStyle = "#3d8bff"; g.fillRect(0, 0, 32, 32);
  g.fillStyle = "#fff"; g.fillRect(8, 8, 16, 16);
  return { name: "check.png", mimeType: "image/png", data: c.toDataURL("image/png").split(",")[1] };
}

// ---------- Pairing ----------

/// Whether this browser may use the Mac (else the pairing screen is up).
async function checkPaired() {
  try {
    const r = await fetch("/api/info", { cache: "no-store" });
    if (r.status === 401) {
      const info = await r.json().catch(() => ({}));
      showPairing(info.host);
      return false;
    }
    return r.ok;
  } catch {
    return true;   // the Mac's unreachable: not a pairing problem
  }
}

function showPairing(host) {
  if (state.stream) { state.stream.close(); state.stream = null; }
  el.app.classList.add("pairing");
  el.pairPane.hidden = false;
  if (host) { el.pairHost.textContent = host; document.title = "Pair with " + host; }
  if (!el.pairName.value) el.pairName.value = deviceName();
  setTimeout(() => el.pairCode.focus(), 50);
}

el.pairCode.addEventListener("input", () => {
  const digits = el.pairCode.value.replace(/\D/g, "").slice(0, 6);
  el.pairCode.value = digits.length > 3 ? digits.slice(0, 3) + " " + digits.slice(3) : digits;
  el.pairError.textContent = "";
  if (digits.length === 6) pair({ code: digits });
});

el.pairForm.addEventListener("submit", (e) => {
  e.preventDefault();
  pair({ code: el.pairCode.value.replace(/\D/g, "") });
});

let pairing = false;

async function pair(answer) {
  if (pairing) return;
  pairing = true;
  el.pairSubmit.disabled = true;
  el.pairError.textContent = "";
  try {
    const r = await post("/api/pair", { ...answer, name: el.pairName.value.trim() || deviceName() });
    if (r.ok) {
      // Paired: the cookie's set. Start over where the device meant to go.
      location.replace(location.pathname === "/pair" ? "/" : location.pathname);
      return;
    }
    const body = await r.json().catch(() => ({}));
    showPairing();
    el.pairError.textContent = body.error || "The Mac said no (" + r.status + ")";
    el.pairCode.select();
  } catch {
    el.pairError.textContent = "Couldn’t reach the Mac";
  } finally {
    pairing = false;
    el.pairSubmit.disabled = false;
  }
}

// ---------- Tool calls: a run of them is one quiet line, opening to the calls ----------

const verbWords = {
  run: ["Ran", "Running", "a command", "commands"],
  read: ["Read", "Reading", "a file", "files"],
  edit: ["Edited", "Editing", "a file", "files"],
  search: ["Searched", "Searching", "once", "times"],
  fetch: ["Fetched", "Fetching", "a page", "pages"],
  other: ["Used", "Using", "a tool", "tools"],
};

function toolVerb(kind) {
  switch ((kind || "").toLowerCase()) {
    case "execute": case "bash": case "bashoutput": return "run";
    case "read": case "notebookread": return "read";
    case "edit": case "delete": case "move": case "write": case "multiedit": case "notebookedit": return "edit";
    case "search": case "grep": case "glob": case "ls": return "search";
    case "fetch": case "webfetch": case "websearch": return "fetch";
    default: return "other";
  }
}

// "Ran git status --short", "Ran 2 commands and read a file", "Running …".
function groupSummary(tools, running) {
  const clean = (s) => (s || "").replace(/`/g, "").trim();
  if (tools.length === 1) {
    const t = tools[0], verb = toolVerb(t.kind), w = verbWords[verb];
    const lead = running ? w[1] : w[0];
    const raw = clean(t.input || t.title);
    const first = raw.split("\n")[0];
    switch (verb) {
      case "run": {
        const short = first.length > 48 ? first.slice(0, 45) : first;
        return short ? lead + " " + short + (short !== raw ? "…" : "") : lead + " " + w[2];
      }
      case "read": case "edit": {
        const name = first.split("/").pop();
        return name ? lead + " " + name : lead + " " + w[2];
      }
      case "search": return first ? lead + " for " + (first.length > 40 ? first.slice(0, 37) + "…" : first) : lead;
      case "fetch": { let host = ""; try { host = new URL(first).host; } catch {} return lead + " " + (host || w[2]); }
      default: {
        const title = clean(t.title || t.kind);
        return title.length > 60 ? title.slice(0, 57) + "…" : title;
      }
    }
  }
  const counts = new Map();
  for (const t of tools) { const v = toolVerb(t.kind); counts.set(v, (counts.get(v) || 0) + 1); }
  const phrases = [...counts].map(([verb, n], i) => {
    const w = verbWords[verb], lead = running ? w[1] : w[0];
    const object = n === 1 ? w[2] : verb === "search" ? n + " times" : n + " " + w[3];
    return (i === 0 ? lead : lead.toLowerCase()) + " " + object;
  });
  return new Intl.ListFormat("en", { type: "conjunction" }).format(phrases) + (running ? "…" : "");
}

// Before each run of tool calls, its line; the calls show when it's open.
function groupTools() {
  for (const h of el.transcript.querySelectorAll(":scope > .tool-group")) h.remove();
  let run = [];
  const flush = () => {
    if (!run.length) return;
    const id = run[0].dataset.id;
    const tools = run.map((n) => state.items.get(n.dataset.id)?.tool).filter(Boolean);
    const running = tools.some((t) => t.status === "pending" || t.status === "in_progress");
    const failed = tools.filter((t) => t.status === "failed").length;
    const open = state.openGroups.has(id);
    const line = document.createElement("button");
    line.type = "button";
    line.className = "tool-group" + (running ? " running" : "");
    line.dataset.group = id;
    line.title = open ? "Hide the tool calls" : "Show the tool calls";
    line.setAttribute("aria-expanded", open);
    line.textContent = groupSummary(tools, running) + (open ? "  ⌄" : "  ›");
    if (failed) line.append(span("failed", failed === 1 && tools.length === 1 ? "  · failed" : "  · " + failed + " failed"));
    el.transcript.insertBefore(line, run[0]);
    for (const n of run) n.classList.toggle("collapsed", !open);
    run = [];
  };
  for (const node of [...el.transcript.children]) {
    if (node.classList.contains("tool")) run.push(node); else flush();
  }
  flush();
}

el.transcript.addEventListener("click", (e) => {
  const more = e.target.closest(".bubble > .more");
  if (more) {
    const id = more.closest(".item").dataset.id;
    const open = !state.openMessages.has(id);
    if (open) state.openMessages.add(id); else state.openMessages.delete(id);
    more.closest(".bubble").classList.toggle("folded", !open);
    more.textContent = open ? "Less" : "More";
    more.title = open ? "Show Less" : "Show All of It";
    return;
  }
  const line = e.target.closest(".tool-group");
  if (!line) return;
  const id = line.dataset.group;
  if (state.openGroups.has(id)) state.openGroups.delete(id); else state.openGroups.add(id);
  groupTools();
});

// ---------- In Sandshell's window: the transcript's own parts ----------

const fileLinks = { byItem: new Map(), asked: new Map(), timers: new Map() };
const ui = {};

function configure(c) {
  state.config = c;
  const root = document.documentElement;
  root.classList.toggle("can-fork", !!c.canFork);
  root.classList.toggle("can-undo", !!c.canUndo);
  if (c.replyFont) root.style.setProperty("--reply-font", c.replyFont);
  if (c.messageFont) root.style.setProperty("--message-font", c.messageFont);
  // The app's type scale (Theme.swift's TypeRole), so the page and the
  // window never drift apart.
  for (const [name, size] of Object.entries({ small: c.sizes?.small, ui: c.sizes?.ui, read: c.sizes?.reading })) {
    if (size) root.style.setProperty("--t-" + name, size + "px");
  }
  artboardStrips();
}

// ---------- In Sandshell's window: what a turn drew on its board ----------

// A design session's board put away (config.artboards: its color): after
// each turn that wrote pages on it, a strip of those artboards. The Mac says
// which written files are artboards on this chat's board, and serves their
// pages; a frame's click shows the board, on that artboard.
const strips = { nodes: new Map() };
const boardPage = /\/\.sandshell\/canvas\/[^/]+\/[^/]+\.html?$/i;
const paletteSVG = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 2a6 6 0 1 0 0 12c1 0 1.3-.7 1-1.4-.4-.8.1-1.6 1-1.6h1.5A2.5 2.5 0 0 0 14 8.5C14 5 11.3 2 8 2z"/><circle cx="5" cy="7.5" r=".8"/><circle cx="7.3" cy="4.8" r=".8"/><circle cx="10.5" cy="5.4" r=".8"/></svg>';

// Each turn (from one of your messages to the next) that wrote board pages:
// its first and last items, the pages, and how many writes (a rewrite redraws).
function turnsWithArtboards() {
  const turns = [];
  let turn = null;
  for (const id of state.order) {
    const item = state.items.get(id);
    if (!item) continue;
    if (item.kind === "user" || !turn) { turn = { first: id, last: id, paths: [], writes: 0 }; turns.push(turn); }
    turn.last = id;
    for (const d of item.tool?.diffs || []) {
      if (!boardPage.test(d.path || "")) continue;
      turn.writes++;
      if (!turn.paths.includes(d.path)) turn.paths.push(d.path);
    }
  }
  return turns.filter((t) => t.paths.length);
}

function artboardStrips() {
  const want = new Set();
  if (transcriptOnly && state.config?.artboards) {
    for (const t of turnsWithArtboards()) {
      const key = t.first + "|" + t.writes + "|" + t.paths.join("|");
      want.add(key);
      let node = strips.nodes.get(key);
      if (!node) { node = buildStrip(t.paths); strips.nodes.set(key, node); }
      node.style.setProperty("--strip", state.config.artboards);
      const after = state.nodes.get(t.last);
      // Moving a strip reloads its pages: only when it's out of place.
      if (after && after.isConnected && after.nextSibling !== node) after.after(node);
    }
  }
  for (const [key, node] of strips.nodes) if (!want.has(key)) { node.remove(); strips.nodes.delete(key); }
}

function buildStrip(paths) {
  const box = document.createElement("div");
  box.className = "artboard-strip";
  box.hidden = true;   // until the Mac says these are artboards
  const head = document.createElement("div");
  head.className = "head";
  const mark = document.createElement("span");
  mark.className = "mark";
  mark.innerHTML = paletteSVG;
  const title = span("title", "Board");
  const count = span("count", "");
  const show = actionButton("show", "Show Board ›", "Show the board beside this chat");
  show.addEventListener("click", () => post("showArtboard", {}));
  head.append(mark, title, count, show);
  const frames = document.createElement("div");
  frames.className = "frames";
  box.append(head, frames);
  post("artboards", { paths }).then((r) => {
    let list = [];
    try { list = JSON.parse(r.body).artboards || []; } catch { return; }
    if (!list.length) return;
    title.textContent = list[0].boardTitle || "Board";
    count.textContent = list.length + (list.length === 1 ? " artboard" : " artboards");
    for (const a of list.slice(0, 8)) frames.append(artboardFrame(a));
    box.hidden = false;
  }).catch(() => {});
  return box;
}

// One artboard, its page drawn small (scaled from its own size), and its title.
function artboardFrame(a) {
  const width = 168, scale = width / Math.max(a.width, 1);
  const b = document.createElement("button");
  b.type = "button";
  b.className = "frame";
  b.title = "Show “" + a.title + "” on the board";
  const view = document.createElement("div");
  view.className = "view";
  view.style.width = width + "px";
  view.style.height = Math.min(Math.round(a.height * scale), 140) + "px";
  const page = document.createElement("iframe");
  page.src = "/board/" + encodeURIComponent(a.board) + "/" + a.file.split("/").map(encodeURIComponent).join("/");
  page.loading = "lazy";
  page.tabIndex = -1;
  page.setAttribute("sandbox", "allow-scripts");
  page.setAttribute("aria-hidden", "true");
  page.style.width = a.width + "px";
  page.style.height = a.height + "px";
  page.style.transform = "scale(" + scale + ")";
  view.append(page);
  b.append(view, span("name", a.title));
  b.addEventListener("click", () => post("showArtboard", { id: a.id }));
  return b;
}

function post(name, fields) {
  return native.postMessage({ name, body: JSON.stringify(fields ?? {}) });
}

function actionButton(cls, label, title) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = cls;
  b.textContent = label;
  if (title) b.title = title;
  return b;
}

// Copy and Fork on a reply, Copy on your message, Copy on a code block,
// Undo on a turn's changes; file paths that exist on the Mac become links.
function decorate(item, div) {
  if (item.kind === "text" || (item.kind === "user" && item.text)) {
    const bar = document.createElement("div");
    bar.className = "actions";
    bar.append(actionButton("act-copy", "Copy", item.kind === "text" ? "Copy Reply" : "Copy Message"));
    if (item.kind === "text") bar.append(actionButton("act-fork", "Fork", "Fork to New Chat"));
    div.append(bar);
  }
  for (const pre of div.querySelectorAll(".text pre, .item.text > pre")) {
    const wrap = document.createElement("div");
    wrap.className = "code";
    pre.replaceWith(wrap);
    wrap.append(pre, actionButton("copy-code", "Copy", "Copy Code"));
  }
  if (item.kind === "changes" && item.turn && !item.restored) {
    const undo = actionButton("act-undo", "Undo", "Put these files back as they were before this turn");
    undo.dataset.turn = item.turn;
    div.append(" ", undo);
  }
  if (["text", "user", "thought", "notice", "tool", "changes"].includes(item.kind)) linkFiles(item.id, div);
}

// What an item shows, without its buttons.
function shownText(node) {
  const copy = node.cloneNode(true);
  for (const b of copy.querySelectorAll(".actions, button")) b.remove();
  return copy;
}

// The Mac finds the paths that name files (it can look on disk); the page
// links them. Known links go on at once (a streaming reply re-renders), and
// the Mac is asked again once the text settles.
function linkFiles(id, node) {
  const known = fileLinks.byItem.get(id);
  if (known?.length) wrapFileLinks(node, known);
  clearTimeout(fileLinks.timers.get(id));
  fileLinks.timers.set(id, setTimeout(() => askFileLinks(id), known ? 400 : 120));
}

async function askFileLinks(id) {
  fileLinks.timers.delete(id);
  const node = state.nodes.get(id);
  if (!node || !node.isConnected) return;
  const text = shownText(node).textContent;
  if (!text.trim() || fileLinks.asked.get(id) === text) return;
  fileLinks.asked.set(id, text);
  const code = [...node.querySelectorAll("code")].filter((c) => !c.closest("pre")).map((c) => c.textContent);
  let links;
  try { links = JSON.parse((await post("fileLinks", { text, code })).body).links || []; } catch { return; }
  fileLinks.byItem.set(id, links);
  const now = state.nodes.get(id);
  if (now && links.length) wrapFileLinks(now, links);
}

function wrapFileLinks(node, links) {
  const byText = new Map(links.map((l) => [l.text, l]));
  const alternatives = [...byText.keys()].sort((a, b) => b.length - a.length)
    .map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!alternatives.length) return;
  const re = new RegExp("(?<![\\w/.~-])(" + alternatives.join("|") + ")(?![\\w/@+-])", "g");
  const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => n.parentElement?.closest("a, button, .actions") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
  });
  const texts = [];
  while (walker.nextNode()) texts.push(walker.currentNode);
  for (const t of texts) {
    const s = t.nodeValue;
    re.lastIndex = 0;
    let m, last = 0;
    const frag = document.createDocumentFragment();
    while ((m = re.exec(s))) {
      const link = byText.get(m[1]);
      frag.append(s.slice(last, m.index));
      const a = document.createElement("a");
      a.className = "file";
      a.href = "#";
      a.dataset.path = link.path;
      if (link.line != null) a.dataset.line = link.line;
      a.title = link.path + (link.line != null ? ":" + link.line : "");
      a.textContent = m[1];
      frag.append(a);
      last = m.index + m[1].length;
    }
    if (last) { frag.append(s.slice(last)); t.replaceWith(frag); }
  }
}

function copied(b) {
  const was = b.textContent;
  b.textContent = "Copied";
  b.classList.add("done");
  setTimeout(() => { b.textContent = was; b.classList.remove("done"); }, 1200);
}

function onTranscriptClick(e) {
  const target = e.target.closest("a, button");
  if (!target || !el.transcript.contains(target)) return;
  const node = target.closest(".item");
  const item = node && state.items.get(node.dataset.id);
  if (target.matches("a.file")) {
    e.preventDefault();
    post("openFile", { path: target.dataset.path, line: target.dataset.line ? +target.dataset.line : null });
  } else if (target.matches("a[href]")) {
    e.preventDefault();
    post("openURL", { url: target.href });
  } else if (target.matches(".act-copy") && item) {
    const html = shownText(node);
    post("copy", { text: item.text || "", html: item.kind === "text" ? html.innerHTML : "" });
    copied(target);
  } else if (target.matches(".act-fork") && item) {
    post("fork", { text: item.text || "" });
  } else if (target.matches(".copy-code")) {
    post("copy", { text: target.parentElement.querySelector("pre").textContent });
    copied(target);
  } else if (target.matches(".act-undo")) {
    post("undo", { turn: target.dataset.turn });
  }
}

// Find (⌘F, ⌘G, ⇧⌘G come from the window).
function find(action) {
  if (!ui.find) {
    const bar = document.createElement("div");
    bar.id = "find";
    const input = document.createElement("input");
    input.type = "search";
    input.placeholder = "Find";
    input.setAttribute("aria-label", "Find in the conversation");
    const count = document.createElement("span");
    count.className = "count";
    const prev = actionButton("prev", "‹", "Previous (⇧⌘G)");
    const next = actionButton("next", "›", "Next (⌘G)");
    const done = actionButton("done", "Done");
    bar.append(input, count, prev, next, done);
    document.body.append(bar);
    ui.find = { bar, input, count };
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); find(e.shiftKey ? "previous" : "next"); }
      if (e.key === "Escape") { e.preventDefault(); find("hide"); }
    });
    input.addEventListener("input", () => { getSelection().removeAllRanges(); if (input.value) find("next"); else count.textContent = ""; });
    prev.addEventListener("click", () => find("previous"));
    next.addEventListener("click", () => find("next"));
    done.addEventListener("click", () => find("hide"));
  }
  const f = ui.find;
  if (action === "hide") { f.bar.classList.remove("shown"); return; }
  if (action === "show" || !f.bar.classList.contains("shown")) {
    f.bar.classList.add("shown");
    f.input.focus();
    f.input.select();
    if (action === "show") return;
  }
  if (!f.input.value) return;
  // window.find searches from the selection: keep it out of the find field.
  f.input.blur();
  const found = window.find(f.input.value, false, action === "previous", true);
  f.count.textContent = found ? "" : "Not found";
}

function setUpTranscript() {
  el.transcript.addEventListener("click", onTranscriptClick);
  window.sandshellFind = find;
  ui.jump = actionButton("jump", "↓", "Jump to the Newest");
  ui.jump.hidden = true;
  ui.jump.addEventListener("click", () => scrollToBottom());
  document.body.append(ui.jump);
  el.transcript.addEventListener("scroll", () => { ui.jump.hidden = nearBottom(); }, { passive: true });
}

// ---------- Start ----------

// The window (or phone) changed size: what was at the end stays at the end.
{
  let pinned = true;
  el.transcript.addEventListener("scroll", () => { pinned = nearBottom(); }, { passive: true });
  new ResizeObserver(() => { if (pinned) el.transcript.scrollTop = el.transcript.scrollHeight; }).observe(el.transcript);
}

(async () => {
  if (transcriptOnly) setUpTranscript();
  if (native) { route(); return; }
  // A pairing link (QR code, AirDrop): /pair#<secret>.
  if (location.pathname === "/pair" && location.hash.length > 1) {
    const secret = decodeURIComponent(location.hash.slice(1));
    history.replaceState(null, "", "/pair");   // don't keep the secret in history
    el.pairName.value = deviceName();
    await pair({ secret });
    return;
  }
  if (await checkPaired()) {
    if (location.pathname === "/pair") history.replaceState(null, "", "/");
    route();
  }
})();
