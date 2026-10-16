#!/usr/bin/env python3
"""Fixtures for scripts/run-self-tests.sh: each self-test scenario's workspace,
made or reset so a run never depends on what an earlier one left behind.

    selftest_fixtures.py <root> prepare <fixture>     make/reset a fixture dir
    selftest_fixtures.py <root> config <fixture>      apply its config.json edits (after the app made one)
    selftest_fixtures.py <root> rm-sandboxes <fixture> remove sbx sandboxes for that folder
    selftest_fixtures.py <root> kitdirs               print the kits scenario's five kit dirs

Everything lives under <root> (a /tmp folder): the app only does destructive
things for scratch workspaces there.
"""
import json, os, shutil, subprocess, sys, uuid
from datetime import datetime, timedelta, timezone

ZEBRA = "11111111-1111-4111-8111-111111111111"   # SelfTest.zebraID

def sh(*args, cwd=None, check=True):
    return subprocess.run(args, cwd=cwd, check=check, capture_output=True, text=True).stdout

def git_repo(d, files, commits):
    """Fresh repo at d: `commits` is a list of (message, {path: text}) applied in order."""
    if os.path.isdir(os.path.join(d, ".git")):
        sh("git", "-C", d, "reset", "-q", "--hard")
        sh("git", "-C", d, "clean", "-qfdx", "-e", ".sandshell")
        sh("git", "-C", d, "checkout", "-q", files.get("__branch__", "main"))
        return
    os.makedirs(d, exist_ok=True)
    sh("git", "init", "-q", "-b", "main", cwd=d)
    for msg, content in commits:
        for path, text in content.items():
            p = os.path.join(d, path)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(text)
        sh("git", "add", "-A", cwd=d)
        sh("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg, cwd=d)
    if "__branch__" in files:
        sh("git", "checkout", "-qb", files["__branch__"], cwd=d)

def edit(d, path, old, new):
    p = os.path.join(d, path)
    s = open(p).read()
    assert old in s, (path, old)
    open(p, "w").write(s.replace(old, new, 1))

def state_path(d):
    return os.path.join(d, ".sandshell", "state.json")

def set_sessions(d, specs):
    """Replace the workspace's sessions with `specs` (most recent first):
    dicts with agent, name, and optionally chat / transcript."""
    os.makedirs(os.path.join(d, ".sandshell"), exist_ok=True)
    p = state_path(d)
    state = json.load(open(p)) if os.path.exists(p) else {}
    folders = state.get("folders") or [{"id": str(uuid.uuid4()).upper(), "order": -1, "relativePath": ""}]
    root = next(f for f in folders if f.get("relativePath", "") == "")
    real = os.path.realpath(d)
    now = datetime.now(timezone.utc)
    sessions = []
    for i, spec in enumerate(specs):
        s = {"id": str(uuid.uuid4()).upper(), "folderID": root["id"], "agent": spec["agent"],
             "name": spec["name"], "order": i, "workdir": real,
             "createdAt": (now - timedelta(minutes=i + 1)).strftime("%Y-%m-%dT%H:%M:%SZ")}
        if spec.get("chat"): s["isChat"] = True
        if spec.get("transcript"): s["transcriptID"] = spec["transcript"]
        sessions.append(s)
    state.update({"folders": folders, "sessions": sessions})
    state.setdefault("schemaVersion", 1)
    state.setdefault("expandedFolderIDs", [])
    json.dump(state, open(p, "w"), indent=2)

README = """# Scratch Notes

Sandshell keeps these notes to check the Markdown preview: prose in the
document face, headings larger, code monospaced.

## Section

- a list
- of things

```python
def hello():
    print("world")
```
"""
APP = "".join(f"def f{i}():\n    return {i}\n" for i in range(20))

FIXTURES = {}

def fixture(name):
    def wrap(fn):
        FIXTURES[name] = fn
        return fn
    return wrap

@fixture("files")
def _files(d):
    # A repo with two commits, src/app.py changed in two places, two shells.
    git_repo(d, {}, [("init", {"README.md": README, "src/app.py": APP}),
                      ("ignore", {".gitignore": ".DS_Store\n.sandshell/\n"})])
    edit(d, "src/app.py", "    return 0\n", '    return "CHANGED-HEAD"\n')
    edit(d, "src/app.py", "    return 19\n", '    return "CHANGED-TAIL"\n')
    set_sessions(d, [{"agent": "shell", "name": "Shell A"}, {"agent": "shell", "name": "Shell B"}])

@fixture("title-strip-workspace")
def _title(d):
    git_repo(d, {"__branch__": "feature/readout-squeeze"}, [("init", {"README.md": README})])
    set_sessions(d, [{"agent": "shell", "name": "Shell A"}])

@fixture("chat")
def _chat(d):
    # Chats make their own sessions; a repo so Files and links have something.
    git_repo(d, {}, [("init", {"README.md": README, "src/app.py": APP})])
    set_sessions(d, [])

@fixture("search")
def _search(d):
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [{"agent": "claude", "name": "Zebra chat", "chat": True, "transcript": ZEBRA},
                     {"agent": "shell", "name": "deploy notes"},
                     {"agent": "shell", "name": "alpha build"}])

@fixture("kits")
def _kits(d):
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [])

@fixture("kitagents")
def _kitagents(d):
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [])

@fixture("agents")
def _agents(d):
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [])

@fixture("fresh")
def _fresh(d):
    # A folder whose sandboxes don't exist yet (the runner removes them).
    shutil.rmtree(d, ignore_errors=True)
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [{"agent": "shell", "name": "Shell A"}])

@fixture("broken")
def _broken(d):
    git_repo(d, {}, [("init", {"README.md": README})])
    set_sessions(d, [{"agent": "shell", "name": "Shell A"}])

# config.json edits, applied once the app has written the file.
CONFIGS = {
    "kits": lambda root: {"kits": [os.path.join(root, "kitdirs", "a")], "sandshellKits": []},
    "kitagents": lambda root: {"kits": ["docker.io/sbx/code-server-kit:latest"], "sandshellKits": []},
    "broken": lambda root: {"kits": [os.path.join(root, "kitdirs", "does-not-exist")], "sandshellKits": []},
}

def kitdirs(root):
    """Five tiny mixin kits for the kits scenario; d declares `files` (which
    `sbx kit add` refuses, forcing a rebuild)."""
    out = []
    for k in "abcde":
        d = os.path.join(root, "kitdirs", k)
        os.makedirs(d, exist_ok=True)
        spec = (f'schemaVersion: "2"\nkind: mixin\nname: selftest-{k}\ndisplayName: Self-test {k.upper()}\n'
                f'description: Self-test mixin {k}.\nenvironment:\n  variables:\n    SELFTEST_{k.upper()}: "1"\n')
        if k == "d":
            os.makedirs(os.path.join(d, "files", "home"), exist_ok=True)
            open(os.path.join(d, "files", "home", "selftest-d.txt"), "w").write("d\n")
        open(os.path.join(d, "spec.yaml"), "w").write(spec)
        out.append(d)
    agent = os.path.join(root, "kitdirs", "agent")
    os.makedirs(agent, exist_ok=True)
    open(os.path.join(agent, "spec.yaml"), "w").write(
        'schemaVersion: "2"\nkind: sandbox\nname: agents-probe\ndisplayName: Agents Probe\n'
        'description: Throwaway kind:sandbox kit for the agents scenario.\n'
        'sandbox:\n  image: docker/sandbox-templates:shell-docker\n  entrypoint:\n    - bash\n')
    return out

def rm_sandboxes(d):
    real = os.path.realpath(d)
    try:
        boxes = json.loads(sh("sbx", "ls", "--json", check=False) or "[]")
    except json.JSONDecodeError:
        return
    if isinstance(boxes, dict): boxes = boxes.get("sandboxes", [])
    for b in boxes:
        spaces = [w.split(":")[0] for w in (b.get("workspaces") or [])]
        if any(os.path.realpath(w) == real for w in spaces):
            sh("sbx", "rm", "--force", b["name"], check=False)
            print(f"removed sandbox {b['name']}")

def main():
    root, cmd = sys.argv[1], sys.argv[2]
    os.makedirs(root, exist_ok=True)
    if cmd == "kitdirs":
        print("\n".join(kitdirs(root)))
        return
    name = sys.argv[3]
    d = os.path.join(root, name)
    if cmd == "prepare":
        FIXTURES[name](d)
        print(d)
    elif cmd == "config":
        p = os.path.join(d, ".sandshell", "config.json")
        if name in CONFIGS and os.path.exists(p):
            c = json.load(open(p))
            c.update(CONFIGS[name](root))
            json.dump(c, open(p, "w"), indent=2)
    elif cmd == "rm-sandboxes":
        rm_sandboxes(d)

if __name__ == "__main__":
    main()
