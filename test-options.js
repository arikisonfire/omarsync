// node test-options.js — checks Options.js without the shell
const fs = require("fs")
const vm = require("vm")
const assert = require("assert")

const src = fs.readFileSync(__dirname + "/Options.js", "utf8").replace(/^\.pragma library/m, "")
const O = {}
vm.createContext(O)
vm.runInContext(src, O)

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) }
  catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}
const job = (opts, extra) => Object.assign({ src: "/a/", dst: "/b", opts: opts || {}, filters: [], extra: "" }, extra || {})

test("catalog keys are unique and complete", () => {
  const keys = new Set()
  for (const d of O.CATALOG) {
    assert(!keys.has(d.key), "duplicate " + d.key)
    keys.add(d.key)
    assert(O.GROUPS.some(g => g.id === d.group), "bad group " + d.group)
    assert(d.label && d.hint, "missing text " + d.key)
  }
})

test("archive preset and implied --no- flags", () => {
  const r = O.buildArgs(job({ archive: true, perms: false, times: true }))
  assert.deepStrictEqual(Array.from(r.argv), ["--archive", "--no-perms"])
  assert.strictEqual(r.errors.length, 0)
})

test("every value type", () => {
  const r = O.buildArgs(job({
    verbose: 2, bwlimit: 1024, maxSize: "500M", deleteMode: "after", recursive: true, delete: true,
    linkDest: "/snap/1\n\n/snap/2", checksumChoice: "xxh3", ipVersion: "6", timeout: 30, chmod: "D755"
  }))
  assert.deepStrictEqual(Array.from(r.argv), ["--recursive", "--chmod=D755", "--checksum-choice=xxh3",
    "--link-dest=/snap/1", "--link-dest=/snap/2", "--max-size=500M",
    "--delete", "--delete-after", "--bwlimit=1024", "--timeout=30", "--ipv6", "-v", "-v"])
})

test("rsh composition quotes identity", () => {
  const r = O.buildArgs(job({ sshPort: 2222, sshIdentity: "/home/u/my key" }), "ssh")
  assert.deepStrictEqual(Array.from(r.argv), ["--rsh=ssh -p 2222 -i '/home/u/my key'"])
})

test("filters and extra args", () => {
  const r = O.buildArgs(job({}, { filters: [{ type: "exclude", pattern: "*.tmp" }, { type: "protect", pattern: "keep/" }, { type: "include", pattern: "" }], extra: "--fsync '--out-format=%n x'" }))
  assert.deepStrictEqual(Array.from(r.argv), ["--exclude=*.tmp", "--filter=protect keep/", "--fsync", "--out-format=%n x"])
})

test("errors: invalid size, delete without recursion, unbalanced quotes, same paths", () => {
  assert(O.buildArgs(job({ maxSize: "5 GB" })).errors.some(e => /invalid size/.test(e)))
  assert(O.buildArgs(job({ delete: true })).errors.some(e => /Recursive/.test(e)))
  assert(O.buildArgs(job({ archive: true, delete: true })).errors.length === 0)
  assert(O.buildArgs(job({}, { extra: "'oops" })).errors.some(e => /quotes/.test(e)))
  assert(O.buildArgs(job({}, { src: "/x/", dst: "/x" })).errors.some(e => /same/.test(e)))
  assert(O.buildArgs(job({ inplace: true, delayUpdates: true })).errors.length === 1)
})

test("runArgs adds GUI flags, -- and ./ for dash paths", () => {
  const r = O.runArgs(job({ archive: true }, { src: "-weird", dst: "host:/x" }), "ssh", true)
  assert.deepStrictEqual(Array.from(r.argv), ["rsync", "--dry-run", "--archive", "--info=progress2",
    "--itemize-changes", "--stats", "--outbuf=L", "--", "./-weird", "host:/x"])
})

test("remote detection", () => {
  assert(O.isRemote("user@host:/srv"))
  assert(O.isRemote("host:data"))
  assert(O.isRemote("rsync://host/mod"))
  assert(!O.isRemote("/mnt/a:b"))
  assert(!O.isRemote("./a:b"))
  const t = O.sshTarget("alice@nas.local:/volume1")
  assert.strictEqual(t.user, "alice"); assert.strictEqual(t.host, "nas.local")
  assert.strictEqual(O.sshTarget("host::module"), null)
})

test("splitArgs and quote round trip", () => {
  const args = ["a b", "it's", "", "--x=$HOME", "plain"]
  assert.deepStrictEqual(Array.from(O.splitArgs(O.commandLine(args))), args)
})

test("progress, item and stats parsing", () => {
  const p = O.parseProgress("    512,000,000  48%   84.32MB/s    0:00:06 (xfr#12, to-chk=3/100)")
  assert.strictEqual(p.percent, 48); assert.strictEqual(p.transferred, 12); assert.strictEqual(p.total, 100)
  assert(O.parseProgress("          1.23G  100%  12.00MB/s    0:01:40 (xfr#3, ir-chk=1/9)"))
  assert.strictEqual(O.parseItem(">f+++++++++ docs/a.txt").kind, "new")
  assert.strictEqual(O.parseItem(">f.st...... docs/b.txt").kind, "update")
  assert.strictEqual(O.parseItem(".d..t...... docs/").kind, "attr")
  assert.strictEqual(O.parseItem("*deleting   old.txt").path, "old.txt")
  assert.strictEqual(O.parseItem("sending incremental file list"), null)
  const s = {}
  assert(O.parseStat("Number of regular files transferred: 1,234", s))
  assert(O.parseStat("sent 1.23K bytes  received 35 bytes  2,538.00 bytes/sec", s))
  assert.strictEqual(s.transferred, 1234); assert.strictEqual(s.sent, "1.23K")
})

test("a folder rsync could not remove is caught and weighs on the status", () => {
  assert.strictEqual(O.parseNotDeleted("cannot delete non-empty directory: 260818 - Nextcloud/Fotos"), "260818 - Nextcloud/Fotos")
  assert.strictEqual(O.parseNotDeleted("cannot delete non-empty directory: "), null)
  assert.strictEqual(O.parseNotDeleted("*deleting   old.txt"), null)
  assert.strictEqual(O.parseItem("cannot delete non-empty directory: a/b"), null)
  // rsync exits 0 over those folders, so only their number tells the run apart
  // from one that really made the destination a copy of the source
  assert.strictEqual(O.exitStatus(0, false, 5), "ok")
  assert.strictEqual(O.exitStatus(0, false, 5, 0), "ok")
  assert.strictEqual(O.exitStatus(0, false, 5, 9798), "partial")
  assert.strictEqual(O.exitStatus(0, true, 5, 9798), "stopped")
  assert.strictEqual(O.exitStatus(23, false, 0, 3), "failed")
})

test("safety: deleting into /, home, remote home, source inside destination", () => {
  const e = (opts, extra) => O.buildArgs(Object.assign(job(opts, extra), { home: "/home/me" })).errors
  assert(e({ archive: true, delete: true }, { dst: "/" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "/home/me/" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true }, { dst: "/home/me/", extra: "--delete-after" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "nas:" }).some(x => /remote home/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "u@nas:~/" }).some(x => /remote home/.test(x)))
  assert(!e({ archive: true, delete: true }, { dst: "u@nas:backup" }).some(x => /remote/.test(x)))
  // system trees are refused all the way down, folders that hold mount points
  // and scratch space only at the top: /srv/backup is where a backup belongs
  assert(e({ archive: true, delete: true }, { dst: "/usr/share/x" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "/etc/ssh" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "nas:/usr/share/x" }).some(x => /system folder/.test(x)))
  assert(!e({ archive: true, delete: true }, { dst: "/srv/backup" }).length)
  assert(!e({ archive: true, delete: true }, { dst: "/mnt/disk/b" }).length)
  assert(!e({ archive: true, delete: true }, { dst: "/var/tmp/try" }).length)
  assert(e({ archive: true, delete: true }, { src: "/data/photos/", dst: "/data" }).some(x => /inside the destination/.test(x)))
  assert(!e({ archive: true }, { src: "/data/photos/", dst: "/data" }).length)
  assert(O.buildArgs(job({}, { src: "/a/", dst: "/a/b" })).warnings.some(x => /inside the source/.test(x)))
  assert(e({}, { src: "-oProxyCommand=x:y" }).some(x => /start with/.test(x)))
  assert(e({ deleteMode: "bogus" }).some(x => /unknown value/.test(x)))
  assert.deepStrictEqual(Array.from(O.destructiveFlags(["-a", "--del", "--remove-source-files", "--delete-excluded", "--deleted", "--remove-sent-files"])), ["--del", "--remove-source-files", "--delete-excluded", "--remove-sent-files"])
  // folders containing home, system folders, relative paths, other users' remote homes
  assert(e({ archive: true, delete: true }, { dst: "/home" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "/home/me/../me/" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "/usr/" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "/run/media/me/" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "backup" }).some(x => /Refusing/.test(x)))
  assert(!e({ archive: true, delete: true }, { dst: "/run/media/me/Backup/" }).some(x => /Refusing/.test(x)))
  // a drive mounted straight under /run/media (VeraCrypt) is a drive root, not the user's drive folder
  assert(!e({ archive: true, delete: true }, { dst: "/run/media/veracrypt2" }).some(x => /Refusing/.test(x)))
  assert(!e({ archive: true, delete: true }, { dst: "/home/me/backup" }).some(x => /Refusing/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "u@nas:~other/" }).some(x => /remote home/.test(x)))
  // --delete-missing-args deletes on the receiver too
  assert(e({ archive: true, deleteMissingArgs: true }, { dst: "/home/me/" }).some(x => /Refusing to delete/.test(x)))
  assert(O.deletesOnReceiver(["--delete-missing-args"]))
})

test("safety: Move protects the source the way --delete protects the destination", () => {
  const e = (opts, extra) => O.buildArgs(Object.assign(job(opts, extra), { home: "/home/me" })).errors
  const move = { archive: true, removeSourceFiles: true }
  const removes = x => /Refusing to remove files/.test(x)
  assert(e(move, { src: "/", dst: "/mnt/b" }).some(removes))
  assert(e(move, { src: "/home/me/", dst: "/mnt/b" }).some(removes))
  assert(e(move, { src: "/home", dst: "/mnt/b" }).some(removes))
  assert(e(move, { src: "/etc/", dst: "/mnt/b" }).some(removes))
  assert(e(move, { src: "/run/media/me/", dst: "/mnt/b" }).some(removes))
  assert(e({ archive: true }, { src: "/home/me/", dst: "/mnt/b", extra: "--remove-sent-files" }).some(removes))
  assert(e(move, { src: "u@nas:~/", dst: "/mnt/b" }).some(x => /remote home/.test(x)))
  assert(e(move, { src: "nas:", dst: "/mnt/b" }).some(x => /remote home/.test(x)))
  // ordinary moves still work
  assert(!e(move, { src: "/home/me/Downloads/", dst: "/mnt/b" }).some(removes))
  assert(!e(move, { src: "/run/media/me/USB/", dst: "/mnt/b" }).some(removes))
  assert(!e(move, { src: "u@nas:inbox", dst: "/mnt/b" }).some(x => /remote home/.test(x)))
  // a plain copy never triggers it
  assert(!e({ archive: true }, { src: "/home/me/", dst: "/mnt/b" }).some(removes))
  assert(e({ archive: true, delete: true }, { dst: "u@nas:/home" }).some(x => /remote home/.test(x)))
  assert(e({}, { dst: "-l@nas:/x" }).some(x => /start with/.test(x)))
  // the remote home written out, like ~ is
  assert(e({ archive: true, delete: true }, { dst: "u@nas:/home/u/" }).some(x => /remote home/.test(x)))
  assert(e({ archive: true, delete: true }, { dst: "mac:/Users/u" }).some(x => /remote home/.test(x)))
  assert(e(move, { src: "u@nas:/home/u/./", dst: "/mnt/b" }).some(x => /remote home/.test(x)))
  assert(!e({ archive: true, delete: true }, { dst: "u@nas:/home/u/backup" }).some(x => /remote/.test(x)))
})

// ---- Locations.js
const L = { Options: O }
vm.createContext(L)
vm.runInContext(fs.readFileSync(__dirname + "/Locations.js", "utf8")
  .replace(/^\.pragma library/m, "").replace(/^\.import .*$/m, ""), L)

const LSBLK = JSON.stringify({ blockdevices: [
  { name: "nvme0n1", path: "/dev/nvme0n1", uuid: null, mountpoints: [], rm: false, hotplug: false, tran: "nvme", children: [
    { path: "/dev/nvme0n1p2", uuid: "root-uuid", label: null, mountpoints: ["/", "/home"], rm: false, hotplug: false } ] },
  { name: "sda", path: "/dev/sda", uuid: null, mountpoints: [null], rm: false, hotplug: true, tran: "usb", model: "WD Elements ", children: [
    { path: "/dev/sda1", uuid: "usb-uuid", label: "Backup", mountpoints: ["/run/media/me/Backup"], rm: false, hotplug: true } ] }
] })

test("passwords are kept out of the history and warned about", () => {
  const r = O.redactSecrets
  assert.strictEqual(r("rsync --rsh='sshpass -p hunter2 ssh' -- /a /b"), "rsync --rsh='sshpass -p <hidden> ssh' -- /a /b")
  assert.strictEqual(r("rsync --rsh='sshpass -phunter2 ssh' -- /a /b"), "rsync --rsh='sshpass -p<hidden> ssh' -- /a /b")
  assert.strictEqual(r("rsync -- rsync://u:s3cr3t@nas/mod /b"), "rsync -- rsync://u:<hidden>@nas/mod /b")
  // no false positives on ordinary options and paths
  const plain = ["rsync -a --rsh='ssh -o PasswordAuthentication=no' -- /a /b",
                 "rsync -a --password-file=/home/me/.pw -- /a /b",
                 "rsync -a -- /a/Passwords /b"]
  for (const c of plain) assert.strictEqual(r(c), c)
  // the job itself still holds it, so buildArgs says so
  const w = O.buildArgs(job({ rsh: "sshpass -p hunter2 ssh" }, { dst: "nas:backup" })).warnings
  assert(w.some(x => /password in the command/.test(x)), JSON.stringify(w))
  assert(!O.buildArgs(job({ rsh: "ssh" }, { dst: "nas:backup" })).warnings.some(x => /password/.test(x)))
  // the history's copy of the job is redacted too, and can't run until retyped
  const secret = job({ archive: true, rsh: "sshpass -p hunter2 ssh", sshOptions: "-o X=1" },
                     { dst: "nas:backup", extra: "--password=hunter2" })
  const kept = O.redactJob(secret)
  assert(!/hunter2/.test(JSON.stringify(kept)), JSON.stringify(kept))
  assert.strictEqual(kept.opts.sshOptions, "-o X=1")
  assert.strictEqual(secret.opts.rsh, "sshpass -p hunter2 ssh", "the live job is left alone")
  assert(O.buildArgs(kept).errors.some(x => /does not keep passwords/.test(x)))
  assert(!O.buildArgs(O.redactJob(job({ archive: true }))).errors.length)
})

test("mount points from findmnt", () => {
  const text = JSON.stringify({ filesystems: [{ target: "/" }, { target: "/home/me/nas" }, { target: "/mnt/a b" }, {}] }, null, 3)
  assert.deepStrictEqual(Array.from(L.parseFindmnt(text)), ["/", "/home/me/nas", "/mnt/a b"])
  assert.throws(() => L.parseFindmnt("{ not json"))
})

test("lsblk parsing and drive anchors", () => {
  const mounts = L.parseLsblk(LSBLK)
  assert.strictEqual(L.drives(mounts).length, 1)
  assert.strictEqual(L.anchorFor("/home/me/Documents", mounts, "/home/me"), null)
  const a = L.anchorFor("/run/media/me/Backup/laptop/", mounts, "/home/me")
  assert.deepStrictEqual(JSON.parse(JSON.stringify(a)),
    { uuid: "usb-uuid", label: "Backup", rel: "/laptop/", serial: "", size: "", fstype: "" })
  assert.strictEqual(L.anchorFor("/run/media/me/Backup", mounts, "/home/me").rel, "")
  // same drive, different mount point
  const moved = L.parseLsblk(LSBLK.replace("/run/media/me/Backup", "/mnt/usb"))
  assert.strictEqual(L.resolveAnchor(a, moved), "/mnt/usb/laptop/")
  const gone = L.parseLsblk(LSBLK.replace(/"usb-uuid"/, '"other"'))
  assert.strictEqual(L.resolveAnchor(a, gone), "")
  assert.strictEqual(L.describe("/x", a, gone, "/home/me").connected, false)
  assert.strictEqual(L.describe("~/Documents", null, mounts, "/home/me").detail, "~/Documents")
  assert.strictEqual(L.describe("me@nas:/data", null, mounts, "/home/me").kind, "ssh")
  assert.strictEqual(L.absolutePath("docs", "/home/me"), "/home/me/docs")
  assert.strictEqual(L.absolutePath("~/docs", "/home/me"), "/home/me/docs")
  assert.strictEqual(L.absolutePath("nas:docs", "/home/me"), "nas:docs")
  assert.strictEqual(L.absolutePath("", "/home/me"), "")
})

test("a cloned filesystem UUID is not the same drive", () => {
  const stick = (dev, serial, size) => JSON.stringify({ blockdevices: [
    { path: "/dev/" + dev, tran: "usb", serial: serial, model: "WD Elements", children: [
      { path: "/dev/" + dev + "1", uuid: "usb-uuid", label: "Backup", fstype: "exfat", size: size,
        mountpoints: ["/run/media/me/Backup"] } ] } ] })
  const mounts = L.parseLsblk(stick("sdb", "SER123", "1.8T"))
  const a = L.anchorFor("/run/media/me/Backup/laptop", mounts, "/home/me")
  assert.deepStrictEqual([a.serial, a.size, a.fstype], ["SER123", "1.8T", "exfat"])
  assert.strictEqual(L.resolveAnchor(a, mounts), "/run/media/me/Backup/laptop")
  // another drive carrying the same filesystem UUID is refused, not used
  const clone = L.parseLsblk(stick("sdc", "OTHER", "32G"))
  assert.strictEqual(L.resolveAnchor(a, clone), "")
  const info = L.describe("/x", a, clone, "/home/me")
  assert.strictEqual(info.connected, false)
  assert.strictEqual(info.mismatch, true)
  // simply not connected stays a different case
  assert.strictEqual(L.describe("/x", a, [], "/home/me").mismatch, false)
  // an anchor saved before the identity was recorded still resolves
  const old = L.sanitizeAnchor({ uuid: "usb-uuid", label: "Backup", rel: "/laptop" })
  assert.strictEqual(L.resolveAnchor(old, clone), "/run/media/me/Backup/laptop")
  // a serial the drive no longer reports is not treated as a mismatch
  const noSerial = L.parseLsblk(stick("sdb", null, "1.8T"))
  assert.strictEqual(L.resolveAnchor(a, noSerial), "/run/media/me/Backup/laptop")
})

test("unmounted media and anchor sanitising", () => {
  const mounts = L.parseLsblk(LSBLK)
  assert.strictEqual(L.unmountedMedia("/run/media/me/Backup/x", mounts, "/home/me"), "")
  assert.strictEqual(L.unmountedMedia("/run/media/me/Other/x", mounts, "/home/me"), "/run/media/me/Other")
  assert.strictEqual(L.unmountedMedia("/media/usb", mounts, "/home/me"), "/media/usb")
  assert.strictEqual(L.unmountedMedia("/home/me/x", mounts, "/home/me"), "")
  // VeraCrypt mounts a drive right under /run/media; the per-user folder is no drive
  const vc = L.parseLsblk(JSON.stringify({ blockdevices: [{ path: "/dev/sda", tran: "usb", children: [{ path: "/dev/sda2", children: [
    { path: "/dev/mapper/veracrypt1", uuid: "6AA3-CDD9", fstype: "exfat", mountpoints: ["/run/media/veracrypt1"] }] }] }] }))
  assert.strictEqual(L.unmountedMedia("/run/media/veracrypt1/Nextcloud", vc, "/home/me"), "")
  assert.strictEqual(L.unmountedMedia("/run/media/veracrypt2/Nextcloud", vc, "/home/me"), "/run/media/veracrypt2/Nextcloud")
  const userDir = L.parseLsblk(JSON.stringify({ blockdevices: [{ path: "/dev/sdc1", uuid: "u", fstype: "ext4", mountpoints: ["/run/media/me"], hotplug: true }] }))
  assert.strictEqual(L.unmountedMedia("/run/media/me/Backup/x", userDir, "/home/me"), "/run/media/me/Backup")
  assert.strictEqual(L.sanitizeAnchor({ uuid: "abc-1", rel: "/../../etc" }), null)
  assert.strictEqual(L.sanitizeAnchor({ uuid: "abc", rel: "etc" }), null)
  assert.strictEqual(L.sanitizeAnchor({ uuid: "$(x)", rel: "" }), null)
  assert.strictEqual(L.sanitizeAnchor({ uuid: "abc-1", rel: "/a/b/", label: "L" }).rel, "/a/b/")
  assert.strictEqual(L.sanitizeAnchor({ uuid: "abc-1", rel: "", serial: "x".repeat(200) }).serial.length, 64)
  assert.strictEqual(L.sanitizeAnchor({ uuid: "abc-1", rel: "", size: 12 }).size, "")
})

test("nesting warning and limited file systems", () => {
  const w = (src, dst) => O.buildArgs(job({ archive: true }, { src, dst })).warnings.some(x => /inside the destination/.test(x))
  assert(w("/home/me/Nextcloud", "/run/media/usb/Nextcloud"))
  assert(!w("/home/me/Nextcloud/", "/run/media/usb/Nextcloud"))
  assert(!w("/home/me/Nextcloud", "/run/media/usb/Backup"))
  const ex = L.parseLsblk(LSBLK.replace('"label": "Backup"', '"label": "Backup", "fstype": "exfat"').replace('label: "Backup"', 'label: "Backup", fstype: "exfat"'))
  const mounts = L.parseLsblk(JSON.stringify({ blockdevices: [{ path: "/dev/sdb1", uuid: "6AA1", fstype: "exfat", mountpoints: ["/run/media/me"], hotplug: true }] }))
  const fw = L.fsWarnings("/run/media/me/Nextcloud", { archive: true, hardLinks: true }, mounts, "/home/me")
  assert(fw.some(x => /Invalid argument/.test(x)))
  assert(fw.some(x => /Hard links/.test(x) && /Permissions/.test(x)))
  assert.strictEqual(L.fsWarnings("/home/me/x", { archive: true }, L.parseLsblk(LSBLK), "/home/me").length, 0)
})

test("FAT32 gets a time tolerance, exFAT does not", () => {
  const lsblk = fs => L.parseLsblk(JSON.stringify({ blockdevices: [{ path: "/dev/sdb1", uuid: "6AA1", fstype: fs, mountpoints: ["/run/media/me/STICK"], hotplug: true }] }))
  const fat = lsblk("vfat")
  const o = { archive: true }
  assert.strictEqual(L.fatTimeOpts(o, "/home/me/a/", "/run/media/me/STICK/a", fat, "/home/me").modifyWindow, 1)
  assert.strictEqual(L.fatTimeOpts(o, "/run/media/me/STICK/a/", "/home/me/a", fat, "/home/me").modifyWindow, 1)
  assert.strictEqual(o.modifyWindow, undefined)
  assert.strictEqual(L.fatTimeOpts({ archive: true, modifyWindow: 3 }, "/home/me/a/", "/run/media/me/STICK/a", fat, "/home/me").modifyWindow, 3)
  assert.strictEqual(L.fatTimeOpts(o, "/home/me/a/", "/run/media/me/STICK/a", lsblk("exfat"), "/home/me"), o)
  assert.strictEqual(L.fatTimeOpts(o, "/home/me/a/", "nas:/a", fat, "/home/me"), o)
  const w = L.fsWarnings("/run/media/me/STICK/a", L.fatTimeOpts(o, "/home/me/a/", "/run/media/me/STICK/a", fat, "/home/me"), fat, "/home/me")
  assert(!w.some(x => /2 s steps/.test(x)))
  assert(O.buildArgs(job(L.fatTimeOpts(o, "/home/me/a/", "/run/media/me/STICK/a", fat, "/home/me"))).argv.includes("--modify-window=1"))
})

test("safe file names: limits and file system detection", () => {
  const e = (opts, extra) => O.buildArgs(job(Object.assign({ archive: true, safeNames: true }, opts), extra)).errors
  assert.strictEqual(e({}).length, 0)
  assert(e({}, { dst: "nas:/backup" }).some(x => /local folders/.test(x)))
  assert(e({ linkDest: "/snap" }).some(x => /Link dest/.test(x)))
  assert(e({ backupDir: "old" }).some(x => /absolute Backup dir/.test(x)))
  // -K keeps a symlinked folder on the receiver, which the clean-up pass of
  // safe names refuses to enter: rejected here instead of failing every run
  assert(e({ keepDirlinks: true }).some(x => /Keep receiver dir symlinks/.test(x)))
  assert(!O.buildArgs(job({ safeNames: true })).argv.some(a => a === ""))
  const mounts = L.parseLsblk(JSON.stringify({ blockdevices: [{ path: "/dev/sdb1", uuid: "6AA1", fstype: "exfat", mountpoints: ["/run/media/me"], hotplug: true }] }))
  assert.strictEqual(L.limitedFs("/run/media/me/x", mounts, "/home/me"), "exFAT")
  assert.strictEqual(L.limitedFs("/home/me/x", mounts, "/home/me"), "")
  assert(!L.fsWarnings("/run/media/me/x", { archive: true, safeNames: true }, mounts, "/home/me").some(x => /Invalid argument/.test(x)))
})

test("presets adapt to FAT/exFAT/NTFS destinations", () => {
  const mirror = O.PRESETS.find(p => p.id === "mirror")
  const adapted = O.presetOpts(mirror, true)
  assert.deepStrictEqual(JSON.parse(JSON.stringify(adapted)),
    { archive: true, delete: true, perms: false, owner: false, group: false, links: false, devices: false, specials: false })
  const argv = Array.from(O.buildArgs(job(adapted)).argv)
  assert.deepStrictEqual(argv, ["--archive", "--no-links", "--no-perms", "--no-owner", "--no-group", "--no-devices", "--no-specials", "--delete"])
  assert.deepStrictEqual(JSON.parse(JSON.stringify(O.matchPreset(Object.assign({ safeNames: true, bwlimit: 1024 }, adapted)))), { id: "mirror", limitedFs: true })
  assert.deepStrictEqual(JSON.parse(JSON.stringify(O.matchPreset(mirror.opts))), { id: "mirror", limitedFs: false })
  assert.strictEqual(O.matchPreset({ archive: true, delete: true, perms: false }).id, "custom")
  const move = O.presetOpts(O.PRESETS.find(p => p.id === "move"), true)
  assert.strictEqual(O.matchPreset(move).id, "move")
})

test("presets match in any key order, as Qt's JSON.stringify leaves it", () => {
  // Qt's JS engine keeps an object's own key order even when JSON.stringify
  // gets a sorted key list, and a profile's job comes back with sorted keys.
  const Q = {}
  vm.createContext(Q)
  vm.runInContext(`(function() {
    var stringify = JSON.stringify
    JSON.stringify = function(v, keys, space) {
      if (!Array.isArray(keys) || !v || typeof v !== "object") return stringify(v, keys, space)
      var o = {}
      Object.keys(v).forEach(function(k) { if (keys.indexOf(k) >= 0) o[k] = v[k] })
      return stringify(o, null, space)
    }
  })()`, Q)
  vm.runInContext(src, Q)
  const sorted = o => Object.keys(o).sort().reduce((r, k) => (r[k] = o[k], r), {})
  for (const p of Q.PRESETS) for (const limited of [false, true]) {
    const opts = sorted(Object.assign({ partial: true, safeNames: limited }, Q.presetOpts(p, limited)))
    assert.deepStrictEqual(JSON.parse(JSON.stringify(Q.matchPreset(opts))), { id: p.id, limitedFs: limited }, p.id + (limited ? " on FAT/exFAT" : ""))
  }
})

test("dry run progress comes from the file counter, not the bytes", () => {
  const line = "      9,923,668   0%    9.24GB/s    0:00:00 (xfr#5, ir-chk=1136/20761)"
  const p = O.parseProgress(line)
  assert.strictEqual(p.percent, 0)
  assert.strictEqual(p.eta, "0:00:00")
  const s = O.scanProgress(p, 400000)
  assert.strictEqual(s.done, 19625)
  assert.strictEqual(s.total, 20761)
  assert.strictEqual(s.percent, 94)
  assert.strictEqual(s.rate, 49)
  assert.strictEqual(O.scanProgress(O.parseProgress("   1,234  3%  1MB/s  0:00:10"), 9000), null)
  assert.strictEqual(O.formatClock(3725), "1:02:05")
})

test("ssh config hosts", () => {
  assert.deepStrictEqual(Array.from(L.parseSshConfig("Host nas backup\n  Port 2222\nHost *.lan !x\nhost server")), ["nas", "backup", "server"])
})

if (failures) { console.log(failures + " failed"); process.exit(1) }
console.log("all passed")
