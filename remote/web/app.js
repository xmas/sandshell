// Sandshell Remote Control — the web client a phone, PC or another Mac loads
// from the Mac. One event stream (/api/events) brings the session list and,
// for the open chat, its state then patches; commands are POSTs.
"use strict";

const $ = (id) => document.getElementById(id);
const el = {
  app: $("app"), listPane: $("list-pane"), chatPane: $("chat-pane"), checkPane: $("check-pane"), placeholder: $("placeholder"),
  host: $("host"), conn: $("conn"), sessions: $("sessions"), empty: $("empty"),
  back: $("back"), title: $("chat-title"), sub: $("chat-sub"), mode: $("mode"),
  transcript: $("transcript"), cards: $("cards"), composer: $("composer"), input: $("input"),
  send: $("send"), file: $("file"), attachments: $("attachments"), status: $("status"),
  checkBack: $("check-back"), checkRun: $("check-run"), checkResults: $("check-results"),
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

function open(id) {
  if (state.stream) state.stream.close();
  state.current = id;
  resetTranscript();
  const url = "/api/events" + (id ? "?session=" + encodeURIComponent(id) : "");
  const stream = new EventSource(url);
  state.stream = stream;
  setConn("connecting");
  stream.onopen = () => setConn("on");
  stream.onerror = () => setConn(stream.readyState === EventSource.CLOSED ? "off" : "connecting");
  for (const name of ["hello", "sessions", "state", "patch", "gone"]) {
    stream.addEventListener(name, (e) => {
      const data = JSON.parse(e.data);
      handle(name, data);
      for (const listen of state.listeners) listen(name, data);
    });
  }
}

function setConn(how) {
  el.conn.className = "conn " + (how === "on" ? "on" : how === "off" ? "off" : "");
  el.conn.title = how === "on" ? "Connected" : how === "off" ? "Disconnected" : "Connecting…";
}

function handle(name, data) {
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
      state.omitted = data.omitted;
      for (const item of data.items) { state.items.set(item.id, item); state.order.push(item.id); }
      state.status = data.status;
      renderAll(true);
      break;
    case "patch":
      if (data.session !== state.current) return;
      applyPatch(data);
      break;
    case "gone":
      if (data.session === state.current) {
        state.status = { ...(state.status || {}), phase: "closed", closedReason: "Remote Control is off for this chat on the Mac, or it closed." };
        renderStatus();
      }
      break;
  }
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
    for (const id of [...state.items.keys()]) if (!p.order.includes(id)) { state.items.delete(id); state.nodes.get(id)?.remove(); state.nodes.delete(id); }
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
  const div = document.createElement("div");
  div.className = "item " + item.kind;
  div.dataset.id = item.id;
  switch (item.kind) {
    case "user": {
      const bubble = document.createElement("div");
      bubble.className = "bubble";
      bubble.textContent = item.text || "";
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

function blocks(text) {
  const lines = text.split("\n");
  const html = [];
  let para = [], list = null, quote = [], table = [];
  const flushPara = () => { if (para.length) { html.push("<p>" + inline(para.join("<br>")) + "</p>"); para = []; } };
  const flushList = () => { if (list) { html.push(`<${list.tag}>` + list.items.map((x) => "<li>" + inline(x) + "</li>").join("") + `</${list.tag}>`); list = null; } };
  const flushQuote = () => { if (quote.length) { html.push("<blockquote>" + inline(quote.join("<br>")) + "</blockquote>"); quote = []; } };
  const flushTable = () => {
    if (!table.length) return;
    const rows = table.filter((r) => !/^\|?\s*:?-{2,}/.test(r)).map((r) => r.replace(/^\||\|$/g, "").split("|").map((c) => inline(c.trim())));
    html.push('<div class="table-wrap"><table>' + rows.map((r, i) => "<tr>" + r.map((c) => (i ? "<td>" : "<th>") + c + (i ? "</td>" : "</th>")).join("") + "</tr>").join("") + "</table></div>");
    table = [];
  };
  const flushAll = () => { flushPara(); flushList(); flushQuote(); flushTable(); };
  for (const line of lines) {
    let m;
    if (!line.trim()) { flushAll(); continue; }
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { flushAll(); const n = Math.min(m[1].length + 1, 4); html.push(`<h${n}>` + inline(m[2]) + `</h${n}>`); continue; }
    if (/^\s*\|.*\|\s*$/.test(line)) { flushPara(); flushList(); flushQuote(); table.push(line.trim()); continue; }
    flushTable();
    if ((m = line.match(/^\s*[-*+]\s+(.*)$/))) { flushPara(); flushQuote(); if (!list || list.tag !== "ul") { flushList(); list = { tag: "ul", items: [] }; } list.items.push(m[1]); continue; }
    if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) { flushPara(); flushQuote(); if (!list || list.tag !== "ol") { flushList(); list = { tag: "ol", items: [] }; } list.items.push(m[1]); continue; }
    if ((m = line.match(/^&gt;\s?(.*)$/))) { flushPara(); flushList(); quote.push(m[1]); continue; }
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
  for (const file of el.file.files) {
    try { state.pending.push(await shrink(file)); } catch (err) { flash("Couldn’t read " + file.name); }
  }
  el.file.value = "";
  renderAttachments();
  renderStatus();
});

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
      resolve({ name: file.name || "Photo", mimeType: type, data: dataURL.split(",")[1], url: dataURL });
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

// ---------- Start ----------

route();
