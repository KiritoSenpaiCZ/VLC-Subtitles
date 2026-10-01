#!/usr/bin/env python3
"""
Keeps the code that several addons share in one place.

Each shared piece of code lives in dev/shared/<name>.<ext>. Inside every
addon file that uses it, the copy sits between two marker comments:

    -- >>> shared block "<name>" ...      (Lua)     # >>> shared block "<name>" ...  (Python)
    ...copy...
    -- <<< shared block "<name>"                    # <<< shared block "<name>"

Run from anywhere:
    python dev/sync.py          copy every shared block into the addon files
    python dev/sync.py --check  only report addon files whose copy differs

targets.json (next to this script) lists, per block, the addon files that
use it (paths relative to the folder that holds all the repos), plus
optional "copy_to" pairs: files copied as-is after syncing (LF endings).
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))  # the folder holding all repos

def comment_prefix(path):
    return "#" if path.endswith(".py") else "--"

def read_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    crlf = b"\r\n" in raw
    return raw.decode("utf-8").replace("\r\n", "\n"), crlf

def write_text(path, text, crlf):
    data = text.replace("\n", "\r\n") if crlf else text
    with open(path, "wb") as f:
        f.write(data.encode("utf-8"))

def block_pattern(prefix, name):
    p = re.escape(prefix)
    return re.compile(
        r"(?m)^(?P<indent>[ \t]*)" + p + r" >>> shared block \"" + re.escape(name) + r"\"[^\n]*\n"
        r"(?P<body>.*?)"
        r"^[ \t]*" + p + r" <<< shared block \"" + re.escape(name) + r"\"[ \t]*$",
        re.S)

def main():
    check_only = "--check" in sys.argv
    with open(os.path.join(HERE, "targets.json"), encoding="utf-8") as f:
        config = json.load(f)
    repo = os.path.basename(os.path.dirname(HERE))
    problems, changed = 0, set()
    for name, targets in config["blocks"].items():
        src = [f for f in os.listdir(os.path.join(HERE, "shared")) if os.path.splitext(f)[0] == name]
        if len(src) != 1:
            print("ERROR: dev/shared/%s.* not found (or found twice)" % name); problems += 1; continue
        shared, _ = read_text(os.path.join(HERE, "shared", src[0]))
        shared = shared.rstrip("\n") + "\n"
        for rel in targets:
            path = os.path.join(ROOT, rel)
            text, crlf = read_text(path)
            prefix = comment_prefix(path)
            matches = list(block_pattern(prefix, name).finditer(text))
            if len(matches) != 1:
                print("ERROR: %s: expected one shared block \"%s\", found %d" % (rel, name, len(matches)))
                problems += 1
                continue
            m = matches[0]
            if m.group("body") == shared:
                continue
            if check_only:
                print("DIFFERS: %s (block \"%s\")" % (rel, name)); problems += 1
                continue
            header = '%s >>> shared block "%s" - edit dev/shared/%s in %s, then run dev/sync.py\n' % (prefix, name, src[0], repo)
            footer = '%s <<< shared block "%s"' % (prefix, name)
            text = text[:m.start()] + header + shared + footer + text[m.end():]
            write_text(path, text, crlf)
            changed.add(rel)
            print("updated: %s (block \"%s\")" % (rel, name))
    copied = 0
    if not check_only:
        for src_rel, dst_rel in config.get("copy_to", []):
            text, _ = read_text(os.path.join(ROOT, src_rel))
            dst = os.path.join(ROOT, dst_rel)
            old = read_text(dst)[0] if os.path.exists(dst) else None
            if old != text:
                write_text(dst, text, False)
                copied += 1
                print("copied: %s -> %s" % (src_rel, dst_rel))
    if problems:
        print("%d problem(s)" % problems); sys.exit(1)
    if check_only:
        print("all shared blocks in sync")
    else:
        print("done: %d file(s) updated, %d copied" % (len(changed), copied))

if __name__ == "__main__":
    main()
