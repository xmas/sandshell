#!/usr/bin/env python3
"""Build and test from inside a sandbox, through the Mac's Xcode.

The sandbox is Linux, with no Swift. The user registers Xcode's MCP bridge once
(`sbx mcp add xcode --command xcrun --args mcpbridge`) and loads it into the
sandbox (`sbx mcp load xcode --sandbox <name>`); sbx's gateway then carries it
here. A chat doesn't get these as tools (docs/extensions.md), so this speaks
MCP to the gateway itself, through the sandbox's proxy.

  scripts/xcode-sandbox.py build                build app and tests; errors listed
  scripts/xcode-sandbox.py test                 build, then every test
  scripts/xcode-sandbox.py test FooTests ...    build, then these suites or tests
  scripts/xcode-sandbox.py log [warning]        the last build's issues
  scripts/xcode-sandbox.py tools                what Xcode offers
  scripts/xcode-sandbox.py call Tool '{json}'   any tool

Exits non-zero unless the build succeeded and the tests really passed. Never
trust a quiet answer: a build returns an empty response, and a first test run
after one can too, so results come from the build log and a run's own summary.

It drives the user's real Xcode, which must have Sandshell.xcodeproj open. A
new source file needs `xcodegen generate` on the Mac first.
"""
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

GATEWAY = "http://mcp-gateway.docker.internal/"  # resolves only through the proxy
PROJECT = "Sandshell.xcodeproj"
TARGET = "SandshellTests"
SESSION_FILE = Path("/tmp/sandshell-xcode-session")
TIMEOUT = 570


def post(body, session=None, timeout=TIMEOUT):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "Authorization": "Bearer proxy-managed"}
    if session:
        headers["Mcp-Session-Id"] = session
    request = urllib.request.Request(GATEWAY, json.dumps(body).encode(), headers)
    with urllib.request.build_opener().open(request, timeout=timeout) as response:
        new_session = response.headers.get("Mcp-Session-Id")
        text = response.read().decode()
    messages = []
    for line in text.splitlines():
        if line.startswith("data:"):
            try:
                messages.append(json.loads(line[5:]))
            except ValueError:
                pass
    if not messages and text.strip():
        try:
            messages = [json.loads(text)]
        except ValueError:
            pass
    return new_session, messages


def connect():
    session, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "sandshell-sandbox", "version": "1"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session)
    # The gateway offers its own tools until a server is added to the session.
    post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": {"name": "mcp-add", "arguments": {"name": "xcode"}}}, session)
    SESSION_FILE.write_text(session)
    return session


def rpc(method, params):
    """One request; gateway sessions don't last, so a stale one is replaced."""
    body = {"jsonrpc": "2.0", "id": 7, "method": method, "params": params}
    session = SESSION_FILE.read_text().strip() if SESSION_FILE.exists() else connect()
    try:
        return post(body, session)[1]
    except urllib.error.HTTPError as error:
        if error.code not in (400, 404):
            raise
    return post(body, connect())[1]


def call(tool, arguments=None):
    """A tool's text, or "" for an empty response."""
    messages = rpc("tools/call", {"name": tool, "arguments": arguments or {}})
    if not messages:
        return ""
    result = messages[-1].get("result", messages[-1])
    content = result.get("content") if isinstance(result, dict) else None
    return "\n".join(item.get("text", "") for item in content) if content else json.dumps(messages[-1])


def workspace():
    for line in call("XcodeListWorkspaces").splitlines():
        if PROJECT in line and "workspaceIdentifier: " in line:
            return line.split("workspaceIdentifier: ")[1].split(",")[0]
    sys.exit(f"Xcode doesn't have {PROJECT} open.")


def issues(ws, severity="error"):
    """Print the build log's issues, once each; whether the build succeeded."""
    log = json.loads(call("GetBuildLog", {"workspaceIdentifier": ws, "severity": severity}))
    seen = set()
    for entry in log.get("buildLogEntries", []):
        for issue in entry.get("emittedIssues", []):
            key = (issue.get("path"), issue.get("line"), issue.get("message"))
            if key not in seen:
                seen.add(key)
                print(f"  {Path(issue.get('path') or '?').name}:{issue.get('line')}: {issue.get('message')}")
    print(log.get("buildResult"))
    return "succeeded" in (log.get("buildResult") or "") and not log.get("buildIsRunning")


def build(ws):
    call("BuildProject", {"workspaceIdentifier": ws, "buildForTesting": True})
    return issues(ws)


def test(ws, names):
    arguments = {"workspaceIdentifier": ws}
    tool = "RunAllTests"
    if names:
        tool = "RunSomeTests"
        arguments["tests"] = [{"targetName": TARGET, "testIdentifier": name} for name in names]
    run = {}
    for _ in range(2):  # the first run after a build can answer with nothing
        try:
            run = json.loads(call(tool, arguments) or "{}")
        except ValueError:
            run = {}
        if run.get("summary"):
            break
    if not run.get("summary"):
        print(f"No test result: {json.dumps(run)[:400]}")
        return False
    print(run["summary"])
    for result in run.get("results", []):
        if result.get("state") not in ("Passed", "Skipped"):
            print(f"  {result.get('state')} {result.get('identifier')}: " + " | ".join(result.get("errorMessages") or [])[:400])
    counts = run.get("counts", {})
    return counts.get("failed", 1) == 0 and counts.get("passed", 0) > 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "help"
    if command == "tools":
        for tool in rpc("tools/list", {})[-1]["result"]["tools"]:
            print(tool["name"])
    elif command == "call":
        print(call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}))
    elif command == "log":
        issues(workspace(), sys.argv[2] if len(sys.argv) > 2 else "error")
    elif command == "build":
        return 0 if build(workspace()) else 1
    elif command == "test":
        ws = workspace()
        return 0 if build(ws) and test(ws, sys.argv[2:]) else 1
    else:
        print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
