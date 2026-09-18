#!/usr/bin/env python3
"""Run an rsync job with names made safe for FAT/exFAT/NTFS.

usage: safenames.py to|from rsync [OPTIONS...] -- SRC DST

"to":   names in SRC that such file systems can't store are written to DST
        with look-alike characters (a:b -> a：b, "end." -> "end．").
"from": the reverse, for copying such a backup back.

The mapping is fixed, so the next run finds the renamed files under the same
names and rsync's normal size/time check skips unchanged ones.

How a run works:
  1. rsync lists SRC with the job's filters (so excluded files stay excluded).
  2. The job's own rsync runs with every unsafe name excluded and every renamed
     name protected from --delete.
  3. Each unsafe entry runs as its own rsync pass to its renamed path
     (directories recursively, again without their unsafe children).
  4. With deleting on, renamed entries on DST whose source is gone are removed.
Output keeps rsync's format, with paths as in SRC, so the plugin can parse it.
Exit code: the most serious rsync exit code of all passes.
"""
import os
import re
import shutil
import subprocess
import sys

UNSAFE = ':?<>"*|\\'
LOOKALIKE = "：？＜＞＂＊｜＼"
TO_SAFE = {ord(a): b for a, b in zip(UNSAFE, LOOKALIKE)}
TO_SAFE.update({c: chr(0x2400 + c) for c in range(1, 32)})          # control chars -> ␁..␟
TO_UNIX = {ord(b): a for a, b in zip(UNSAFE, LOOKALIKE)}
TO_UNIX.update({0x2400 + c: chr(c) for c in range(1, 32)})
TRAIL_SAFE = {".": "．", " ": "␠"}   # trailing dots are dropped by FAT/exFAT
TRAIL_UNIX = {v: k for k, v in TRAIL_SAFE.items()}

DELETE_RE = re.compile(r"^--(del|delete|delete-(before|during|delay|after|excluded))(=|$)")
FILTER_RE = re.compile(r"^(--(exclude|include|filter|exclude-from|include-from|cvs-exclude|from0|one-file-system|"
                       r"recursive|no-recursive|no-r|archive|dirs)(=|$)|-[FCxrad]+$)")
LIST_RE = re.compile(rb"^(\S)\S{9}\s+[\d,.]+\s+\d{4}/\d\d/\d\d \d\d:\d\d:\d\d (.*)$")
ITEM_RE = re.compile(rb"^([<>ch.*][fdLDS]\S{9} )(.*)$")
DELETING_RE = re.compile(rb"^(\*deleting\s+)(.*)$")
MAX_DELETE_RE = re.compile(r"^--max-delete=(\d+)$")
SHORT_CLUSTER_RE = re.compile(r"^-[A-Za-z0-9@]+$")
SHORT_WITH_VALUE = "eBfTM@"      # -e CMD, -B SIZE, -f RULE, -T DIR, -M OPT, -@ NUM
SEVERITY_OK = (0, 23, 24, 25)

deleted = 0      # deletions so far, rsync's own ones included, for --max-delete


def _trail(name, table):
    stripped = name.rstrip("".join(table))
    return stripped + "".join(table[c] for c in name[len(stripped):])


def to_safe(name):
    return _trail(name.translate(TO_SAFE), TRAIL_SAFE)


def to_unix(name):
    return _trail(name, TRAIL_UNIX).translate(TO_UNIX)


def rules(direction):
    """(exclude, protect) rsync arguments for one direction."""
    ascii_patterns = ["*[%s]*" % c for c in UNSAFE] + ["*[\x01-\x1f]*", "*.", "* "]
    look_patterns = ["*%s*" % c for c in LOOKALIKE] + ["*%s*" % chr(0x2400 + c) for c in range(1, 32)] + ["*．", "*␠"]
    unsafe, renamed = (ascii_patterns, look_patterns) if direction == "to" else (look_patterns, ascii_patterns)
    return ["--exclude=" + p for p in unsafe], ["--filter=P " + p for p in renamed]


def out(line):
    sys.stdout.buffer.write(line)
    sys.stdout.buffer.flush()


def note(text):
    sys.stderr.write("safe names: %s\n" % text)
    sys.stderr.flush()


def fs(b):
    return os.fsdecode(b)


def unescape(raw):
    # rsync prints unprintable bytes as \#ooo
    return re.sub(rb"\\#([0-7]{3})", lambda m: bytes([int(m.group(1), 8)]), raw)


def run(argv, prefix=None, rename=None):
    """Runs rsync, passing its output through; itemized paths get `prefix`
    (a directory pass) or become `rename` (a single file pass). Deletions rsync
    reports are counted, so step 4 can carry on where --max-delete left off."""
    global deleted
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE)
    buf = b""
    while True:
        chunk = proc.stdout.read1(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            m = re.search(rb"[\r\n]", buf)
            if not m:
                break
            line, sep, buf = buf[:m.start()], buf[m.start():m.end()], buf[m.end():]
            if DELETING_RE.match(line):
                deleted += 1
            out(rewrite(line, prefix, rename) + sep)
    if buf:
        if DELETING_RE.match(buf):
            deleted += 1
        out(rewrite(buf, prefix, rename))
    return proc.wait()


def rewrite(line, prefix, rename):
    if prefix is None and rename is None:
        return line
    m = ITEM_RE.match(line) or DELETING_RE.match(line)
    if not m:
        return line
    path = m.group(2)
    if rename is not None:
        path = rename
    elif path in (b"./", b"."):
        path = prefix + b"/"
    else:
        path = prefix + b"/" + path
    return m.group(1) + path


def is_dry_run(opts):
    """--dry-run, or -n anywhere in a cluster of short options (-vn, -an):
    step 4 deletes on its own, so it must not miss a dry run rsync obeys."""
    value_next = False
    for o in opts:
        if value_next:
            value_next = False
            continue
        if o == "--dry-run":
            return True
        if SHORT_CLUSTER_RE.match(o):
            for i, c in enumerate(o[1:], 1):
                if c == "n":
                    return True
                if c in SHORT_WITH_VALUE:
                    value_next = i == len(o) - 1    # "-e" "ssh": the value is the next argument
                    break
    return False


def worst(codes):
    bad = [c for c in codes if c not in SEVERITY_OK]
    if bad:
        return bad[0]
    for c in (23, 24, 25):
        if c in codes:
            return c
    return 0


def main():
    global deleted
    if len(sys.argv) < 4 or sys.argv[1] not in ("to", "from") or "--" not in sys.argv:
        note("usage: safenames.py to|from rsync [OPTIONS...] -- SRC DST")
        return 1
    direction = sys.argv[1]
    rsync = sys.argv[2:]
    sep = rsync.index("--")
    opts, paths = rsync[1:sep], rsync[sep + 1:]
    if len(paths) != 2:
        note("needs exactly one source and one destination")
        return 1
    src, dst = paths
    rename = to_safe if direction == "to" else to_unix
    unrename = to_unix if direction == "to" else to_safe
    dry = is_dry_run(opts)
    deleting = any(DELETE_RE.match(o) for o in opts)
    max_delete = next((int(m.group(1)) for m in map(MAX_DELETE_RE.match, opts) if m), None)
    exclude, protect = rules(direction)

    # 1. what the job transfers, with its own filters
    listing = subprocess.run([rsync[0], "--list-only", "-8"] + [o for o in opts if FILTER_RE.match(o)] + ["--", src],
                             stdout=subprocess.PIPE)
    if listing.returncode not in SEVERITY_OK:
        note("could not list the source (rsync exit %d)" % listing.returncode)
        return listing.returncode
    entries = []                                   # (rel path, is dir), parents first
    for raw in listing.stdout.split(b"\n"):
        m = LIST_RE.match(raw)
        if not m:
            continue
        kind, rel = m.group(1), unescape(m.group(2))
        if kind == b"l":
            rel = rel.split(b" -> ", 1)[0]
        rel = fs(rel)
        if rel != ".":
            entries.append((rel, kind == b"d"))
    src_base = src if src.endswith("/") else (os.path.dirname(src.rstrip("/")) or ".")
    dst_base = dst

    def mapped(rel):
        return "/".join(rename(p) for p in rel.split("/"))

    # names that would land on the same file
    by_dir = {}
    for rel, _ in entries:
        parent, name = os.path.split(rel)
        by_dir.setdefault(parent, []).append(name)
    collisions = set()
    for parent, names in by_dir.items():
        seen, folded = {}, {}
        for name in names:
            target = rename(name)
            if target in seen and seen[target] != name:
                note("“%s” and “%s” in “%s” get the same name: “%s” is skipped, rename one of them"
                     % (seen[target], name, parent or ".", name if name != target else seen[target]))
                collisions.add(os.path.join(parent, name if name != target else seen[target]))
            seen.setdefault(target, name)
            low = target.casefold()
            if direction == "to" and low in folded and folded[low] != target:
                note("“%s” and “%s” in “%s” differ only in case: on FAT/exFAT one overwrites the other"
                     % (folded[low], target, parent or "."))
            folded.setdefault(low, target)

    # Copied back, "．" and "．．" become "." and "..": the pass for such an
    # entry would write into, and with --delete empty, the destination itself
    # or the folder above it. A drive can hold such names, so they are skipped.
    refused = False
    for rel, _ in entries:
        if any(p in (".", "..") for p in mapped(rel).split("/")) \
                and not any(rel == c or rel.startswith(c + "/") for c in collisions):
            note("“%s” would become “%s”, which leads out of its folder: skipped" % (rel, mapped(rel)))
            collisions.add(rel)
            refused = True

    def unsafe(rel):
        return rename(os.path.basename(rel)) != os.path.basename(rel)

    def skipped(rel):
        return rel in collisions or any(rel.startswith(c + "/") for c in collisions)

    codes = [23] if refused else []
    # 2. the job itself, unsafe names left out, renamed ones protected
    code = run([rsync[0]] + exclude + protect + opts + ["--", src, dst])
    codes.append(code)
    if code not in SEVERITY_OK:
        return code

    sub_opts = [o for o in opts if o not in ("--stats", "--info=progress2")]
    file_opts = [o for o in sub_opts if not DELETE_RE.match(o)]
    entry_dirs = {rel for rel, is_dir in entries if is_dir}

    # 3. one pass per unsafe entry
    for rel, is_dir in entries:
        if not unsafe(rel) or skipped(rel):
            continue
        source = os.path.join(src_base, rel)
        target = os.path.join(dst_base, mapped(rel))
        shown = os.fsencode(rel)
        if dry and not os.path.isdir(os.path.dirname(target)):
            # the parent only exists after a real run: report what would happen
            out((b"cd+++++++++ " + shown + b"/\n") if is_dir else (b">f+++++++++ " + shown + b"\n"))
            if is_dir:
                for inner, inner_dir in entries:
                    if inner.startswith(rel + "/") and not any(unsafe(p) for p in _parents_below(inner, rel)):
                        out((b"cd+++++++++ " if inner_dir else b">f+++++++++ ") + os.fsencode(inner) + (b"/\n" if inner_dir else b"\n"))
            continue
        if is_dir:
            code = run([rsync[0]] + exclude + protect + sub_opts + ["--", source + "/", target + "/"], prefix=shown)
        else:
            code = run([rsync[0]] + file_opts + ["--", source, target], rename=shown)
        codes.append(code)
        if code not in SEVERITY_OK:
            return worst(codes)

    touched = set()          # dst dirs whose times need restoring

    # 4. renamed entries whose source is gone
    limit_hit = False
    if deleting:
        dirs = [""] + sorted(entry_dirs)
        for rel in dirs:
            if limit_hit:
                break
            if rel and any(unsafe(p) and p in collisions for p in _prefixes(rel)):
                continue
            here = os.path.join(dst_base, mapped(rel)) if rel else dst_base
            if not src.endswith("/") and rel == "":
                continue        # DST itself holds more than this job's folder
            try:
                names = os.listdir(here)
            except OSError:
                continue
            expected = {rename(n) for n in by_dir.get(rel, [])}
            for name in names:
                original = unrename(name)
                if original == name or name in expected:
                    continue
                if os.path.lexists(os.path.join(src_base, rel, original)):
                    continue    # excluded from the job, not deleted (like rsync)
                # rsync stops deleting at --max-delete and exits 25; its own
                # deletions from step 2 are already counted in `deleted`.
                if max_delete is not None and deleted >= max_delete:
                    note("--max-delete=%d reached: renamed leftovers on the destination are kept" % max_delete)
                    codes.append(25)
                    limit_hit = True
                    break
                deleted += 1
                path = os.path.join(here, name)
                is_dir = os.path.isdir(path) and not os.path.islink(path)
                touched.add(rel)
                out(b"*deleting   " + os.fsencode(os.path.join(rel, original)) + (b"/" if is_dir else b"") + b"\n")
                if dry:
                    continue
                try:
                    if is_dir:
                        shutil.rmtree(path)
                    else:
                        os.unlink(path)
                except OSError as err:
                    note("cannot delete %s: %s" % (path, err.strerror))
                    codes.append(23)

    # Passes 3 and 4 changed directories after pass 2 set their times: put the
    # source times back, deepest first, or the next run "updates" them again.
    keep_times = any(o in ("--archive", "--times") or re.match(r"^-[a-zA-Z]*[at]", o) for o in opts) \
        and not any(o in ("--no-times", "--no-t", "--omit-dir-times") or re.match(r"^-[a-zA-Z]*O", o) for o in opts)
    if keep_times and not dry:
        for rel, _ in entries:
            if unsafe(rel) and not skipped(rel):
                parent = os.path.dirname(rel)
                while True:
                    touched.add(parent)
                    if not parent:
                        break
                    parent = os.path.dirname(parent)
        for rel in sorted(touched, key=lambda r: -r.count("/") - (1 if r else 0)):
            if rel == "" and not src.endswith("/"):
                continue
            try:
                st = os.stat(os.path.join(src_base, rel) if rel else src)
                os.utime(os.path.join(dst_base, mapped(rel)) if rel else dst_base, ns=(st.st_atime_ns, st.st_mtime_ns))
            except OSError:
                pass

    return worst(codes)


def _prefixes(rel):
    parts = rel.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]


def _parents_below(inner, top):
    """Path components of `inner` below `top` (each as a full rel path)."""
    return [p for p in _prefixes(inner) if len(p) > len(top)]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(20)
