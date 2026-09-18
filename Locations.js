.pragma library

.import "Options.js" as Options

// Where a path lives: local disk, removable drive (tracked by filesystem UUID so
// a job still works when the drive mounts somewhere else) or a remote host.

// lsblk -J -o NAME,PATH,UUID,LABEL,MOUNTPOINTS,RM,HOTPLUG,TRAN,SIZE,MODEL,FSTYPE
function parseLsblk(text) {
  var mounts = []
  var data
  try { data = JSON.parse(text) } catch (e) { return mounts }

  function walk(dev, removable, model) {
    var rem = removable || dev.rm === true || dev.rm === "1" || dev.hotplug === true || dev.hotplug === "1" || dev.tran === "usb"
    var mdl = dev.model || model || ""
    var points = dev.mountpoints || []
    for (var i = 0; i < points.length; i++) {
      var mp = points[i]
      if (!mp || mp.charAt(0) !== "/") continue
      // udisks mounts external media under /run/media (or /media)
      var external = rem || /^\/(run\/)?media\//.test(mp)
      mounts.push({ mount: mp, uuid: dev.uuid || "", label: dev.label || "", removable: !!external,
                    size: dev.size || "", device: dev.path || "", model: String(mdl).trim(), fstype: dev.fstype || "" })
    }
    var children = dev.children || []
    for (var c = 0; c < children.length; c++) walk(children[c], rem, mdl)
  }

  var devs = (data && data.blockdevices) || []
  for (var d = 0; d < devs.length; d++) walk(devs[d], false, "")
  // Longest mount first so prefix lookups find the innermost file system.
  mounts.sort(function(a, b) { return b.mount.length - a.mount.length })
  return mounts
}

// Every mount point from `findmnt -J -l -o TARGET`, network and FUSE mounts
// included, which lsblk doesn't list. Throws on output that isn't JSON.
function parseFindmnt(text) {
  var data = JSON.parse(text)
  return ((data && data.filesystems) || []).map(function(f) { return f && f.target })
    .filter(function(t) { return typeof t === "string" && t.charAt(0) === "/" })
}

function drives(mounts) {
  return mounts.filter(function(m) { return m.removable && m.uuid && m.mount !== "/" })
}

function expandHome(path, home) {
  var p = String(path || "")
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.slice(1)
  return p
}

// Absolute local path: ~ expanded, relative paths taken from the home folder
// (so a run never depends on the shell's working directory). Remote paths and
// "" are returned unchanged.
function absolutePath(path, home) {
  var p = expandHome(path, home)
  if (p === "" || p.charAt(0) === "/" || Options.isRemote(p)) return p
  return home + "/" + p
}

function mountFor(path, mounts) {
  for (var i = 0; i < mounts.length; i++) {
    var mp = mounts[i].mount
    if (path === mp || path.indexOf(mp === "/" ? "/" : mp + "/") === 0) return mounts[i]
  }
  return null
}

// { uuid, label, rel } for a path on a removable drive, else null.
function anchorFor(path, mounts, home) {
  var p = expandHome(path, home)
  if (!p || p.charAt(0) !== "/" || Options.isRemote(p)) return null
  var m = mountFor(p, mounts)
  if (!m || !m.removable || !m.uuid) return null
  return { uuid: m.uuid, label: m.label || m.model || m.device, rel: p.slice(m.mount === "/" ? 0 : m.mount.length) }
}

// For a local path under /run/media/<user>/<name> or /media/<name>: that
// mount point when nothing is mounted there (the directory is empty or gone),
// else "". Syncing into such a path fills the internal disk, syncing from it
// with --delete empties the destination.
// File systems that can't store Unix names and metadata
var LIMITED_FS = { vfat: "FAT32", exfat: "exFAT", ntfs: "NTFS", ntfs3: "NTFS", fuseblk: "NTFS" }

// "exFAT" etc. when a local path lives on such a file system, else ""
function limitedFs(path, mounts, home) {
  var p = absolutePath(path, home)
  if (!p || p.charAt(0) !== "/") return ""
  var m = mountFor(p, mounts)
  return m && LIMITED_FS[m.fstype] ? LIMITED_FS[m.fstype] : ""
}

// Warnings for a local destination on FAT/exFAT/NTFS, given the effective opts
function fsWarnings(path, opts, mounts, home, srcRemote) {
  var name = limitedFs(path, mounts, home)
  if (!name) return []
  var m = mountFor(absolutePath(path, home), mounts)
  var out = []
  if (!Options.isOn(opts, "safeNames"))
    out.push(name + " can't store file names containing \\ : * ? \" < > | or ending in a dot — such files fail with “Invalid argument”. "
      + (srcRemote ? "Rename them on the server if there are any." : "Turn on Safe file names below."))
  var unsupported = ["perms", "owner", "group", "links", "hardLinks", "acls", "xattrs", "devices", "specials"]
    .filter(function(k) { return Options.isOn(opts, k) })
  if (unsupported.length)
    out.push(name + " has no permissions, owners, symlinks, hard links, ACLs or xattrs: turn off " + unsupported.map(function(k) { return Options.BY_KEY[k].label }).join(", ") + " to avoid errors")
  if (m.fstype === "vfat" && !(Number(opts && opts.modifyWindow) > 0))
    out.push("FAT32 stores times in 2 s steps: set Time tolerance to 1 or more, or every run copies everything again")
  return out
}

// FAT32 on either side: add --modify-window=1 unless a tolerance is set, so
// its 2 s time steps don't make every file look changed. Returns opts as they
// are when nothing needs to change.
function fatTimeOpts(opts, src, dst, mounts, home) {
  if (opts && opts.modifyWindow !== undefined && opts.modifyWindow !== null && opts.modifyWindow !== "") return opts
  if (limitedFs(src, mounts, home) !== "FAT32" && limitedFs(dst, mounts, home) !== "FAT32") return opts
  var o = {}
  for (var k in opts || {}) o[k] = opts[k]
  o.modifyWindow = 1
  return o
}

function unmountedMedia(path, mounts, home) {
  var p = expandHome(path, home)
  var m = /^(\/run\/media\/[^\/]+\/[^\/]+|\/media\/[^\/]+)(\/|$)/.exec(p)
  if (!m) return ""
  var fs = mountFor(p, mounts)
  return fs && (fs.mount === m[1] || fs.mount.indexOf(m[1] + "/") === 0) ? "" : m[1]
}

// Anchors come from state files: accept only a UUID and a relative path
// that can't climb out of the drive.
function sanitizeAnchor(a) {
  if (!a || typeof a !== "object" || typeof a.uuid !== "string" || !/^[A-Za-z0-9-]{1,64}$/.test(a.uuid)) return null
  var rel = typeof a.rel === "string" ? a.rel : ""
  if (rel !== "" && rel.charAt(0) !== "/") return null
  if (/(^|\/)\.\.(\/|$)/.test(rel)) return null
  return { uuid: a.uuid, label: typeof a.label === "string" ? a.label.slice(0, 80) : "", rel: rel }
}

// Current path for an anchor, or "" when the drive is not connected/mounted.
function resolveAnchor(anchor, mounts) {
  if (!anchor || !anchor.uuid) return ""
  for (var i = 0; i < mounts.length; i++) {
    if (mounts[i].uuid === anchor.uuid) return mounts[i].mount + (anchor.rel || "")
  }
  return ""
}

// { kind: "local"|"drive"|"ssh"|"daemon", title, detail, connected }
function describe(path, anchor, mounts, home) {
  var p = String(path || "")
  if (!p && !anchor) return { kind: "none", title: "", detail: "", connected: true }
  var ssh = Options.sshTarget(p)
  if (ssh) return { kind: "ssh", title: (ssh.user ? ssh.user + "@" : "") + ssh.host, detail: ssh.path || "~", connected: true }
  if (Options.isRemote(p)) return { kind: "daemon", title: "rsync daemon", detail: p, connected: true }
  if (anchor && anchor.uuid) {
    var now = resolveAnchor(anchor, mounts)
    return { kind: "drive", title: "Drive “" + (anchor.label || anchor.uuid.slice(0, 8)) + "”",
             detail: (anchor.rel || "/"), connected: now !== "" }
  }
  var full = absolutePath(p, home)
  var shown = home && full.indexOf(home + "/") === 0 ? "~" + full.slice(home.length) : full
  return { kind: "local", title: "This computer", detail: shown, connected: true }
}

function shortLabel(path, anchor, mounts, home) {
  var d = describe(path, anchor, mounts, home)
  if (d.kind === "none") return "?"
  if (d.kind === "local") return compact(d.detail)
  if (d.kind === "drive") return d.title + " " + d.detail
  if (d.kind === "ssh") return d.title + ":" + compact(d.detail)
  return d.detail
}

// Long local paths keep their start and the last two parts: /tmp/…/t/dst
function compact(p) {
  if (p.length <= 36) return p
  var trail = /\/$/.test(p) ? "/" : ""
  var parts = p.replace(/\/+$/, "").split("/")
  if (parts.length <= 4) return p
  return parts.slice(0, 2).join("/") + "/…/" + parts.slice(-2).join("/") + trail
}

// Host aliases from ~/.ssh/config (no wildcards, no negations)
function parseSshConfig(text) {
  var hosts = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*Host\s+(.+)$/i.exec(lines[i])
    if (!m) continue
    var names = m[1].split(/\s+/)
    for (var n = 0; n < names.length; n++) {
      var h = names[n]
      if (h && !/[*?!]/.test(h) && hosts.indexOf(h) < 0) hosts.push(h)
    }
  }
  return hosts
}

