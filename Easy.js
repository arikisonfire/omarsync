.pragma library

.import "Options.js" as Options

// Easy mode: plain questions on top of the same job. Nothing is stored here:
// answers are read back from job.opts/job.filters and every answer writes
// ordinary options and filter rules, so Expert mode always shows what Easy set.

var GOALS = [
  { id: "copy", label: "Copy", hint: "Adds new and changed files. Nothing is deleted at the destination." },
  { id: "mirror", label: "Mirror", hint: "The destination becomes an exact copy. Files missing in the source are deleted there.", danger: true },
  { id: "update", label: "Update", hint: "Like Copy, but a file that is newer at the destination is never overwritten." },
  { id: "move", label: "Move", hint: "Copies the files, then removes them from the source.", danger: true }
]

var BACKUP_ROOT = ".rsync-backup"
var BACKUP_DIR = BACKUP_ROOT + "/{date}"
var BACKUP_FILTER = { type: "exclude", pattern: "/" + BACKUP_ROOT + "/" }

var BANDWIDTH = [
  { id: "full", label: "Full speed", kib: 0 },
  { id: "10", label: "10 MB/s", kib: 10240 },
  { id: "2", label: "2 MB/s", kib: 2048 }
]

var SKIP_SETS = [
  { id: "caches", label: "Caches and trash", hint: "Temporary files programs can recreate, and deleted files",
    patterns: [".cache/", ".Trash-*/", ".local/share/Trash/"] },
  { id: "systemJunk", label: "System junk files", hint: ".DS_Store, Thumbs.db, desktop.ini, lost+found and similar",
    patterns: [".DS_Store", "._*", "Thumbs.db", "desktop.ini", "$RECYCLE.BIN/", "System Volume Information/", "lost+found/"] }
]

// Options a goal (preset, plain or adapted to FAT/exFAT/NTFS) may set
function goalKeys() {
  var keys = {}
  for (var i = 0; i < Options.PRESETS.length; i++) {
    [false, true].forEach(function(limited) {
      var o = Options.presetOpts(Options.PRESETS[i], limited)
      for (var k in o) keys[k] = true
    })
  }
  Options.LIMITED_FS_OFF.forEach(function(k) { keys[k] = true })
  return keys
}
var GOAL_KEYS = goalKeys()

function hasFilter(filters, f) {
  return (filters || []).some(function(x) { return x && x.type === f.type && x.pattern === f.pattern })
}

function skipOn(filters, set) {
  return set.patterns.every(function(p) { return hasFilter(filters, { type: "exclude", pattern: p }) })
}

function ownedFilter(f) {
  if (!f || f.type !== "exclude") return false
  if (f.pattern === BACKUP_FILTER.pattern) return true
  return SKIP_SETS.some(function(s) { return s.patterns.indexOf(f.pattern) >= 0 })
}

function isSafetyCopy(opts) {
  return Options.isOn(opts, "backup") && String(opts.backupDir || "").replace(/\/+$/, "") === BACKUP_DIR
}

// { goal, thorough, safetyCopy, slowLink, resume, bandwidth, skip: {id: bool}, extras: [label] }
function read(job) {
  var opts = job.opts || {}
  var filters = job.filters || []
  var match = Options.matchPreset(opts)
  var bw = Number(opts.bwlimit) || 0
  var band = "custom"
  for (var b = 0; b < BANDWIDTH.length; b++) if (BANDWIDTH[b].kib === bw) band = BANDWIDTH[b].id

  var skip = {}
  SKIP_SETS.forEach(function(s) { skip[s.id] = skipOn(filters, s) })

  var extras = []
  for (var k in opts) {
    if (!Options.isModified(opts, k) || k === "safeNames") continue
    // goal options: a custom mix is named as a whole, not listed one by one
    if (GOAL_KEYS[k]) continue
    if (k === "checksum" || k === "partial" || k === "compress") continue
    if (k === "bwlimit" && band !== "custom") continue
    if ((k === "backup" || k === "backupDir") && isSafetyCopy(opts)) continue
    var def = Options.BY_KEY[k]
    extras.push(def ? def.label : k)
  }
  var foreign = filters.filter(function(f) {
    if (f && f.pattern === BACKUP_FILTER.pattern && f.type === "exclude") return !isSafetyCopy(opts)
    if (!ownedFilter(f)) return true
    // a lone pattern of a skip set that isn't complete
    return !SKIP_SETS.some(function(s) { return s.patterns.indexOf(f.pattern) >= 0 && skip[s.id] })
  })
  if (foreign.length) extras.push(foreign.length === 1 ? "1 filter rule" : foreign.length + " filter rules")
  if (String(job.extra || "").trim() !== "") extras.push("Extra arguments")

  return {
    goal: match.id,
    limitedFs: match.limitedFs,
    thorough: Options.isOn(opts, "checksum"),
    safetyCopy: isSafetyCopy(opts),
    slowLink: Options.isOn(opts, "compress"),
    resume: Options.isOn(opts, "partial"),
    bandwidth: band,
    skip: skip,
    extras: extras
  }
}

// New { opts, filters } for one answer. Goals go through the panel's
// applyPreset, which knows the destination's file system.
function withAnswer(job, key, value) {
  var opts = Object.assign({}, job.opts || {})
  var filters = (job.filters || []).slice()
  function set(k, on) { if (on) opts[k] = true; else delete opts[k] }
  function addFilter(f) { if (!hasFilter(filters, f)) filters.push({ type: f.type, pattern: f.pattern }) }
  function dropFilter(f) { filters = filters.filter(function(x) { return !(x && x.type === f.type && x.pattern === f.pattern) }) }

  switch (key) {
  case "thorough": set("checksum", value); break
  case "slowLink": set("compress", value); break
  case "resume": set("partial", value); break
  case "bandwidth":
    for (var b = 0; b < BANDWIDTH.length; b++) if (BANDWIDTH[b].id === value) {
      if (BANDWIDTH[b].kib) opts.bwlimit = BANDWIDTH[b].kib
      else delete opts.bwlimit
    }
    break
  case "safetyCopy":
    if (value) {
      opts.backup = true
      opts.backupDir = BACKUP_DIR
      addFilter(BACKUP_FILTER)
    } else {
      delete opts.backup
      delete opts.backupDir
      delete opts.suffix
      dropFilter(BACKUP_FILTER)
    }
    break
  default:
    var m = /^skip\.(\w+)$/.exec(key)
    var set_ = m && SKIP_SETS.filter(function(s) { return s.id === m[1] })[0]
    if (!set_) break
    set_.patterns.forEach(function(p) {
      if (value) addFilter({ type: "exclude", pattern: p })
      else dropFilter({ type: "exclude", pattern: p })
    })
  }
  return { opts: opts, filters: filters }
}

function quoted(s) { return "“" + s + "”" }

// A few plain sentences about what a run does.
// ctx: { srcName, dstName, contentsOnly, remote, dstFs }
function summary(job, ctx) {
  var a = read(job)
  if (!job.src || !job.dst) return "Choose where to copy from and where to copy to."
  var what = ctx.contentsOnly ? "the contents of " + quoted(ctx.srcName) : "the folder " + quoted(ctx.srcName)
  var out = []
  switch (a.goal) {
  case "copy": out.push("Copies new and changed files from " + what + " to " + quoted(ctx.dstName) + ". Nothing is deleted there."); break
  case "mirror": out.push("Makes " + quoted(ctx.dstName) + " an exact copy of " + what + ": files that are not in the source are deleted there."); break
  case "update": out.push("Copies new and changed files from " + what + " to " + quoted(ctx.dstName) + ", but never overwrites a file that is newer there. Nothing is deleted."); break
  case "move": out.push("Moves the files of " + what + " to " + quoted(ctx.dstName) + ": after copying they are removed from the source."); break
  default: out.push("Syncs " + what + " to " + quoted(ctx.dstName) + " with your own combination of settings from Expert mode.")
  }
  out.push(a.thorough ? "Compares the contents of every file (slower, catches every change)." : "Detects changes by size and date.")
  if (a.safetyCopy) out.push("Files that get replaced or deleted are kept in " + BACKUP_ROOT + " at the destination, in a folder per run.")
  var skipped = SKIP_SETS.filter(function(s) { return a.skip[s.id] }).map(function(s) { return s.label.toLowerCase() })
  if (skipped.length) out.push("Skips " + skipped.join(" and ") + ".")
  if (ctx.dstFs) out.push("The drive uses " + ctx.dstFs + ": settings it can't store are left out"
    + (Options.isOn(job.opts, "safeNames") ? " and names it can't store get look-alike characters." : "."))
  if (ctx.remote && (a.slowLink || a.bandwidth !== "full" || a.resume)) {
    var net = []
    if (a.slowLink) net.push("compresses data")
    if (a.bandwidth !== "full") net.push("limits the speed")
    if (a.resume) net.push("resumes interrupted files")
    out.push("Over the network it " + net.join(", ") + ".")
  }
  return out.join(" ")
}
