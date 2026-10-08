#!/usr/bin/env python3
"""python3 test-safenames.py — checks safenames.py against a real rsync.

Every case builds its own source and destination below a temporary folder and
runs the helper the way the plugin does. The cases with a symlink also keep a
folder outside the destination and check that it comes back untouched.
"""
import errno
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "safenames.py")
failures = 0


def write(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def tree(path):
    """Every entry below `path`, relative, symlinks not followed."""
    found = set()
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            found.add(os.path.relpath(os.path.join(dirpath, name), path))
    return found


def run(root, direction, *args, **kw):
    proc = subprocess.run([sys.executable, HELPER, direction, kw.get("rsync", "rsync")] + list(args),
                          cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode, proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace")


def deletions(out):
    return sorted(line[12:] for line in out.splitlines() if line.startswith("*deleting"))


def victims(root):
    """A folder outside the destination, with names step 4 would delete."""
    os.makedirs(os.path.join(root, "outside", "dir：x"))
    write(os.path.join(root, "outside", "secret：notes.txt"), "victim")
    write(os.path.join(root, "outside", "dir：x", "in.txt"), "victim")
    return {"secret：notes.txt", "dir：x", os.path.join("dir：x", "in.txt")}


def test(name, fn):
    global failures
    root = tempfile.mkdtemp(prefix="safenames-test.")
    try:
        fn(root)
        print("ok   " + name)
    except AssertionError as err:
        failures += 1
        print("FAIL " + name + "\n     " + str(err))
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ---- the destination is never left through a symlink ----

def symlinked_folder_with_keep_dirlinks(root):
    """--keep-dirlinks tells rsync to keep a symlinked folder on the receiver,
    so step 4 meets one without any race."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    os.makedirs(os.path.join(root, "dst"))
    kept = victims(root)
    os.symlink(os.path.join(root, "outside"), os.path.join(root, "dst", "Docs"))
    code, out, err = run(root, "to", "-a", "-K", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert tree(os.path.join(root, "outside")) == kept, "outside the destination: %s" % tree(os.path.join(root, "outside"))
    assert "is not a real folder" in err, "no note about the symlink: %r" % err
    assert code == 23, "exit %d, expected 23" % code


def symlink_planted_during_the_run(root):
    """The destination changes while the job runs: the wrapper puts the symlink
    back after every rsync pass, so it is there when step 4 starts.
    --delete-excluded switches the filter check off, which leaves the directory
    file descriptors as the only thing between step 4 and the files outside."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    os.makedirs(os.path.join(root, "dst"))
    kept = victims(root)
    link, target = os.path.join(root, "dst", "Docs"), os.path.join(root, "outside")
    os.symlink(target, link)
    wrapper = os.path.join(root, "rsync-wrapper")
    write(wrapper, '#!/bin/sh\nrsync "$@"\nstatus=$?\nrm -rf %s\nln -s %s %s\nexit $status\n' % (link, target, link))
    os.chmod(wrapper, 0o755)
    code, out, err = run(root, "to", "-a", "--delete", "--delete-excluded", "--itemize-changes",
                         "--", "src/", "dst/", rsync=wrapper)
    assert tree(target) == kept, "outside the destination: %s" % tree(target)
    assert "is not a real folder" in err, "no note about the symlink: %r" % err
    assert code == 23, "exit %d, expected 23" % code


def destination_root_swapped_during_the_run(root):
    """The destination itself is replaced by a symlink while the job runs: the
    wrapper swaps it once the transfer pass is through, so the folder step 4
    would open is no longer the one the run started in."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    os.makedirs(os.path.join(root, "dst"))
    kept = victims(root)
    dst, target = os.path.join(root, "dst"), os.path.join(root, "outside")
    wrapper = os.path.join(root, "rsync-wrapper")
    write(wrapper, '#!/bin/sh\nrsync "$@"\nstatus=$?\n'
                   'case " $* " in *" --delete "*) rm -rf %s; ln -s %s %s ;; esac\nexit $status\n'
                   % (dst, target, dst))
    os.chmod(wrapper, 0o755)
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/", rsync=wrapper)
    assert tree(target) == kept, "outside the destination: %s" % tree(target)
    assert deletions(out) == [], "deleted although the destination had changed: %s" % deletions(out)
    assert "not the folder this run started in" in err, "no note about the swap: %r" % err
    assert code == 23, "exit %d, expected 23" % code


def a_symlinked_destination_still_works(root):
    """The destination the user picked may well be reached through a symlink.
    It is resolved once, before the job runs, and cleaned like any other."""
    os.makedirs(os.path.join(root, "real"))
    os.symlink(os.path.join(root, "real"), os.path.join(root, "dst"))
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert deletions(out) == ["Docs/gone:dir/", "Docs/gone:dir/in.txt",
                              "Docs/gone:file.txt", "Docs/keep:it.log"], deletions(out)
    assert tree(os.path.join(root, "real")) == {"Docs", os.path.join("Docs", "normal.txt")}, \
        tree(os.path.join(root, "real"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def walk_down_refuses_symlinks(root):
    """The helpers themselves, without rsync."""
    sn = load_helper()
    os.makedirs(os.path.join(root, "base", "real", "deep"))
    os.makedirs(os.path.join(root, "away"))
    write(os.path.join(root, "away", "keep.txt"))
    os.symlink(os.path.join(root, "away"), os.path.join(root, "base", "link"))
    write(os.path.join(root, "base", "file"))
    base_fd = os.open(os.path.join(root, "base"), os.O_RDONLY | os.O_DIRECTORY)
    try:
        fd, why = sn._walk_down(base_fd, "real/deep")
        assert fd is not None, "a real folder was refused: %s" % why
        os.close(fd)
        for rel, what in (("link", "a symlink"), ("link/x", "a folder below a symlink"), ("file", "a file")):
            fd, why = sn._walk_down(base_fd, rel)
            assert fd is None, "%s was opened" % what
            assert why.errno in (errno.ELOOP, errno.ENOTDIR), "%s: errno %s" % (what, why.errno)
        os.mkdir(os.path.join(root, "base", "shut"), 0o300)
        fd, why = sn._walk_down(base_fd, "shut")
        assert fd is None and why.errno == errno.EACCES, "an unreadable folder gave %s" % why
        fd, why = sn._walk_down(base_fd, "nothing/here")
        assert fd is None and why.errno == errno.ENOENT, "a missing folder gave %s" % why
        # a folder listed as a mount point is refused, here without mounting one
        deep = os.path.join(root, "base", "real", "deep")
        fd, why = sn._walk_down(base_fd, "real/deep", {deep})
        assert fd is None and why.errno == errno.EBUSY, "a mount point gave %s" % why
        fd, why = sn._walk_down(base_fd, "real/deep", {os.path.join(root, "elsewhere")})
        assert fd is not None, "an unrelated mount point blocked the way: %s" % why
        os.close(fd)
        assert "/" in sn._mount_points(), "no mount points were read"
        assert tree(os.path.join(root, "away")) == {"keep.txt"}, "the symlink target changed"
        # _remove_at reports deepest first, removes a real tree, refuses a symlink
        seen = []
        sn._remove_at(base_fd, "real", lambda path, is_dir: seen.append(path + ("/" if is_dir else "")), False)
        assert seen == ["real/deep/", "real/"], seen
        assert not os.path.exists(os.path.join(root, "base", "real")), "the folder is still there"
        try:
            sn._remove_at(base_fd, "link", lambda path, is_dir: None, False)
            raise AssertionError("_remove_at followed a symlink")
        except OSError:
            pass
        assert os.path.exists(os.path.join(root, "away", "keep.txt")), "the symlink target was emptied"
        # a dry run reports the same entries and removes none of them
        os.makedirs(os.path.join(root, "base", "keepme", "inner"))
        write(os.path.join(root, "base", "keepme", "inner", "f.txt"))
        seen = []
        sn._remove_at(base_fd, "keepme", lambda path, is_dir: seen.append(path + ("/" if is_dir else "")), True)
        assert seen == ["keepme/inner/f.txt", "keepme/inner/", "keepme/"], seen
        assert os.path.exists(os.path.join(root, "base", "keepme", "inner", "f.txt")), "a dry run removed something"
    finally:
        os.close(base_fd)


def accepted_destination_is_bound_to_its_inode(root):
    """The destination root itself, without rsync: it is opened without
    following one link, and only while it is still the folder it was."""
    sn = load_helper()
    dst, away, other = (os.path.join(root, name) for name in ("dst", "away", "other"))
    for path in (dst, away, other):
        os.makedirs(path)
    accepted = sn._accepted_dst(dst + "/")
    fd, why = sn._open_accepted(accepted)
    assert fd is not None, "the destination was refused: %s" % why
    assert os.fstat(fd).st_ino == os.stat(dst).st_ino, "another folder was opened"
    os.close(fd)
    os.rmdir(dst)
    os.symlink(away, dst)                      # the same path, now a symlink
    fd, why = sn._open_accepted(accepted)
    assert fd is None and why.errno in (errno.ELOOP, errno.ENOTDIR), "a symlinked destination gave %s" % why
    os.unlink(dst)
    os.rename(other, dst)                      # the same path, another real folder
    fd, why = sn._open_accepted(accepted)
    assert fd is None and why.errno == errno.ESTALE, "a swapped destination gave %s" % why
    # a destination rsync still has to create: opened once it is there
    os.rmdir(dst)
    accepted = sn._accepted_dst(dst)
    assert accepted[2] == ["dst"], "the missing part is %s" % (accepted[2],)
    fd, why = sn._open_accepted(accepted)
    assert fd is None and why.errno == errno.ENOENT, "a missing destination gave %s" % why
    os.symlink(away, dst)
    fd, why = sn._open_accepted(accepted)
    assert fd is None and why.errno in (errno.ELOOP, errno.ENOTDIR), "a symlink in its place gave %s" % why
    os.unlink(dst)
    os.makedirs(dst)
    fd, why = sn._open_accepted(accepted)
    assert fd is not None, "the folder rsync created was refused: %s" % why
    os.close(fd)
    assert tree(away) == set(), "the symlink target changed"


def load_helper():
    import importlib.util
    spec = importlib.util.spec_from_file_location("safenames", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---- step 4 deletes what rsync would delete, and only that ----

def leftovers(root, extra=""):
    """A destination with three renamed entries whose source is gone."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Docs", "gone：file.txt"), "old")
    write(os.path.join(root, "dst", "Docs", "gone：dir", "in.txt"), "old")
    write(os.path.join(root, "dst", "Docs", "keep：it.log"), "old")
    write(os.path.join(root, "dst", "Docs", "normal.txt"))


def orphans_are_deleted(root):
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    # rsync reports one line per entry, deepest first
    assert deletions(out) == ["Docs/gone:dir/", "Docs/gone:dir/in.txt",
                              "Docs/gone:file.txt", "Docs/keep:it.log"], deletions(out)
    assert tree(os.path.join(root, "dst")) == {"Docs", os.path.join("Docs", "normal.txt")}, tree(os.path.join(root, "dst"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def a_destination_without_a_slash_is_cleaned_too(root):
    """A job may write its destination with or without a trailing slash. rsync
    prints the listing step 4 compares against below the path only for the
    first and below its parent for the second, so the pass has to ask for the
    form it reads. It kept every left-over otherwise."""
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst")
    assert deletions(out) == ["Docs/gone:dir/", "Docs/gone:dir/in.txt",
                              "Docs/gone:file.txt", "Docs/keep:it.log"], deletions(out)
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def excluded_names_survive(root):
    """rsync keeps what the filters exclude, even when the source is gone."""
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--exclude=*.log", "--itemize-changes", "--", "src/", "dst/")
    assert deletions(out) == ["Docs/gone:dir/", "Docs/gone:dir/in.txt", "Docs/gone:file.txt"], deletions(out)
    assert os.path.exists(os.path.join(root, "dst", "Docs", "keep：it.log")), "the excluded file was deleted"
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def delete_excluded_removes_them(root):
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--delete-excluded", "--exclude=*.log",
                         "--itemize-changes", "--", "src/", "dst/")
    assert "Docs/keep:it.log" in deletions(out), deletions(out)
    assert not os.path.exists(os.path.join(root, "dst", "Docs", "keep：it.log")), "the excluded file survived"


def protect_rules_stop_the_pass(root):
    """Protect rules cannot be read here, so nothing is deleted at all."""
    leftovers(root)
    before = tree(os.path.join(root, "dst"))
    code, out, err = run(root, "to", "-a", "--delete", "--filter=protect keep*", "--itemize-changes",
                         "--", "src/", "dst/")
    assert deletions(out) == [], deletions(out)
    assert tree(os.path.join(root, "dst")) == before, "something was deleted"
    assert "protect files on the destination" in err, "no note: %r" % err
    assert code == 23, "exit %d, expected 23" % code


def source_without_a_slash_and_an_unsafe_root(root):
    write(os.path.join(root, "src", "pro:ject", "normal.txt"))
    write(os.path.join(root, "dst", "pro：ject", "gone：x.txt"), "old")
    write(os.path.join(root, "dst", "pro：ject", "keep：y.log"), "old")
    code, out, err = run(root, "to", "-a", "--delete", "--exclude=*.log", "--itemize-changes",
                         "--", "src/pro:ject", "dst")
    assert deletions(out) == ["pro:ject/gone:x.txt"], deletions(out)
    assert os.path.exists(os.path.join(root, "dst", "pro：ject", "keep：y.log")), "the excluded file was deleted"
    assert os.path.exists(os.path.join(root, "dst", "pro：ject", "normal.txt")), "the job did not copy"


def restoring_from_a_drive(root):
    """Direction "from": the destination holds the real names again."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Docs", "gone:x.txt"), "old")
    write(os.path.join(root, "dst", "Docs", "keep:y.log"), "old")
    code, out, err = run(root, "from", "-a", "--delete", "--exclude=*.log", "--itemize-changes",
                         "--", "src/", "dst/")
    assert deletions(out) == ["Docs/gone：x.txt"], deletions(out)
    assert os.path.exists(os.path.join(root, "dst", "Docs", "keep:y.log")), "the excluded file was deleted"


def a_dry_run_only_reports(root):
    for opts in (["-a", "--delete", "--dry-run", "--itemize-changes"], ["-avn", "--delete"]):
        shutil.rmtree(os.path.join(root, "dst"), ignore_errors=True)
        shutil.rmtree(os.path.join(root, "src"), ignore_errors=True)
        leftovers(root)
        code, out, err = run(root, "to", *(opts + ["--", "src/", "dst/"]))
        assert "Docs/gone:file.txt" in deletions(out), "%s: %s" % (opts, deletions(out))
        assert os.path.exists(os.path.join(root, "dst", "Docs", "gone：file.txt")), "%s deleted for real" % opts


def max_delete_is_honoured(root):
    leftovers(root)
    code, out, err = run(root, "to", "-a", "--delete", "--max-delete=1", "--itemize-changes", "--", "src/", "dst/")
    assert len(deletions(out)) == 1, deletions(out)
    assert "--max-delete=1 reached" in err, err
    assert code == 25, "exit %d, expected 25" % code


def without_recursion_it_stays_at_the_top(root):
    """rsync deletes "only for the directories that are being synchronized":
    with --dirs that is the transfer root, not the folders below it."""
    write(os.path.join(root, "src", "Docs", "keep.txt"))
    write(os.path.join(root, "dst", "Docs", "extra：x.txt"), "old")
    write(os.path.join(root, "dst", "extra：top.txt"), "old")
    code, out, err = run(root, "to", "--dirs", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert deletions(out) == ["extra:top.txt"], deletions(out)
    assert os.path.exists(os.path.join(root, "dst", "Docs", "extra：x.txt")), "deleted below a folder rsync does not sync"


def max_delete_counts_a_whole_folder(root):
    """Every entry of a removed folder counts, the way rsync counts them."""
    write(os.path.join(root, "src", "Docs", "keep.txt"))
    write(os.path.join(root, "dst", "Docs", "keep.txt"))
    for name in ("one.txt", "two.txt", "three.txt"):
        write(os.path.join(root, "dst", "Docs", "gone：dir", name), "old")
    code, out, err = run(root, "to", "-a", "--delete", "--max-delete=2", "--itemize-changes", "--", "src/", "dst/")
    left = tree(os.path.join(root, "dst", "Docs", "gone：dir"))
    assert 3 - len(left) == 2, "removed %d entries, the budget was 2: %s" % (3 - len(left), left)
    assert "--max-delete=2 reached" in err, err
    assert code == 25, "exit %d, expected 25" % code


def an_unreadable_folder_is_reported(root):
    """rsync makes a destination folder readable again on every pass, so this
    can only happen while the job runs: the wrapper takes the permission away
    after the last rsync call. The pass must say so instead of skipping it."""
    if os.geteuid() == 0:
        return                                 # root reads it anyway
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Docs", "gone：x.txt"), "old")
    write(os.path.join(root, "dst", "Docs", "normal.txt"))
    shut = os.path.join(root, "dst", "Docs")
    wrapper = os.path.join(root, "rsync-wrapper")
    write(wrapper, '#!/bin/sh\nrsync "$@"\nstatus=$?\nchmod 300 %s\nexit $status\n' % shut)
    os.chmod(wrapper, 0o755)
    try:
        code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/", rsync=wrapper)
    finally:
        os.chmod(shut, 0o755)
    assert "are kept" in err, "nothing was reported: %r" % err
    assert deletions(out) == [], "deleted although the folder could not be read: %s" % deletions(out)
    assert code == 23, "exit %d, expected 23" % code


def folder_times_are_restored(root):
    """Pass 3 writes into a folder after pass 2 set its time; without the last
    pass the next run would report .d..t on it."""
    write(os.path.join(root, "src", "Docs", "a:b.txt"))
    os.makedirs(os.path.join(root, "dst"))
    os.utime(os.path.join(root, "src", "Docs"), (1000000000, 1000000000))
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert os.path.exists(os.path.join(root, "dst", "Docs", "a：b.txt")), "the renamed file is missing"
    got = os.stat(os.path.join(root, "dst", "Docs"), follow_symlinks=False).st_mtime
    assert int(got) == 1000000000, "folder time is %d" % got


# ---- a folder the source no longer has goes as a whole ----

def gone(root):
    """The source keeps Docs, the destination still has Archive from an earlier
    run: renamed files at several depths, a renamed folder, a renamed file
    inside that one, and plain files next to them."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Archive", "2019", "Drafts", "Report -＞ Final.pdf"), "old")
    write(os.path.join(root, "dst", "Archive", "2019", "Drafts", "plain.pdf"), "old")
    write(os.path.join(root, "dst", "Archive", "Old", "Notes 2019：2020", "photo.jpg"), "old")
    write(os.path.join(root, "dst", "Archive", "Old", "Notes 2019：2020", "inner：x.jpg"), "old")


def a_folder_gone_from_the_source_goes_as_a_whole(root):
    """The protect rules kept the renamed files from rsync's --delete, and
    step 4 only walks folders the source still has: they stayed, with every
    folder above them, and rsync said "cannot delete non-empty directory" on
    every run, so the job never finished."""
    gone(root)
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert "cannot delete" not in out, [l for l in out.splitlines() if "cannot delete" in l]
    assert tree(os.path.join(root, "dst")) == {"Docs", os.path.join("Docs", "normal.txt")}, \
        tree(os.path.join(root, "dst"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def a_dry_run_says_so_too(root):
    gone(root)
    before = tree(os.path.join(root, "dst"))
    code, out, err = run(root, "to", "-a", "--delete", "--dry-run", "--itemize-changes", "--", "src/", "dst/")
    assert "cannot delete" not in out, [l for l in out.splitlines() if "cannot delete" in l]
    for path in ("Archive/", "Archive/2019/Drafts/Report -＞ Final.pdf", "Archive/Old/Notes 2019：2020/inner：x.jpg"):
        assert path in deletions(out), "%s missing from %s" % (path, deletions(out))
    assert tree(os.path.join(root, "dst")) == before, "a dry run removed something"
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def what_the_job_excludes_still_holds_a_gone_folder(root):
    """Only the protection safe names adds is lifted: a file the job's own
    filters exclude keeps its folder, the way rsync always does."""
    gone(root)
    write(os.path.join(root, "dst", "Archive", "2019", "Drafts", "notes.log"), "old")
    code, out, err = run(root, "to", "-a", "--delete", "--exclude=*.log", "--itemize-changes", "--", "src/", "dst/")
    assert os.path.exists(os.path.join(root, "dst", "Archive", "2019", "Drafts", "notes.log")), "the excluded file was deleted"
    assert not os.path.exists(os.path.join(root, "dst", "Archive", "2019", "Drafts", "Report -＞ Final.pdf")), \
        "the renamed file next to it stayed"
    assert not os.path.exists(os.path.join(root, "dst", "Archive", "Old")), "a folder without excluded files stayed"
    assert "cannot delete non-empty directory: Archive/2019/Drafts" in out, out


def risked_junk_goes_with_a_gone_folder(root):
    """Easy's "Skip system junk files" lets the destination lose .DS_Store and
    ._* files ("risk" in front of "exclude"). The AppleDouble file of a renamed
    file has a renamed name itself, and the protect rule used to win."""
    gone(root)
    write(os.path.join(root, "dst", "Archive", "2019", "Drafts", "._Report -＞ Final.pdf"), "old")
    write(os.path.join(root, "dst", "Archive", "2019", "Drafts", ".DS_Store"), "old")
    code, out, err = run(root, "to", "-a", "--delete", "--filter=risk ._*", "--filter=risk .DS_Store",
                         "--exclude=._*", "--exclude=.DS_Store", "--itemize-changes", "--", "src/", "dst/")
    assert tree(os.path.join(root, "dst")) == {"Docs", os.path.join("Docs", "normal.txt")}, \
        tree(os.path.join(root, "dst"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def a_gone_folder_inside_a_renamed_folder(root):
    """Pass 3 syncs a renamed folder on its own, with the same rules."""
    write(os.path.join(root, "src", "Docs", "pro:ject", "keep.txt"))
    write(os.path.join(root, "dst", "Docs", "pro：ject", "keep.txt"))
    write(os.path.join(root, "dst", "Docs", "pro：ject", "old", "x：y.txt"), "old")
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert "cannot delete" not in out, [l for l in out.splitlines() if "cannot delete" in l]
    assert tree(os.path.join(root, "dst")) == {"Docs", os.path.join("Docs", "pro：ject"),
                                               os.path.join("Docs", "pro：ject", "keep.txt")}, \
        tree(os.path.join(root, "dst"))


def restoring_removes_a_gone_folder_too(root):
    """Direction "from": the real names are the protected ones."""
    write(os.path.join(root, "src", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Docs", "normal.txt"))
    write(os.path.join(root, "dst", "Old", "a:b.txt"), "old")
    code, out, err = run(root, "from", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert tree(os.path.join(root, "dst")) == {"Docs", os.path.join("Docs", "normal.txt")}, \
        tree(os.path.join(root, "dst"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def renamed_files_of_the_source_stay(root):
    """The protection itself still holds where the source has the folder:
    a second run neither deletes nor copies the renamed file again."""
    write(os.path.join(root, "src", "Docs", "a:b.txt"))
    os.makedirs(os.path.join(root, "dst"))
    run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert deletions(out) == [], deletions(out)
    assert not [l for l in out.splitlines() if l.startswith(">f")], out
    assert os.path.exists(os.path.join(root, "dst", "Docs", "a：b.txt")), "the renamed file is gone"
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


def trailing_dots_and_spaces_are_still_renamed(root):
    """The rules changed their spelling ("--filter=-p" for "--exclude="): a
    name the drive cannot store must still reach it only under its new name."""
    write(os.path.join(root, "src", "Docs", "end "))
    write(os.path.join(root, "src", "Docs", "end."))
    write(os.path.join(root, "src", "Docs", "a:b"))
    os.makedirs(os.path.join(root, "dst"))
    code, out, err = run(root, "to", "-a", "--delete", "--itemize-changes", "--", "src/", "dst/")
    assert tree(os.path.join(root, "dst", "Docs")) == {"end␠", "end．", "a：b"}, tree(os.path.join(root, "dst", "Docs"))
    assert code == 0, "exit %d, expected 0: %s" % (code, err)


for case in (symlinked_folder_with_keep_dirlinks, symlink_planted_during_the_run,
             destination_root_swapped_during_the_run, a_symlinked_destination_still_works,
             walk_down_refuses_symlinks, accepted_destination_is_bound_to_its_inode,
             orphans_are_deleted, a_destination_without_a_slash_is_cleaned_too,
             excluded_names_survive, delete_excluded_removes_them, protect_rules_stop_the_pass,
             source_without_a_slash_and_an_unsafe_root, restoring_from_a_drive, a_dry_run_only_reports,
             max_delete_is_honoured, without_recursion_it_stays_at_the_top,
             max_delete_counts_a_whole_folder, an_unreadable_folder_is_reported, folder_times_are_restored,
             a_folder_gone_from_the_source_goes_as_a_whole, a_dry_run_says_so_too,
             what_the_job_excludes_still_holds_a_gone_folder, risked_junk_goes_with_a_gone_folder,
             a_gone_folder_inside_a_renamed_folder, restoring_removes_a_gone_folder_too,
             renamed_files_of_the_source_stay, trailing_dots_and_spaces_are_still_renamed):
    test(case.__name__.replace("_", " "), case)

if failures:
    print("%d failed" % failures)
    sys.exit(1)
print("all passed")
