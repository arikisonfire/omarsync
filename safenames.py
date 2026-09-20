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
     That pass walks DST through directory file descriptors opened with
     O_NOFOLLOW, so it never enters a symlink below DST, and it leaves alone
     what the job's filters exclude, the way rsync's own --delete does.
Output keeps rsync's format, with paths as in SRC, so the plugin can parse it.
Exit code: the most serious rsync exit code of all passes.
"""
import errno
import os
import re
import stat
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
# Filter rules that can only hide or exclude. Every other rule (P/protect,
# merge, dir-merge) can protect files on the receiver from rsync's --delete;
# step 4 cannot read rsync's rules, so it then deletes nothing at all.
PLAIN_FILTER_RE = re.compile(r"^--filter=\s*(exclude|include|hide|show|risk|clear|[-+HSR!])[a-zA-Z,/!]*(\s|$)")
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


def real_opts(opts):
    """The options themselves, without the values of -e, -B, -f, -T, -M, -@."""
    value_next = False
    for o in opts:
        if value_next:
            value_next = False
            continue
        yield o
        if SHORT_CLUSTER_RE.match(o):
            for i, c in enumerate(o[1:], 1):
                if c in SHORT_WITH_VALUE:
                    value_next = i == len(o) - 1    # "-e" "ssh": the value is the next argument
                    break


def short_flags(opts):
    """Every letter of every cluster of short options (-vn -> "v", "n")."""
    for o in real_opts(opts):
        if not SHORT_CLUSTER_RE.match(o):
            continue
        for c in o[1:]:
            yield c
            if c in SHORT_WITH_VALUE:
                break                              # "-essh": the rest is the value


def is_dry_run(opts):
    """--dry-run, or -n anywhere in a cluster of short options (-vn, -an):
    step 4 deletes on its own, so it must not miss a dry run rsync obeys."""
    return "--dry-run" in real_opts(opts) or "n" in short_flags(opts)


def has_protect_rules(opts):
    """Whether a rule that protects files on the receiver may be in play.
    Rules can also come from a file (merge, dir-merge, -F), which is why every
    rule that is not plainly an exclude or include counts."""
    if "f" in short_flags(opts) or "F" in short_flags(opts):
        return True
    return any(o == "--filter" or (o.startswith("--filter=") and not PLAIN_FILTER_RE.match(o))
               for o in real_opts(opts))


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

    def unmapped(rel):
        return "/".join(unrename(p) for p in rel.split("/"))

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

    # Passes 3 and 4 changed directories after pass 2 set their times: put the
    # source times back, deepest first, or the next run "updates" them again.
    keep_times = any(o in ("--archive", "--times") or re.match(r"^-[a-zA-Z]*[at]", o) for o in opts) \
        and not any(o in ("--no-times", "--no-t", "--omit-dir-times") or re.match(r"^-[a-zA-Z]*O", o) for o in opts)

    # Step 4 and the times below are the only passes that walk DST themselves
    # instead of leaving it to rsync, so they open every folder under DST with
    # O_NOFOLLOW (_walk_down). rsync replaces a symlinked directory on the
    # receiver with a real one; following one here would delete or touch files
    # outside the destination the run was confirmed for.
    base_fd = None
    mounts = set()
    if deleting or (keep_times and not dry):
        mounts = _mount_points()                 # read once, not per folder
        try:
            base_fd = os.open(dst_base, os.O_RDONLY | os.O_DIRECTORY)
        except OSError:
            pass                                 # a dry run: nothing is there yet

    # 4. renamed entries whose source is gone
    limit_hit = False
    listed = None            # dst paths the job's filters still show, None: all
    if deleting and base_fd is not None and has_protect_rules(opts):
        note("the job has filter rules that can protect files on the destination: "
             "renamed leftovers there are kept")
        codes.append(23)
        deleting = False
    if deleting and base_fd is not None and "--delete-excluded" not in real_opts(opts):
        # rsync keeps what the filters exclude ("files that are excluded from
        # the transfer are also excluded from being deleted"), so DST is listed
        # the way SRC was in step 1: a name missing from that listing is
        # excluded and has to survive this pass.
        root = dst if src.endswith("/") else os.path.join(dst, mapped(os.path.basename(src.rstrip("/"))))
        if not os.path.lexists(root):
            listed = set()                       # nothing has been written there yet
        else:
            # -r last, so it wins over the job's own recursion flags: step 4
            # reaches every folder in `entry_dirs`, and a name it can reach but
            # the listing did not show would look excluded and survive.
            shown = subprocess.run([rsync[0], "--list-only", "-8"] + [o for o in opts if FILTER_RE.match(o)]
                                   + ["-r", "--", root], stdout=subprocess.PIPE)
            if shown.returncode != 0:
                note("could not list the destination (rsync exit %d): renamed leftovers are kept"
                     % shown.returncode)
                codes.append(23)
                deleting = False
            else:
                listed = set()
                for raw in shown.stdout.split(b"\n"):
                    m = LIST_RE.match(raw)
                    if not m:
                        continue
                    kind, there = m.group(1), unescape(m.group(2))
                    if kind == b"l":
                        there = there.split(b" -> ", 1)[0]
                    listed.add(fs(there))
    # rsync deletes "only for the directories that are being synchronized":
    # without recursion that is the transfer root alone, so neither may this.
    recursive = any(o in ("--recursive", "--archive") or re.match(r"^-[a-zA-Z]*[ra]", o) for o in real_opts(opts)) \
        and not any(o in ("--no-recursive", "--no-r") for o in real_opts(opts))

    if deleting and base_fd is not None:
        dirs = [""] + (sorted(entry_dirs) if recursive else [])
        for rel in dirs:
            if limit_hit:
                break
            if rel and any(unsafe(p) and p in collisions for p in _prefixes(rel)):
                continue
            if not src.endswith("/") and rel == "":
                continue        # DST itself holds more than this job's folder
            here = os.path.join(dst_base, mapped(rel)) if rel else dst_base
            here_fd, why = _walk_down(base_fd, mapped(rel) if rel else "", mounts)
            if here_fd is None:
                if why.errno in (errno.ELOOP, errno.ENOTDIR):
                    note("“%s” is not a real folder on the destination: renamed leftovers in it are kept" % here)
                    codes.append(23)
                elif why.errno == errno.EBUSY:
                    # the same rule the plugin applies before the run starts
                    note("a drive is mounted inside “%s”: renamed leftovers there are kept" % here)
                    codes.append(23)
                elif why.errno != errno.ENOENT:
                    note("cannot open “%s” on the destination (%s): renamed leftovers in it are kept"
                         % (here, why.strerror or why))
                    codes.append(23)
                continue
            try:
                names = os.listdir(here_fd)
            except OSError as err:
                os.close(here_fd)
                note("cannot read “%s” on the destination (%s): renamed leftovers in it are kept"
                     % (here, err.strerror or err))
                codes.append(23)
                continue
            def report(shown, shown_dir, rel=rel):
                """rsync prints one line per deleted entry, deepest first, and
                counts each of them against --max-delete. `rel` is bound here,
                so the folder of this round is the one the paths are built on."""
                global deleted
                if max_delete is not None and deleted >= max_delete:
                    raise _DeleteLimit()
                deleted += 1
                touched.add(rel)
                out(b"*deleting   " + os.fsencode(os.path.join(rel, unmapped(shown)))
                    + (b"/" if shown_dir else b"") + b"\n")

            try:
                expected = {rename(n) for n in by_dir.get(rel, [])}
                for name in sorted(names):
                    original = unrename(name)
                    if original == name or name in expected:
                        continue
                    if listed is not None and os.path.join(mapped(rel), name) not in listed:
                        continue    # the filters exclude it, so rsync would keep it too
                    if os.path.lexists(os.path.join(src_base, rel, original)):
                        continue    # excluded from the job, not deleted (like rsync)
                    try:
                        is_dir = stat.S_ISDIR(os.lstat(name, dir_fd=here_fd).st_mode)
                    except OSError:
                        continue    # gone since the listing
                    try:
                        if is_dir:
                            _remove_at(here_fd, name, report, dry)
                        else:
                            report(name, False)
                            if not dry:
                                os.unlink(name, dir_fd=here_fd)
                    except _DeleteLimit:
                        # rsync stops deleting at --max-delete and exits 25; its
                        # own deletions from step 2 already count in `deleted`.
                        note("--max-delete=%d reached: renamed leftovers on the destination are kept" % max_delete)
                        codes.append(25)
                        limit_hit = True
                        break
                    except (OSError, RecursionError) as err:
                        note("cannot delete %s: %s" % (os.path.join(here, name), getattr(err, "strerror", None) or err))
                        codes.append(23)
            finally:
                os.close(here_fd)

    if keep_times and not dry and base_fd is not None:
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
            except OSError:
                continue
            if not rel:
                try:
                    os.utime(base_fd, ns=(st.st_atime_ns, st.st_mtime_ns))
                except OSError:
                    pass
                continue
            parent, name = os.path.split(mapped(rel))
            parent_fd, _why = _walk_down(base_fd, parent, mounts)
            if parent_fd is None:
                continue
            try:
                os.utime(name, ns=(st.st_atime_ns, st.st_mtime_ns), dir_fd=parent_fd, follow_symlinks=False)
            except OSError:
                pass
            finally:
                os.close(parent_fd)

    if base_fd is not None:
        os.close(base_fd)
    return worst(codes)


def _prefixes(rel):
    parts = rel.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]


def _parents_below(inner, top):
    """Path components of `inner` below `top` (each as a full rel path)."""
    return [p for p in _prefixes(inner) if len(p) > len(top)]


def _mount_points():
    """Every mount point of this system, from /proc/self/mountinfo."""
    points = set()
    try:
        with open("/proc/self/mountinfo", "rb") as table:
            for line in table:
                fields = line.split(b" ")
                if len(fields) > 4:
                    point = fields[4]
                    for code, char in ((b"\\040", b" "), (b"\\011", b"\t"), (b"\\012", b"\n"), (b"\\134", b"\\")):
                        point = point.replace(code, char)
                    points.add(fs(point))
    except OSError:
        pass                                       # no /proc: the check is skipped
    return points


def _walk_down(base_fd, rel, mounts=None):
    """(fd, None) for `rel` below base_fd, or (None, error). Nothing under
    base_fd is followed: every part is opened with O_DIRECTORY|O_NOFOLLOW, so a
    symlink fails with ELOOP and anything else than a folder with ENOTDIR.
    With `mounts`, a part that is a mount point of its own fails with EBUSY:
    a drive that appeared inside the destination is not this job's to empty."""
    fd = os.dup(base_fd)
    try:
        for part in rel.split("/") if rel else []:
            if part in ("", ".", ".."):
                raise OSError(errno.EINVAL, "a path component leads out of the destination")
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)                           # only once os.open has succeeded
            fd = nxt
            if mounts and _fd_path(fd) in mounts:
                raise OSError(errno.EBUSY, "a drive is mounted here")
    except OSError as err:
        os.close(fd)
        return None, err
    return fd, None


def _fd_path(fd):
    """The path an open directory currently has, or None."""
    try:
        return os.readlink("/proc/self/fd/%d" % fd)
    except OSError:
        return None


class _DeleteLimit(Exception):
    """--max-delete ran out in the middle of a folder."""


def _remove_at(dir_fd, name, report, dry):
    """Removes `name` below dir_fd deepest first, never following a symlink.
    `report(path, is_dir)` sees every entry before it goes and may raise to
    stop at --max-delete; with `dry` nothing is removed."""
    sub = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
    try:
        for child in sorted(os.listdir(sub)):
            if stat.S_ISDIR(os.lstat(child, dir_fd=sub).st_mode):
                _remove_at(sub, child, lambda inner, d: report(os.path.join(name, inner), d), dry)
            else:
                report(os.path.join(name, child), False)
                if not dry:
                    os.unlink(child, dir_fd=sub)
    finally:
        os.close(sub)
    report(name, True)
    if not dry:
        os.rmdir(name, dir_fd=dir_fd)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(20)
