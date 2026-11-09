#!/usr/bin/env bash
# Remove the sandbox-kit-assembled:* image tags no sandbox uses. sbx builds one
# set per kit combination and never removes them.
#
#   scripts/prune-kit-images.sh [--dry-run]
#
# In use means the .image of some sandbox in `sbx ls --json` (stopped ones too),
# by `sbx inspect NAME --json`. For an in-use <hash>, keeps <hash>, <hash>-kit-N
# and <hash>-template. Removes by tag, never by image ID: tags share IDs.
#
# If `sbx ls`, any inspect or the tag listing fails, or says something this
# can't read, it stops and removes nothing: a missing answer must never make an
# image look unused. Every other repository is left alone.
#
# For scripts/run-self-tests.sh:
#   --snapshot FILE       write the current tags to FILE, nothing else
#   --new-since FILE      only tags that aren't in FILE
#   --registry DIR        with --new-since: other live runs' snapshots (DIR/<pid>.tags).
#                         A tag must be in each of them, or it may be that run's.
#   --self PID            with --registry: this run's own snapshot, to skip
exec python3 - "$@" <<'PY'
import json, os, re, subprocess, sys

REPO = "sandbox-kit-assembled"
FORMS = (REPO, "library/" + REPO, "docker.io/" + REPO, "docker.io/library/" + REPO)
TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


class Abort(Exception):
    pass


def sbx(*args):
    try:
        done = subprocess.run(("sbx",) + args, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Abort(f"sbx {' '.join(args)}: {error}")
    if done.returncode != 0:
        raise Abort(f"sbx {' '.join(args)} failed ({done.returncode}): {done.stderr.strip()[:300]}")
    return done.stdout


def progress(text):
    print(text, file=sys.stderr, flush=True)


def parse_json(text, what):
    try:
        return json.loads(text)
    except ValueError:
        raise Abort(f"{what} isn't JSON")


def parse_tags(listing):
    """{tag: reference to remove it by}, from `sbx template ls --json`."""
    images = parse_json(listing, "`sbx template ls --json`")
    if not isinstance(images, list):
        raise Abort("`sbx template ls --json` isn't a list")
    tags = {}
    for image in images:
        repository = image.get("repository") if isinstance(image, dict) else None
        tag = image.get("tag") if isinstance(image, dict) else None
        if not isinstance(repository, str) or not isinstance(tag, str):
            raise Abort(f"can't read this image: {image!r:.200}")
        if repository in FORMS:
            if tag in ("", "<none>"):
                continue
            if not TAG.match(tag):
                raise Abort(f"can't read this tag: {tag!r:.200}")
            tags[tag] = f"{REPO}:{tag}"
        elif repository.endswith("/" + REPO):
            # Ours under a prefix this doesn't know, or someone else's: don't guess.
            raise Abort(f"unknown repository {repository}: check it, then add it to FORMS if it's sbx's")
    return tags


def base(tag):
    return re.sub(r"-(kit-\d+|template)$", "", tag)


def hashes_in_use():
    progress("listing sandboxes (sbx ls)")
    boxes = parse_json(sbx("ls", "--json"), "`sbx ls --json`")
    if isinstance(boxes, dict):
        boxes = boxes.get("sandboxes")
    if not isinstance(boxes, list):
        raise Abort("`sbx ls --json` isn't a list of sandboxes")
    used = set()
    pattern = re.compile(r"^(?:docker\.io/library/|docker\.io/|library/)?" + REPO + r"(?::([^@]+))?(@.*)?$")
    for count, box in enumerate(boxes, 1):
        name = box.get("name") if isinstance(box, dict) else None
        if not isinstance(name, str) or not name:
            raise Abort(f"a sandbox in `sbx ls --json` has no name: {box!r:.200}")
        progress(f"inspecting {count}/{len(boxes)}: {name}")
        info = parse_json(sbx("inspect", name, "--json"), f"`sbx inspect {name} --json`")
        if isinstance(info, list) and len(info) == 1:
            info = info[0]
        image = info.get("image") if isinstance(info, dict) else None
        if not isinstance(image, str) or not image:
            raise Abort(f"`sbx inspect {name} --json` has no .image")
        match = pattern.match(image)
        if match:
            if not match.group(1):
                raise Abort(f"{name}'s image has no tag to match: {image}")
            used.add(base(match.group(1)))
    return used


def read_tags(path):
    try:
        with open(path) as file:
            return {line.strip() for line in file if line.strip()}
    except OSError as error:
        raise Abort(f"can't read {path}: {error}")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def main():
    args = sys.argv[1:]
    dry = snapshot = since = registry = own = None
    while args:
        arg = args.pop(0)
        if arg == "--dry-run":
            dry = True
        elif arg in ("--snapshot", "--new-since", "--registry", "--self"):
            if not args:
                print(f"{arg} needs a value", file=sys.stderr)
                return 64
            value = args.pop(0)
            if arg == "--snapshot":
                snapshot = value
            elif arg == "--new-since":
                since = value
            elif arg == "--registry":
                registry = value
            else:
                own = value
        else:
            print(f"unknown option {arg}", file=sys.stderr)
            return 64

    # Tags first, then what's in use: a sandbox made in between is still seen.
    progress("listing kit images (sbx template ls --json)")
    tags = parse_tags(sbx("template", "ls", "--json"))
    if snapshot:
        partial = f"{snapshot}.{os.getpid()}"
        with open(partial, "w") as file:
            file.write("".join(tag + "\n" for tag in sorted(tags)))
        os.replace(partial, snapshot)
        return 0

    candidates = set(tags)
    if since:
        candidates -= read_tags(since)
        if registry:
            for entry in sorted(os.listdir(registry)):
                if not entry.endswith(".tags") or entry == f"{own}.tags" or not entry[:-5].isdigit():
                    continue
                if alive(int(entry[:-5])):
                    candidates &= read_tags(os.path.join(registry, entry))

    used = hashes_in_use()
    remove = sorted(tag for tag in candidates if base(tag) not in used)
    kept = len(candidates) - len(remove)
    failed = 0
    for tag in remove:
        if dry:
            print(f"would remove {tags[tag]}")
            continue
        try:
            sbx("template", "rm", "--force", tags[tag])
            print(f"removed {tags[tag]}")
        except Abort as error:
            failed += 1
            print(f"couldn't remove {tags[tag]}: {error}", file=sys.stderr)
    verb = "would remove" if dry else "removed"
    print(f"{REPO}: {len(tags)} tags, {verb} {len(remove) - failed}, kept {kept} in use"
          + (f", {len(tags) - len(candidates)} out of scope" if since else "")
          + (f", {failed} failed" if failed else ""))
    return 1 if failed else 0


try:
    sys.exit(main())
except Abort as error:
    print(f"prune-kit-images: {error}. Nothing removed.", file=sys.stderr)
    sys.exit(2)
PY
