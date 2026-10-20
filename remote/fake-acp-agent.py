#!/usr/bin/env python3
"""A fake ACP agent for Remote Control's checks: no sandbox, no model, no tokens.

Speaks ACP (JSON-RPC 2.0, one message per line) on stdin/stdout like
claude-agent-acp does, and answers each prompt by what it asks for:

  image       a reply with an image in it
  permission  a tool call that asks for permission, then says what was chosen
  question    a form question (elicitation/create), then says the answer
  long        a long reply, streamed a word at a time
  slow        works for 20 seconds unless stopped (session/cancel)
  plan        a plan with three steps
  tool        a tool call with a diff
  markdown    headings, a list, code, a link
  anything    "pong: <what you said>"

Run by Sandshell (DEBUG) for the Remote check session.
"""
import base64
import itertools
import json
import struct
import sys
import threading
import time
import uuid
import zlib

out_lock = threading.Lock()
pending = {}          # our request id -> [threading.Event, response]
pending_lock = threading.Lock()
cancelled = threading.Event()
ids = itertools.count(1)
used_tokens = [1200]


def write(message):
    line = json.dumps(message, separators=(",", ":")) + "\n"
    with out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def respond(rid, result):
    write({"jsonrpc": "2.0", "id": rid, "result": result})


def error(rid, code, message):
    write({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def update(session, body):
    write({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": body}})


def ask(method, params, timeout=600):
    """Send a request to the client and wait for its answer."""
    rid = "fake-%d" % next(ids)
    slot = [threading.Event(), None]
    with pending_lock:
        pending[rid] = slot
    write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    slot[0].wait(timeout)
    with pending_lock:
        pending.pop(rid, None)
    return slot[1]


def say(session, text, message_id=None, pause=0.0):
    mid = message_id or str(uuid.uuid4())
    for chunk in chunks(text):
        if cancelled.is_set():
            return
        update(session, {"sessionUpdate": "agent_message_chunk", "messageId": mid,
                         "content": {"type": "text", "text": chunk}})
        if pause:
            time.sleep(pause)


def chunks(text, size=3):
    words = text.split(" ")
    for i in range(0, len(words), size):
        part = " ".join(words[i:i + size])
        yield part if i + size >= len(words) else part + " "


def png(width=48, height=48):
    """A small PNG: a diagonal gradient, so it's visibly an image."""
    rows = b""
    for y in range(height):
        rows += b"\x00" + b"".join(bytes(((x * 5) % 256, (y * 5) % 256, 180)) for x in range(width))

    def block(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + block(b"IHDR", header) + block(b"IDAT", zlib.compress(rows)) + block(b"IEND", b"")


def usage(session):
    used_tokens[0] += 850
    update(session, {"sessionUpdate": "usage_update", "used": used_tokens[0], "size": 200000,
                     "cost": {"amount": round(used_tokens[0] / 1e6 * 3, 4), "currency": "USD"}})


def prompt_text(params):
    parts = []
    images = 0
    for block in params.get("prompt", []):
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
        elif block.get("type") == "image":
            images += 1
    return " ".join(parts).strip(), images


def run_prompt(rid, params):
    session = params.get("sessionId")
    text, images = prompt_text(params)
    asked = text.lower()
    cancelled.clear()
    try:
        if images:
            say(session, "I got %d image%s." % (images, "" if images == 1 else "s"))
            if not text:
                return finish(rid, session)
        if "permission" in asked:
            call = str(uuid.uuid4())
            update(session, {"sessionUpdate": "tool_call", "toolCallId": call, "title": "`touch remote-check.txt`",
                             "kind": "execute", "status": "pending", "rawInput": {"command": "touch remote-check.txt"}})
            answer = ask("session/request_permission", {
                "sessionId": session,
                "toolCall": {"toolCallId": call, "title": "`touch remote-check.txt`", "kind": "execute"},
                "options": [
                    {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "allow_always", "name": "Always Allow", "kind": "allow_always"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
                ]})
            outcome = ((answer or {}).get("result") or {}).get("outcome") or {}
            chosen = outcome.get("optionId") if outcome.get("outcome") == "selected" else "cancelled"
            allowed = chosen in ("allow_once", "allow_always")
            update(session, {"sessionUpdate": "tool_call_update", "toolCallId": call,
                             "status": "completed" if allowed else "failed",
                             "content": [{"type": "content", "content": {"type": "text",
                                          "text": "created remote-check.txt" if allowed else "not run"}}]})
            say(session, "Permission: %s" % chosen)
        elif "question" in asked:
            answer = ask("elicitation/create", {
                "sessionId": session, "mode": "form", "message": "Which colour should the check use?",
                "requestedSchema": {"type": "object", "required": ["colour"], "properties": {
                    "colour": {"type": "string", "title": "Colour", "enum": ["red", "green", "blue"],
                               "enumNames": ["Red", "Green", "Blue"]}}}})
            result = (answer or {}).get("result") or {}
            picked = (result.get("content") or {}).get("colour")
            say(session, "Answer: %s%s" % (result.get("action", "none"), " " + picked if picked else ""))
        elif "image" in asked:
            say(session, "Here is an image:")
            update(session, {"sessionUpdate": "agent_message_chunk", "messageId": str(uuid.uuid4()),
                             "content": {"type": "image", "mimeType": "image/png",
                                         "data": base64.b64encode(png()).decode()}})
            say(session, "That was the image.")
        elif "long" in asked:
            words = " ".join("word%d" % i for i in range(1, 241))
            say(session, "A long reply: " + words + " — the end.", pause=0.02)
        elif "slow" in asked:
            say(session, "Working slowly…")
            for _ in range(200):
                if cancelled.is_set():
                    break
                time.sleep(0.1)
            if not cancelled.is_set():
                say(session, " Done.")
        elif "plan" in asked:
            update(session, {"sessionUpdate": "plan", "entries": [
                {"content": "Read the request", "status": "completed", "priority": "high"},
                {"content": "Make the change", "status": "in_progress", "priority": "high"},
                {"content": "Check it", "status": "pending", "priority": "medium"}]})
            say(session, "Planned three steps.")
        elif "tool" in asked:
            call = str(uuid.uuid4())
            update(session, {"sessionUpdate": "tool_call", "toolCallId": call, "title": "Edit notes.md",
                             "kind": "edit", "status": "in_progress", "rawInput": {"file_path": "/tmp/notes.md"}})
            time.sleep(0.2)
            update(session, {"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed",
                             "content": [{"type": "diff", "path": "/tmp/notes.md",
                                          "oldText": "Hello\nold line\n", "newText": "Hello\nnew line\nanother\n"}]})
            say(session, "Edited notes.md.")
        elif "markdown" in asked:
            say(session, "# Heading\n\nSome **bold** and `code` and a [link](https://example.com).\n\n"
                         "- one\n- two\n\n```swift\nlet x = 1\n```\n")
        else:
            say(session, "pong: " + (text or "(nothing)"), pause=0.03)
        finish(rid, session)
    except Exception as exc:  # report, don't hang the turn
        error(rid, -32603, "fake agent failed: %s" % exc)


def finish(rid, session):
    usage(session)
    respond(rid, {"stopReason": "cancelled" if cancelled.is_set() else "end_turn"})


MODES = {"availableModes": [{"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan"}],
         "currentModeId": "default"}


def handle(message):
    method = message.get("method")
    rid = message.get("id")
    params = message.get("params") or {}
    if method is None:
        # A response to one of our requests.
        with pending_lock:
            slot = pending.get(rid)
        if slot:
            slot[1] = message
            slot[0].set()
        return
    if rid is None:
        if method == "session/cancel":
            cancelled.set()
        return
    if method == "initialize":
        respond(rid, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}, "authMethods": []})
    elif method == "session/new":
        respond(rid, {"sessionId": str(uuid.uuid4()), "modes": MODES})
    elif method == "session/load":
        respond(rid, {"modes": MODES})
    elif method == "session/set_mode":
        MODES["currentModeId"] = params.get("modeId", "default")
        respond(rid, {})
        update(params.get("sessionId"), {"sessionUpdate": "current_mode_update",
                                         "currentModeId": MODES["currentModeId"]})
    elif method == "session/prompt":
        threading.Thread(target=run_prompt, args=(rid, params), daemon=True).start()
    else:
        error(rid, -32601, "%s is not supported by the fake agent" % method)


def main():
    sys.stderr.write("sandshell-launch: up\n")
    sys.stderr.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            handle(json.loads(line))
        except ValueError:
            sys.stderr.write("fake agent: not JSON: %s\n" % line[:200])
            sys.stderr.flush()


if __name__ == "__main__":
    main()
