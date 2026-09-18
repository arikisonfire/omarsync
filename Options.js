.pragma library

// rsync option catalog and job -> argv logic. Pure JS so it can be tested
// outside the shell (see test-options.js).
//
// A job is { src, dst, opts: { key: value }, filters: [{ type, pattern }],
// extra: "" }. Only keys the user changed live in opts; everything else is the
// catalog default. Values never pass through a shell: buildArgs returns argv.

var GROUPS = [
  { id: "preserve", label: "Preserve" },
  { id: "update", label: "Update & compare" },
  { id: "delete", label: "Delete & backup" },
  { id: "filters", label: "Filter options" },
  { id: "connection", label: "Connection" },
  { id: "output", label: "Output & batch" },
  { id: "safety", label: "Safety & expert" }
]

// Options implied by --archive (-rlptgoD). Turning one off while archive is on
// emits --no-<name>.
var ARCHIVE_IMPLIES = ["recursive", "links", "perms", "times", "group", "owner", "devices", "specials"]

function b(key, flag, short, group, label, hint) {
  return { key: key, flag: flag, short: short || "", type: "bool", group: group, label: label, hint: hint }
}
function t(type, key, flag, group, label, hint, extra) {
  var o = { key: key, flag: flag, short: "", type: type, group: group, label: label, hint: hint }
  for (var k in extra || {}) o[k] = extra[k]
  return o
}

var BW_STEPS = [0, 128, 256, 512, 1024, 2048, 5120, 10240, 20480, 51200, 102400]

var CATALOG = [
  // ---- preserve
  b("archive", "--archive", "-a", "preserve", "Archive mode", "Recursive and preserve links, permissions, times, group, owner, devices (-rlptgoD)"),
  b("recursive", "--recursive", "-r", "preserve", "Recursive", "Recurse into directories"),
  b("relative", "--relative", "-R", "preserve", "Relative paths", "Keep the full source path below the destination"),
  b("noImpliedDirs", "--no-implied-dirs", "", "preserve", "No implied dirs", "Don't send implied directories with --relative"),
  b("dirs", "--dirs", "-d", "preserve", "Directories without recursing", "Transfer directories themselves, not their contents"),
  b("links", "--links", "-l", "preserve", "Symlinks as symlinks", "Copy symlinks as symlinks"),
  b("copyLinks", "--copy-links", "-L", "preserve", "Follow symlinks", "Copy the file or directory a symlink points to"),
  b("copyUnsafeLinks", "--copy-unsafe-links", "", "preserve", "Follow unsafe symlinks", "Only symlinks pointing outside the tree are followed"),
  b("safeLinks", "--safe-links", "", "preserve", "Skip unsafe symlinks", "Ignore symlinks that point outside the tree"),
  b("mungeLinks", "--munge-links", "", "preserve", "Munge symlinks", "Make symlinks safe but unusable"),
  b("copyDirlinks", "--copy-dirlinks", "-k", "preserve", "Follow dir symlinks", "Transform symlinks to directories into real directories"),
  b("keepDirlinks", "--keep-dirlinks", "-K", "preserve", "Keep receiver dir symlinks", "Treat a symlinked directory on the receiver as a directory"),
  b("hardLinks", "--hard-links", "-H", "preserve", "Hard links", "Preserve hard links"),
  b("perms", "--perms", "-p", "preserve", "Permissions", "Preserve permissions"),
  b("executability", "--executability", "-E", "preserve", "Executability", "Preserve only the executable bit"),
  t("text", "chmod", "--chmod", "preserve", "chmod", "Change permissions, e.g. D755,F644", { placeholder: "Du=rwx,Dgo=rx,Fu=rw,Fgo=r" }),
  b("acls", "--acls", "-A", "preserve", "ACLs", "Preserve access control lists (implies permissions)"),
  b("xattrs", "--xattrs", "-X", "preserve", "Extended attributes", "Preserve extended attributes"),
  b("owner", "--owner", "-o", "preserve", "Owner", "Preserve owner (needs super-user on the receiver)"),
  b("group", "--group", "-g", "preserve", "Group", "Preserve group"),
  b("devices", "--devices", "", "preserve", "Device files", "Preserve device files (super-user only)"),
  b("specials", "--specials", "", "preserve", "Special files", "Preserve sockets and FIFOs"),
  b("dropD", "--drop-D", "", "preserve", "Refuse devices", "Receiver refuses to create devices and special files"),
  b("copyDevices", "--copy-devices", "", "preserve", "Copy device contents", "Copy a device's contents as a regular file"),
  b("writeDevices", "--write-devices", "", "preserve", "Write to devices", "Write file data into existing devices (implies in-place)"),
  b("times", "--times", "-t", "preserve", "Modification times", "Preserve modification times"),
  b("atimes", "--atimes", "-U", "preserve", "Access times", "Preserve access times"),
  b("openNoatime", "--open-noatime", "", "preserve", "Don't touch atime", "Avoid changing the access time of opened files"),
  b("crtimes", "--crtimes", "-N", "preserve", "Creation times", "Preserve creation times (not every rsync build and file system supports this)"),
  b("omitDirTimes", "--omit-dir-times", "-O", "preserve", "Omit directory times", "Don't preserve directory modification times"),
  b("omitLinkTimes", "--omit-link-times", "-J", "preserve", "Omit symlink times", "Don't preserve symlink modification times"),
  b("superUser", "--super", "", "preserve", "Super-user activities", "Receiver attempts super-user activities"),
  b("fakeSuper", "--fake-super", "", "preserve", "Fake super", "Store privileged attributes in extended attributes"),
  b("sparse", "--sparse", "-S", "preserve", "Sparse files", "Turn sequences of zeros into sparse blocks"),
  b("preallocate", "--preallocate", "", "preserve", "Preallocate", "Allocate destination files before writing"),
  b("numericIds", "--numeric-ids", "", "preserve", "Numeric IDs", "Don't map user and group IDs by name"),
  t("text", "chown", "--chown", "preserve", "chown", "Set owner and group, USER:GROUP", { placeholder: "user:group" }),
  t("text", "usermap", "--usermap", "preserve", "User map", "Custom user name mapping", { placeholder: "0-99:nobody,alice:bob" }),
  t("text", "groupmap", "--groupmap", "preserve", "Group map", "Custom group name mapping", { placeholder: "wheel:users" }),
  t("text", "copyAs", "--copy-as", "preserve", "Copy as", "User and optional group for the copy", { placeholder: "USER[:GROUP]" }),

  // ---- update & compare
  b("update", "--update", "-u", "update", "Skip newer on receiver", "Skip files that are newer on the destination"),
  b("inplace", "--inplace", "", "update", "Update in place", "Write directly into destination files"),
  b("append", "--append", "", "update", "Append", "Append data onto shorter files"),
  b("appendVerify", "--append-verify", "", "update", "Append and verify", "Append, include old data in the file checksum"),
  b("wholeFile", "--whole-file", "-W", "update", "Whole files", "Copy files whole, without the delta algorithm"),
  b("oneFileSystem", "--one-file-system", "-x", "update", "One file system", "Don't cross file system boundaries"),
  b("existing", "--existing", "", "update", "Only existing files", "Skip creating new files on the receiver"),
  b("ignoreExisting", "--ignore-existing", "", "update", "Skip existing files", "Skip updating files that already exist"),
  b("checksum", "--checksum", "-c", "update", "Compare checksums", "Skip based on checksum, not time and size (slower)"),
  t("choice", "checksumChoice", "--checksum-choice", "update", "Checksum algorithm", "Algorithm for file and block checksums",
    { choices: ["", "xxh128", "xxh3", "xxh64", "md5", "md4", "sha1", "none"] }),
  b("sizeOnly", "--size-only", "", "update", "Size only", "Skip files that match in size"),
  b("ignoreTimes", "--ignore-times", "-I", "update", "Ignore times", "Don't skip files that match size and time"),
  t("number", "modifyWindow", "--modify-window", "update", "Time tolerance (s)", "Accuracy for modification time comparisons (FAT: 1)", { min: -1, max: 3600 }),
  b("fuzzy", "--fuzzy", "-y", "update", "Fuzzy basis", "Use a similar file as basis if the destination file is missing"),
  t("list", "compareDest", "--compare-dest", "update", "Compare dest", "Also compare against these directories (one per line)"),
  t("list", "copyDest", "--copy-dest", "update", "Copy dest", "Like compare dest, copying unchanged files (one per line)"),
  t("list", "linkDest", "--link-dest", "update", "Link dest", "Hard-link unchanged files from these directories: snapshots (one per line)"),
  b("mkpath", "--mkpath", "", "update", "Create destination path", "Create missing path components of the destination"),
  b("partial", "--partial", "", "update", "Keep partial files", "Resume interrupted transfers"),
  t("path", "partialDir", "--partial-dir", "update", "Partial dir", "Put partially transferred files into this directory"),
  b("delayUpdates", "--delay-updates", "", "update", "Delay updates", "Put all updated files into place at the end"),
  b("pruneEmptyDirs", "--prune-empty-dirs", "-m", "update", "Prune empty dirs", "Remove empty directory chains from the file list"),
  t("path", "tempDir", "--temp-dir", "update", "Temp dir", "Create temporary files in this directory"),
  t("size", "maxSize", "--max-size", "update", "Max file size", "Don't transfer files larger than this", { placeholder: "e.g. 500M" }),
  t("size", "minSize", "--min-size", "update", "Min file size", "Don't transfer files smaller than this", { placeholder: "e.g. 1K" }),
  t("size", "blockSize", "--block-size", "update", "Block size", "Force a fixed checksum block size", { placeholder: "e.g. 128K" }),
  b("removeSourceFiles", "--remove-source-files", "", "update", "Remove source files", "Delete transferred files from the source (move)"),
  b("ignoreMissingArgs", "--ignore-missing-args", "", "update", "Ignore missing sources", "Missing source arguments are not an error"),
  b("deleteMissingArgs", "--delete-missing-args", "", "update", "Delete missing sources", "Delete missing source arguments from the destination"),
  b("fsync", "--fsync", "", "update", "fsync", "Flush every written file to disk"),
  b("incRecursive", "--no-inc-recursive", "", "update", "No incremental recursion", "Scan the whole file list before transferring"),

  // ---- delete & backup
  b("delete", "--delete", "", "delete", "Delete extraneous", "Delete files on the destination that are not in the source"),
  t("choice", "deleteMode", "", "delete", "Delete timing", "When the receiver deletes",
    { choices: ["", "before", "during", "delay", "after"], flags: { before: "--delete-before", during: "--delete-during", delay: "--delete-delay", after: "--delete-after" } }),
  b("deleteExcluded", "--delete-excluded", "", "delete", "Delete excluded", "Also delete excluded files on the destination"),
  t("number", "maxDelete", "--max-delete", "delete", "Max deletions", "Don't delete more than this many files (0 = unset)", { min: 0, max: 1000000 }),
  b("ignoreErrors", "--ignore-errors", "", "delete", "Delete despite I/O errors", "Delete even if there are I/O errors"),
  b("force", "--force", "", "delete", "Force", "Delete non-empty directories when replaced by a file"),
  b("backup", "--backup", "-b", "delete", "Backup", "Keep replaced and deleted files as backups"),
  t("path", "backupDir", "--backup-dir", "delete", "Backup dir", "Store backups in this directory hierarchy; {date} becomes the start time, e.g. .rsync-backup/{date}"),
  t("text", "suffix", "--suffix", "delete", "Backup suffix", "Suffix for backups (default ~ without backup dir)", { placeholder: "~" }),

  // ---- filter options (rules themselves live in the Filters tab)
  b("cvsExclude", "--cvs-exclude", "-C", "filters", "CVS exclude", "Ignore files the way CVS does (.git, *.o, ...)"),
  b("filterFile", "-F", "", "filters", "Per-directory .rsync-filter", "Merge rules from .rsync-filter files"),
  t("path", "excludeFrom", "--exclude-from", "filters", "Exclude from file", "Read exclude patterns from this file"),
  t("path", "includeFrom", "--include-from", "filters", "Include from file", "Read include patterns from this file"),
  t("path", "filesFrom", "--files-from", "filters", "Files from", "Read the list of source files from this file"),
  b("from0", "--from0", "-0", "filters", "NUL separated lists", "Lists in *-from files are separated by NUL"),
  b("safeNames", "", "", "filters", "Safe file names", "Names FAT/exFAT/NTFS can't store get look-alike characters (a:b → a：b, “end.” → “end．”); copying back restores the originals. Unchanged files are still skipped on the next run"),

  // ---- connection
  t("text", "rsh", "", "connection", "Remote shell", "Command used for host:path (default ssh)", { placeholder: "ssh" }),
  t("number", "sshPort", "", "connection", "SSH port", "Port for the remote shell (0 = default)", { min: 0, max: 65535 }),
  t("path", "sshIdentity", "", "connection", "SSH identity file", "Private key for the remote shell"),
  t("text", "sshOptions", "", "connection", "Extra SSH options", "Added to the remote shell command", { placeholder: "-o Compression=no" }),
  t("text", "rsyncPath", "--rsync-path", "connection", "Remote rsync", "Program to run on the remote side", { placeholder: "/usr/bin/rsync" }),
  b("compress", "--compress", "-z", "connection", "Compress", "Compress file data during the transfer"),
  t("choice", "compressChoice", "--compress-choice", "connection", "Compression", "Compression algorithm",
    { choices: ["", "zstd", "lz4", "zlibx", "zlib", "none"] }),
  t("number", "compressLevel", "--compress-level", "connection", "Compression level", "0 = unset", { min: 0, max: 22 }),
  t("number", "compressThreads", "--compress-threads", "connection", "Compression threads", "0 = unset", { min: 0, max: 64 }),
  t("text", "skipCompress", "--skip-compress", "connection", "Skip compress", "Suffixes not to compress, separated by /", { placeholder: "gz/jpg/mp4" }),
  t("steps", "bwlimit", "--bwlimit", "connection", "Bandwidth limit", "Limit socket I/O", { steps: BW_STEPS }),
  t("number", "timeout", "--timeout", "connection", "I/O timeout (s)", "0 = no timeout", { min: 0, max: 86400 }),
  t("number", "contimeout", "--contimeout", "connection", "Daemon connect timeout (s)", "0 = unset", { min: 0, max: 3600 }),
  t("number", "port", "--port", "connection", "Daemon port", "Port for host::module (0 = default)", { min: 0, max: 65535 }),
  t("text", "address", "--address", "connection", "Bind address", "Local address for daemon connections"),
  t("path", "passwordFile", "--password-file", "connection", "Daemon password file", "Read the daemon password from this file"),
  t("path", "earlyInput", "--early-input", "connection", "Daemon early input", "File sent to the daemon's early exec script"),
  b("noMotd", "--no-motd", "", "connection", "No MOTD", "Suppress the daemon message of the day"),
  t("choice", "ipVersion", "", "connection", "IP version", "Prefer IPv4 or IPv6",
    { choices: ["", "4", "6"], flags: { "4": "--ipv4", "6": "--ipv6" } }),
  t("text", "sockopts", "--sockopts", "connection", "Socket options", "Custom TCP options"),
  b("blockingIo", "--blocking-io", "", "connection", "Blocking I/O", "Use blocking I/O for the remote shell"),
  b("secludedArgs", "--secluded-args", "-s", "connection", "Secluded args", "Send arguments over the protocol"),
  b("oldArgs", "--old-args", "", "connection", "Old args", "Disable the modern argument protection"),
  t("text", "iconv", "--iconv", "connection", "Charset conversion", "Convert file name charsets", { placeholder: "utf8,iso88591" }),
  t("number", "protocol", "--protocol", "connection", "Protocol version", "Force an older protocol (0 = auto)", { min: 0, max: 32 }),
  t("list", "remoteOption", "--remote-option", "connection", "Remote-only options", "Sent to the remote side only (one per line)"),
  t("number", "stopAfter", "--stop-after", "connection", "Stop after (min)", "Stop rsync after this many minutes (0 = unset)", { min: 0, max: 100000 }),
  t("text", "stopAt", "--stop-at", "connection", "Stop at", "Stop at this time", { placeholder: "y-m-dTh:m" }),

  // ---- output & batch
  t("steps", "verbose", "--verbose", "output", "Verbosity", "Repeat -v for more detail", { steps: [0, 1, 2, 3, 4] }),
  b("quiet", "--quiet", "-q", "output", "Quiet", "Suppress non-error messages"),
  b("humanReadable", "--human-readable", "-h", "output", "Human readable", "Numbers like 1.2M"),
  b("eightBit", "--8-bit-output", "-8", "output", "8-bit output", "Leave high-bit characters unescaped"),
  t("text", "info", "--info", "output", "Info flags", "Fine-grained information", { placeholder: "stats2,misc2,flist0" }),
  t("text", "debug", "--debug", "output", "Debug flags", "Fine-grained debug output", { placeholder: "del2,filter" }),
  t("choice", "stderrMode", "--stderr", "output", "stderr mode", "Where messages go",
    { choices: ["", "errors", "all", "client"] }),
  t("text", "outFormat", "--out-format", "output", "Output format", "Format for updates", { placeholder: "%i %n%L" }),
  t("path", "logFile", "--log-file", "output", "Log file", "Log what rsync does to this file"),
  t("text", "logFileFormat", "--log-file-format", "output", "Log file format", "Format for log file updates"),
  b("listOnly", "--list-only", "", "output", "List only", "List the source files instead of copying"),
  t("path", "writeBatch", "--write-batch", "output", "Write batch", "Record the update into this batch file"),
  t("path", "onlyWriteBatch", "--only-write-batch", "output", "Only write batch", "Write the batch without updating the destination"),
  t("path", "readBatch", "--read-batch", "output", "Read batch", "Apply a recorded batch file to the destination"),

  // ---- safety & expert
  b("insecureLinks", "--insecure-links", "", "safety", "Insecure links", "Follow attacker-owned symlinks in operator paths"),
  t("path", "confineRoot", "--confine-root", "safety", "Confine root", "Refuse operator paths resolving outside this directory"),
  b("trustSender", "--trust-sender", "", "safety", "Trust sender", "Trust the remote sender's file list"),
  t("size", "maxAlloc", "--max-alloc", "safety", "Max allocation", "Limit for memory allocations", { placeholder: "e.g. 2G" }),
  t("number", "checksumSeed", "--checksum-seed", "safety", "Checksum seed", "Block and file checksum seed (0 = default)", { min: 0, max: 2147483647 }),
  b("oldDirs", "--old-dirs", "", "safety", "Old dirs", "Like --dirs when talking to an old rsync")
]

var BY_KEY = (function() {
  var m = {}
  for (var i = 0; i < CATALOG.length; i++) m[CATALOG[i].key] = CATALOG[i]
  return m
})()

var FILTER_TYPES = ["exclude", "include", "protect", "risk", "hide", "show", "merge", "dir-merge", "clear"]

var PRESETS = [
  { id: "copy", label: "Copy", hint: "Archive copy, keeps extra files on the destination", opts: { archive: true } },
  { id: "mirror", label: "Mirror", hint: "Exact mirror incl. hard links, ACLs, xattrs; deletes extras", opts: { archive: true, hardLinks: true, acls: true, xattrs: true, delete: true } },
  { id: "update", label: "Update", hint: "Archive copy that never overwrites newer files", opts: { archive: true, update: true } },
  { id: "move", label: "Move", hint: "Archive copy, then remove the source files", opts: { archive: true, removeSourceFiles: true } }
]

// FAT/exFAT/NTFS store no Unix metadata: presets written to such a drive leave
// it out, or every run reports all files as changed (and xattrs fail).
// Choices layered on top of a preset (Easy mode: thoroughness, safety copy,
// connection): they don't make a job "custom" and survive a preset change.
var MODIFIER_KEYS = ["checksum", "backup", "backupDir", "partial", "compress", "bwlimit"]

var LIMITED_FS_OFF = ["perms", "owner", "group", "links", "devices", "specials"]
var LIMITED_FS_DROP = ["hardLinks", "acls", "xattrs"]

function presetOpts(preset, limitedFs) {
  var o = {}
  for (var k in preset.opts) o[k] = preset.opts[k]
  if (!limitedFs) return o
  LIMITED_FS_DROP.forEach(function(k) { delete o[k] })
  LIMITED_FS_OFF.forEach(function(k) { if (impliedByArchive(o, k)) o[k] = false; else delete o[k] })
  return o
}

// { id, limitedFs } of the preset (plain or adapted) the behaviour options
// match, id "custom" when none does. Connection, output and filter options
// don't count.
function matchPreset(opts) {
  var behaviour = {}
  for (var k in opts || {}) {
    var def = BY_KEY[k]
    if (def && def.group !== "connection" && def.group !== "output" && def.group !== "filters" && MODIFIER_KEYS.indexOf(k) < 0) behaviour[k] = opts[k]
  }
  var key = function(o) { return JSON.stringify(o, Object.keys(o).sort()) }
  for (var i = 0; i < PRESETS.length; i++) {
    if (key(presetOpts(PRESETS[i], false)) === key(behaviour)) return { id: PRESETS[i].id, limitedFs: false }
    if (key(presetOpts(PRESETS[i], true)) === key(behaviour)) return { id: PRESETS[i].id, limitedFs: true }
  }
  return { id: "custom", limitedFs: false }
}

var EXIT_CODES = {
  0: "Success",
  1: "Syntax or usage error",
  2: "Protocol incompatibility",
  3: "Errors selecting input/output files or directories",
  4: "Requested action not supported",
  5: "Error starting client-server protocol",
  6: "Daemon unable to append to log file",
  10: "Error in socket I/O",
  11: "Error in file I/O",
  12: "Error in rsync protocol data stream",
  13: "Errors with program diagnostics",
  14: "Error in IPC code",
  20: "Stopped (received SIGUSR1 or SIGINT)",
  21: "Some error returned by waitpid()",
  22: "Error allocating core memory buffers",
  23: "Partial transfer due to error",
  24: "Partial transfer due to vanished source files",
  25: "The --max-delete limit stopped deletions",
  30: "Timeout in data send/receive",
  35: "Timeout waiting for daemon connection",
  127: "rsync or the remote shell was not found",
  255: "Remote shell connection failed"
}

function exitText(code) {
  return EXIT_CODES[code] !== undefined ? EXIT_CODES[code] : ("Exit code " + code)
}

// ok | partial | failed | stopped
// changed: number of itemized changes; code 23 without any is a plain failure
function exitStatus(code, stopped, changed) {
  if (stopped) return "stopped"
  if (code === 0) return "ok"
  if (code === 23 && changed === 0) return "failed"
  if (code === 23 || code === 24 || code === 25) return "partial"
  return "failed"
}

function get(opts, key) {
  var def = BY_KEY[key]
  var v = opts ? opts[key] : undefined
  if (v !== undefined && v !== null) return v
  if (!def) return undefined
  if (def.type === "bool") return false
  if (def.type === "number" || def.type === "steps") return 0
  return ""
}

// Effective switch state: archive-implied options read as on unless the user
// turned them off explicitly.
function isOn(opts, key) {
  var v = opts ? opts[key] : undefined
  if (v === true) return true
  if (v === false) return false
  return impliedByArchive(opts, key)
}

function impliedByArchive(opts, key) {
  return !!(opts && opts.archive === true && ARCHIVE_IMPLIES.indexOf(key) >= 0)
}

function isModified(opts, key) {
  var v = opts ? opts[key] : undefined
  if (v === undefined || v === null || v === "" || v === 0) return false
  if (v === false) return impliedByArchive(opts, key)
  return true
}

function formatRate(kib) {
  if (!kib) return "Unlimited"
  if (kib >= 1024) return (kib / 1024) + " MiB/s"
  return kib + " KiB/s"
}

// Split a command line like a POSIX shell would for quoting purposes only:
// no expansion, no globbing, nothing is executed.
function splitArgs(s) {
  var out = [], cur = "", has = false, q = ""
  s = String(s || "")
  for (var i = 0; i < s.length; i++) {
    var c = s[i]
    if (q === "'") { if (c === "'") q = ""; else cur += c; continue }
    if (q === '"') {
      if (c === '"') q = ""
      else if (c === "\\" && i + 1 < s.length && '"\\$`'.indexOf(s[i + 1]) >= 0) cur += s[++i]
      else cur += c
      continue
    }
    if (c === "'" || c === '"') { q = c; has = true; continue }
    if (c === "\\" && i + 1 < s.length) { cur += s[++i]; has = true; continue }
    if (/\s/.test(c)) { if (has) { out.push(cur); cur = ""; has = false } continue }
    cur += c; has = true
  }
  if (q) return null
  if (has) out.push(cur)
  return out
}

function quote(arg) {
  var s = String(arg)
  if (s !== "" && /^[A-Za-z0-9_@%+=:,.\/-]+$/.test(s)) return s
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

function commandLine(argv) {
  return argv.map(quote).join(" ")
}

// Inline passwords that can only come from the free-form "Remote shell",
// "Extra SSH options" and "Extra arguments" fields. The history keeps its
// command line for months and outlives any "Forget password", so what is
// stored there goes through this first. It cannot protect the job itself:
// a secret typed into a job field is saved with the profile and the last job.
function redactSecrets(text) {
  return String(text)
    .replace(/(\bsshpass\s+-p\s*)(\S+)/g, "$1<hidden>")
    .replace(/(\b[Pp]ass(?:word|phrase)?\s*=\s*)(\S+)/g, "$1<hidden>")
    .replace(/(:\/\/[^\s:@\/]+:)([^\s@\/]+)(@)/g, "$1<hidden>$3")
}

// What redactSecrets left behind: a job loaded from the history can't run
// until the password is typed in again.
var REDACTED_RE = /\bsshpass\s+-p\s*<hidden>|\b[Pp]ass(?:word|phrase)?\s*=\s*<hidden>|:\/\/[^\s:@\/]+:<hidden>@/

// The job as the history keeps it. The history also stores the job itself (to
// run it again), so its free-form fields get the same treatment as the command
// line; otherwise the password would sit in history.json anyway.
function redactJob(job) {
  var j = JSON.parse(JSON.stringify(job || {}))
  if (typeof j.extra === "string") j.extra = redactSecrets(j.extra)
  for (var k in j.opts || {}) if (typeof j.opts[k] === "string") j.opts[k] = redactSecrets(j.opts[k])
  return j
}

var SIZE_RE = /^\d+(\.\d+)?([bkmgtBKMGT]([iI]?[bB])?)?([+-]1)?$/

function isRemote(path) {
  var p = String(path || "")
  if (/^rsync:\/\//.test(p)) return true
  // host:path or user@host:path; a colon after the first slash is a local path
  var colon = p.indexOf(":")
  if (colon <= 0) return false
  var slash = p.indexOf("/")
  return slash < 0 || colon < slash
}

// "user@host:path" -> { user, host, path }; null for local or daemon paths
function sshTarget(path) {
  var p = String(path || "")
  if (!isRemote(p) || /^rsync:\/\//.test(p) || /^[^\/]*::/.test(p)) return null
  var m = /^(?:([^@\/:]+)@)?(\[[^\]]+\]|[^:\/]+):(.*)$/.exec(p)
  return m ? { user: m[1] || "", host: m[2], path: m[3] } : null
}

function localArg(path) {
  var p = String(path || "")
  if (p.charAt(0) === "-") return "./" + p
  return p
}

function rshCommand(opts, defaultRsh) {
  var base = String(get(opts, "rsh") || "").trim()
  var port = Number(get(opts, "sshPort")) || 0
  var identity = String(get(opts, "sshIdentity") || "").trim()
  var extra = String(get(opts, "sshOptions") || "").trim()
  if (!base && !port && !identity && !extra) return ""
  var parts = [base || defaultRsh || "ssh"]
  if (port) parts.push("-p " + port)
  if (identity) parts.push("-i " + quote(identity))
  if (extra) parts.push(extra)
  return parts.join(" ")
}

// Flags in argv (catalog or extra arguments) that delete or move data
function destructiveFlags(argv) {
  return argv.filter(function(a) {
    return /^--(del|delete|delete-(before|during|delay|after|excluded|missing-args)|remove-(source|sent)-files)(=|$)/.test(String(a))
  })
}

function deletesOnReceiver(argv) {
  return argv.some(function(a) { return /^--(del|delete|delete-(before|during|delay|after|excluded|missing-args))(=|$)/.test(String(a)) })
}

// Flags that delete on the sender: the source loses files, so the source needs
// the same protection the destination gets from deletesOnReceiver.
function removesSource(argv) {
  return argv.some(function(a) { return /^--remove-(source|sent)-files(=|$)/.test(String(a)) })
}

// Lexical normalisation: no symlink resolution, just //, . and ..
function normalizePath(p) {
  var abs = p.charAt(0) === "/"
  var out = []
  var parts = p.split("/")
  for (var i = 0; i < parts.length; i++) {
    var seg = parts[i]
    if (seg === "" || seg === ".") continue
    if (seg === "..") { if (out.length) out.pop(); continue }
    out.push(seg)
  }
  return (abs ? "/" : "") + out.join("/")
}

function isInside(child, parent) {
  if (parent === "/") return child !== "/"
  return child.indexOf(parent + "/") === 0
}

// Folders that hold other people's or the system's data: never a target for
// deleting on the receiver, and never a source to remove files from
var PROTECTED_DIRS = ["/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/media", "/mnt", "/opt", "/proc",
  "/root", "/run", "/run/media", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var", "/Users"]

// p must be absolute (Locations.absolutePath resolves ~ and relative paths)
function protectedPath(p, home) {
  if (p === "" || p === "/" || p.charAt(0) !== "/") return true
  if (PROTECTED_DIRS.indexOf(p) >= 0 || /^\/run\/media\/[^\/]+$/.test(p)) return true
  var h = home ? normalizePath(home) : ""
  return h !== "" && (p === h || isInside(h, p))
}

// Same for the path behind "host:": "~", "~other", "" and system folders, and
// /home/NAME or /Users/NAME, which is the remote home written out
function protectedRemotePath(p) {
  var rp = normalizePath(String(p).replace(/^~[^\/]*\/?/, ""))
  return rp === "" || rp === "/" || PROTECTED_DIRS.indexOf(rp) >= 0 || /^\/(home|Users)\/[^\/]+$/.test(rp)
}

function checkSafety(src, dst, argv, home, errors, warnings) {
  var srcSsh = sshTarget(src), dstSsh = sshTarget(dst)
  var dash = function(t) { return t && (t.host.charAt(0) === "-" || t.user.charAt(0) === "-") }
  if (dash(srcSsh) || dash(dstSsh)) errors.push("Host and user names can't start with “-”")

  var deleting = deletesOnReceiver(argv)
  if (deleting && dst) {
    if (dstSsh) {
      if (protectedRemotePath(dstSsh.path))
        errors.push("Refusing to delete in the remote home, root or a system folder: choose a subfolder")
    } else if (!isRemote(dst)) {
      if (protectedPath(normalizePath(dst), home))
        errors.push("Refusing to delete in /, your home folder, a folder containing it or a system folder: choose a subfolder")
    }
  }
  // Move (--remove-source-files) empties the source just as --delete empties
  // the destination, so the source gets the same protection.
  if (removesSource(argv) && src) {
    if (srcSsh) {
      if (protectedRemotePath(srcSsh.path))
        errors.push("Refusing to remove files from the remote home, root or a system folder: choose a subfolder")
    } else if (!isRemote(src)) {
      if (protectedPath(normalizePath(src), home))
        errors.push("Refusing to remove files from /, your home folder, a folder containing it or a system folder: choose a subfolder")
    }
  }
  if (src && dst && !isRemote(src) && !isRemote(dst) && src.charAt(0) === "/" && dst.charAt(0) === "/") {
    var s = normalizePath(src), t = normalizePath(dst)
    if (isInside(s, t) && deleting) errors.push("The source lies inside the destination: deleting there would remove the source itself")
    else if (isInside(t, s)) warnings.push("The destination lies inside the source, so it gets copied into itself")
  }
}

// Returns { argv, errors, warnings }. argv excludes the program name and the
// GUI-only flags (progress/stats), which runArgs adds.
function buildArgs(job, defaultRsh) {
  var opts = job.opts || {}
  var argv = [], errors = [], warnings = []
  var i, def, v

  for (i = 0; i < CATALOG.length; i++) {
    def = CATALOG[i]
    v = opts[def.key]
    if (v === undefined || v === null) continue
    if (!def.flag && !def.flags) continue   // composite (rsh parts)

    switch (def.type) {
    case "bool":
      if (v === true && !impliedByArchive(opts, def.key)) argv.push(def.flag)
      else if (v === false && impliedByArchive(opts, def.key)) argv.push(def.flag.replace(/^--/, "--no-"))
      break
    case "number":
      if (v !== "" && Number(v) !== 0) {
        if (!isFinite(Number(v)) || Math.round(Number(v)) !== Number(v)) errors.push(def.label + ": not a whole number")
        else argv.push(def.flag + "=" + Number(v))
      }
      break
    case "steps":
      if (def.key === "verbose") { for (var n = 0; n < Number(v); n++) argv.push("-v") }
      else if (Number(v) > 0) argv.push(def.flag + "=" + Number(v))
      break
    case "size":
      if (String(v).trim() !== "") {
        if (!SIZE_RE.test(String(v).trim())) errors.push(def.label + ": invalid size \"" + v + "\"")
        else argv.push(def.flag + "=" + String(v).trim())
      }
      break
    case "choice":
      if (v === "") break
      if (def.choices.indexOf(String(v)) < 0) { errors.push(def.label + ": unknown value \"" + v + "\""); break }
      argv.push(def.flags ? def.flags[v] : def.flag + "=" + v)
      break
    case "list":
      var lines = String(v).split("\n")
      for (var l = 0; l < lines.length; l++) if (lines[l].trim() !== "") argv.push(def.flag + "=" + lines[l].trim())
      break
    default:
      if (String(v) !== "") argv.push(def.flag + "=" + v)
    }
  }

  var rsh = rshCommand(opts, defaultRsh)
  if (rsh) argv.push("--rsh=" + rsh)

  var filters = job.filters || []
  for (i = 0; i < filters.length; i++) {
    var f = filters[i]
    var pat = String(f.pattern || "")
    if (f.type === "clear") { argv.push("--filter=clear"); continue }
    if (pat.trim() === "") continue
    if (f.type === "exclude") argv.push("--exclude=" + pat)
    else if (f.type === "include") argv.push("--include=" + pat)
    else if (FILTER_TYPES.indexOf(f.type) >= 0) argv.push("--filter=" + f.type + " " + pat)
    else errors.push("Unknown filter rule type: " + f.type)
  }

  var extra = splitArgs(job.extra)
  if (extra === null) errors.push("Extra arguments: unbalanced quotes")
  else for (i = 0; i < extra.length; i++) argv.push(extra[i])

  // ---- consistency checks
  var on = function(k) { return isOn(opts, k) }
  if (on("inplace") && on("delayUpdates")) errors.push("Update in place and Delay updates can't be combined")
  if (on("inplace") && get(opts, "partialDir")) errors.push("Update in place and Partial dir can't be combined")
  if (on("append") && on("appendVerify")) warnings.push("Append verify already includes Append")
  if (on("existing") && on("ignoreExisting")) warnings.push("Only existing + Skip existing transfers nothing")
  if (on("copyLinks") && on("links")) warnings.push("Follow symlinks overrides Symlinks as symlinks")
  if ((on("delete") || get(opts, "deleteMode")) && !on("recursive") && !on("dirs"))
    errors.push("Deleting needs Recursive or Directories")
  if (get(opts, "deleteMode") && !on("delete")) warnings.push("Delete timing implies deleting extraneous files")
  if (on("removeSourceFiles") && on("delete")) warnings.push("Remove source files together with Delete: double-check the paths")
  if (get(opts, "readBatch") && (get(opts, "writeBatch") || get(opts, "onlyWriteBatch")))
    errors.push("Read batch can't be combined with writing a batch")
  if (on("quiet") && Number(get(opts, "verbose")) > 0) warnings.push("Quiet and Verbosity cancel each other")
  var bdirRel = String(get(opts, "backupDir") || "")
  var dstT0 = String(job.dst || "").trim()
  if (on("backup") && bdirRel && on("deleteExcluded")
      && (bdirRel.charAt(0) !== "/" || (!isRemote(dstT0) && isInside(normalizePath(bdirRel), normalizePath(dstT0)))))
    warnings.push("Delete excluded also removes the backups kept inside the destination")
  if (on("crtimes")) warnings.push("Creation times need rsync built with crtimes support and a file system that stores them; otherwise rsync stops with an error")
  if (on("safeNames")) {
    var srcT = String(job.src || "").trim(), dstT = String(job.dst || "").trim()
    if (isRemote(srcT) || isRemote(dstT)) errors.push("Safe file names works with local folders and drives only: turn it off (Options › Filter options) for server paths, or switch to Easy mode, which does it for you")
    var clash = ["relative", "filesFrom", "linkDest", "compareDest", "copyDest", "readBatch", "writeBatch", "onlyWriteBatch", "listOnly"]
      .filter(function(k) { return BY_KEY[k].type === "bool" ? on(k) : !!get(opts, k) })
    if (clash.length) errors.push("Safe file names can't be combined with " + clash.map(function(k) { return BY_KEY[k].label }).join(", "))
    var bdir = String(get(opts, "backupDir") || "")
    if (bdir && bdir.charAt(0) !== "/") errors.push("Safe file names needs an absolute Backup dir")
  }

  var line = commandLine(argv)
  if (REDACTED_RE.test(line))
    errors.push("The history does not keep passwords: type the password into the command again (Options › Connection or Extra arguments)")
  else if (redactSecrets(line) !== line)
    warnings.push("There is a password in the command. It is saved in plain text with the profile and the last job (only the history hides it) — “Remember in keyring” or a Daemon password file keeps it out of the files.")

  var src = String(job.src || "").trim()
  var dst = String(job.dst || "").trim()
  checkSafety(src, dst, argv, String(job.home || ""), errors, warnings)
  var listOnly = on("listOnly")
  var readBatch = !!get(opts, "readBatch")
  if (!src && !readBatch) errors.push("Choose a source")
  if (!dst && !listOnly) errors.push("Choose a destination")
  if (src && dst && src.replace(/\/+$/, "") === dst.replace(/\/+$/, "")) errors.push("Source and destination are the same")
  if (isRemote(src) && isRemote(dst)) errors.push("Source and destination can't both be remote")
  // "a/Nextcloud" -> "b/Nextcloud" without a trailing slash nests the folder
  var base = function(p) { return p.replace(/\/+$/, "").replace(/^.*[\/:]/, "") }
  if (src && dst && !/\/$/.test(src) && base(src) !== "" && base(src) === base(dst))
    warnings.push("This creates " + base(dst) + "/" + base(src) + " inside the destination. To sync into " + base(dst) + " itself, turn on “Copy the contents”.")

  return { argv: argv, errors: errors, warnings: warnings }
}

// Full argv for a run: GUI flags for progress/itemize/stats, then the paths.
// {date} in the backup dir: one folder per run
function expandDate(text, now) {
  var d = new Date(now === undefined ? Date.now() : now)
  var p = function(n) { return (n < 10 ? "0" : "") + n }
  var stamp = d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + "_" + p(d.getHours()) + p(d.getMinutes())
  return String(text).split("{date}").join(stamp)
}

function runArgs(job, defaultRsh, dryRun, now) {
  if (job.opts && typeof job.opts.backupDir === "string" && job.opts.backupDir.indexOf("{date}") >= 0) {
    job = Object.assign({}, job)
    job.opts = Object.assign({}, job.opts, { backupDir: expandDate(job.opts.backupDir, now) })
  }
  var built = buildArgs(job, defaultRsh)
  var argv = ["rsync"]
  if (dryRun) argv.push("--dry-run")
  argv = argv.concat(built.argv)
  argv.push("--info=progress2", "--itemize-changes", "--stats", "--outbuf=L")
  var src = String(job.src || "").trim()
  var dst = String(job.dst || "").trim()
  if (src || dst) argv.push("--")
  if (src) argv.push(localArg(src))
  if (dst) argv.push(localArg(dst))
  return { argv: argv, errors: built.errors, warnings: built.warnings }
}

// ---- output parsing

var PROGRESS_RE = /^\s*([\d,.]+[KMGTP]?)\s+(\d{1,3})%\s+([\d,.]+[kKMGTP]?B\/s)\s+(\d+:\d{2}:\d{2})(?:\s+\(xfr#(\d+),\s+(?:ir|to)-chk=(\d+)\/(\d+)\))?/

function parseProgress(line) {
  var m = PROGRESS_RE.exec(String(line))
  if (!m) return null
  return {
    bytes: m[1], percent: Number(m[2]), speed: m[3], eta: m[4],
    transferred: m[5] ? Number(m[5]) : -1,
    toCheck: m[6] ? Number(m[6]) : -1, total: m[7] ? Number(m[7]) : -1
  }
}

function formatClock(sec) {
  var p = function(n) { return (n < 10 ? "0" : "") + n }
  return Math.floor(sec / 3600) + ":" + p(Math.floor(sec / 60) % 60) + ":" + p(sec % 60)
}

// A dry run moves no data, so rsync's byte percentage, rate and ETA are
// meaningless (0 % at "9 GB/s", ETA 0:00:00). Its file-list counter is real:
// take the progress from the files checked and the ETA from how long that took.
function scanProgress(progress, elapsedMs) {
  if (!progress || !(progress.total > 0) || progress.toCheck < 0) return null
  var done = Math.max(0, progress.total - progress.toCheck)
  var percent = Math.max(0, Math.min(100, Math.floor(done * 100 / progress.total)))
  var eta = ""
  // The file list still grows while rsync recurses, so an early estimate would
  // only jump around.
  if (done > 50 && elapsedMs > 3000 && done < progress.total)
    eta = formatClock(Math.round(elapsedMs * (progress.total - done) / done / 1000))
  return { done: done, total: progress.total, percent: percent, eta: eta,
           rate: elapsedMs > 1000 ? Math.round(done / (elapsedMs / 1000)) : 0 }
}

var ITEM_RE = /^([<>ch.*][fdLDS][^\s]{9}) (.+)$/

// { kind: "new"|"update"|"delete"|"attr"|"other", path, code }
function parseItem(line) {
  var s = String(line)
  var del = /^\*deleting\s+(.+)$/.exec(s)
  if (del) return { kind: "delete", path: del[1], code: "*deleting" }
  var m = ITEM_RE.exec(s)
  if (!m) return null
  var code = m[1]
  var kind = code.indexOf("+++++++") >= 0 ? "new"
    : (code[0] === "<" || code[0] === ">") ? "update"
    : code[0] === "c" ? "new"
    : code[0] === "." ? "attr" : "other"
  return { kind: kind, path: m[2], code: code }
}

function parseNumber(s) {
  return Number(String(s).replace(/,/g, "")) || 0
}

// Collects --stats lines into an object; returns true when the line was a stat.
function parseStat(line, stats) {
  var s = String(line)
  var m
  if ((m = /^Number of files: ([\d,]+)/.exec(s))) { stats.files = parseNumber(m[1]); return true }
  if ((m = /^Number of created files: ([\d,]+)/.exec(s))) { stats.created = parseNumber(m[1]); return true }
  if ((m = /^Number of deleted files: ([\d,]+)/.exec(s))) { stats.deleted = parseNumber(m[1]); return true }
  if ((m = /^Number of regular files transferred: ([\d,]+)/.exec(s))) { stats.transferred = parseNumber(m[1]); return true }
  if ((m = /^Total file size: ([\d,.]+[KMGTP]?)/.exec(s))) { stats.totalSize = m[1]; return true }
  if ((m = /^Total transferred file size: ([\d,.]+[KMGTP]?)/.exec(s))) { stats.transferredSize = m[1]; return true }
  if ((m = /^sent ([\d,.]+[KMGTP]?) bytes\s+received ([\d,.]+[KMGTP]?) bytes\s+([\d,.]+[KMGTP]?) bytes\/sec/.exec(s))) {
    stats.sent = m[1]; stats.received = m[2]; stats.rate = m[3]; return true
  }
  if (/^(Number of|Total |Literal data|Matched data|File list |total size is)/.test(s)) return true
  return false
}

