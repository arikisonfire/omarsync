import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Options.js" as Options
import "Locations.js" as Locations
import "Easy.js" as Easy

// omaRSYNC, an rsync front end: bar icon (a ring that fills with progress,
// pulses when SSH needs an answer) and a popup with Job · Options · Filters ·
// History · Log.
Panel {
  id: root
  moduleName: "io.github.arikisonfire.rsync"
  ipcTarget: "io.github.arikisonfire.rsync"

  readonly property string appName: "omaRSYNC"

  // ------------------------------------------------------------------ setup
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy-rsync"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy-rsync"
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string helper: pluginDir + "askpass.sh"
  readonly property string picker: pluginDir + "pick-path.py"
  readonly property string safeNamesHelper: pluginDir + "safenames.py"

  readonly property bool notify: root.setting("notify", true) !== false
  readonly property string defaultRsh: String(root.setting("defaultRsh", "ssh") || "ssh")
  readonly property int historyLimit: Math.max(10, Math.min(1000, Number(root.setting("historyLimit", 200)) || 200))

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.45)

  function glyph(cp) { return String.fromCodePoint(cp) }
  readonly property var icons: ({
    sync: glyph(0xF04E6), syncAlert: glyph(0xF04E7), folder: glyph(0xF024B), file: glyph(0xF0214),
    history: glyph(0xF02DA), drive: glyph(0xF02CA), server: glyph(0xF048B), laptop: glyph(0xF0322),
    swap: glyph(0xF04E1), copy: glyph(0xF018F), trash: glyph(0xF01B4), up: glyph(0xF005D),
    down: glyph(0xF0045), close: glyph(0xF0156), plus: glyph(0xF0415), key: glyph(0xF0306),
    lock: glyph(0xF033E), alert: glyph(0xF0026), check: glyph(0xF012C), eye: glyph(0xF0208),
    eyeOff: glyph(0xF0209), chevronDown: glyph(0xF0140), chevronRight: glyph(0xF0142), search: glyph(0xF0349),
    play: glyph(0xF040A), stop: glyph(0xF04DB), connect: glyph(0xF0318)
  })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    // history and profiles reveal paths and hosts: keep them private
    Quickshell.execDetached(["sh", "-c", 'umask 077; mkdir -p -- "$1" "$2" && chmod 700 -- "$1" "$2"', "mkdir", root.configDir, root.stateDir])
    tightenFiles.restart()
    refreshMounts()
    toolCheck.running = true
  }

  onOpenedChanged: if (opened) { refreshMounts(); sshConfig.reload(); if (!toolCheck.running) toolCheck.running = true }

  // ------------------------------------------------------------------ tools
  // Checked at start and on every open, so installing a missing tool needs no
  // shell restart. rsync 3.1 brought --info=progress2, which the UI reads.
  property string rsyncVersion: ""
  property string rsyncProblem: ""
  property bool keyringAvailable: true
  Process {
    id: toolCheck
    command: ["sh", "-c", 'rsync --version 2>/dev/null | head -n 1; command -v secret-tool >/dev/null 2>&1 && echo "secret-tool ok"; exit 0']
    stdout: StdioCollector { id: toolCheckOut; waitForEnd: true }
    onExited: {
      var text = toolCheckOut.text
      var m = /rsync\s+version\s+v?(\d+)\.(\d+)(?:\.(\d+))?/.exec(text)
      root.rsyncVersion = m ? m[1] + "." + m[2] + (m[3] !== undefined ? "." + m[3] : "") : ""
      root.rsyncProblem = !m ? "rsync is not installed: install the rsync package, then reopen this popup"
        : Number(m[1]) * 1000 + Number(m[2]) < 3001 ? "rsync " + root.rsyncVersion + " is too old: " + root.appName + " needs rsync 3.1 or newer"
        : ""
      root.keyringAvailable = /secret-tool ok/.test(text)
    }
  }

  // ------------------------------------------------------------------ job
  property string tab: "job"
  // "easy": plain questions on the Job tab; "expert": every option. Both edit the same job.
  property string uiMode: "easy"
  readonly property bool expert: uiMode === "expert"
  function setUiMode(mode) {
    root.uiMode = mode === "expert" ? "expert" : "easy"
    Qt.callLater(root.adaptSafeNames)
    if (!root.expert && (root.tab === "options" || root.tab === "filters")) root.tab = "job"
    stateSave.restart()
  }
  property var job: defaultJob()
  property string profileName: ""
  property bool showCommand: false     // Easy mode: command preview unfolded

  function defaultJob() {
    return { src: "", dst: "", srcAnchor: null, dstAnchor: null, opts: { archive: true }, filters: [], extra: "" }
  }

  function clone(v) { return JSON.parse(JSON.stringify(v === undefined ? null : v)) }

  function patchJob(changes) {
    var j = Object.assign({}, root.job)
    for (var k in changes) j[k] = changes[k]
    root.job = j
    root.confirmDestructive = false
    stateSave.restart()
  }

  function setOpt(key, value) {
    var o = Object.assign({}, root.job.opts)
    var def = Options.BY_KEY[key]
    if (def && def.type === "bool") {
      if (value === Options.impliedByArchive(o, key)) delete o[key]
      else o[key] = value
    } else if (value === undefined || value === null || value === "" || value === 0) {
      delete o[key]
    } else {
      o[key] = value
    }
    patchJob({ opts: o })
  }

  // On a FAT/exFAT/NTFS destination presets leave out what the drive can't
  // store and turn on safe file names.
  function applyPreset(preset) {
    var o = {}
    // keep connection and output settings, replace behaviour
    for (var k in root.job.opts) {
      var def = Options.BY_KEY[k]
      if (def && (def.group === "connection" || def.group === "output" || def.group === "filters" || Options.MODIFIER_KEYS.indexOf(k) >= 0)) o[k] = root.job.opts[k]
    }
    var p = Options.presetOpts(preset, root.dstFs !== "")
    for (var key in p) o[key] = p[key]
    if (root.dstFs !== "" && !Options.isRemote(root.runJob.src)) o.safeNames = true
    else if (root.srcFs === "" && root.presetMatch.limitedFs) delete o.safeNames   // was added for the old drive
    patchJob({ opts: o })
  }

  readonly property var presetMatch: Options.matchPreset(job.opts)
  readonly property string activePreset: presetMatch.id

  // A preset job whose destination moves to or away from such a drive follows
  // along (e.g. Mirror picked before the destination, or a loaded profile).
  onDstFsChanged: Qt.callLater(root.adaptToLocation)
  onMountsLoadedChanged: Qt.callLater(root.adaptToLocation)
  onJobChanged: Qt.callLater(root.adaptSafeNames)
  function adaptToLocation() {
    adaptPresetToDestination()
    adaptSafeNames()
  }

  // Easy mode has no switch for safe file names, so it keeps them right: on for
  // a local job writing to FAT/exFAT/NTFS, off otherwise — with a server path
  // they can't work at all and would only block the run.
  function adaptSafeNames() {
    if (root.expert || !root.mountsLoaded) return
    var on = Options.isOn(root.job.opts, "safeNames")
    var remote = Options.isRemote(root.runJob.src) || Options.isRemote(root.runJob.dst)
    if (remote) {
      if (on) {
        root.setOpt("safeNames", false)
        root.flash("Safe file names turned off: they only work between local folders and drives")
      }
      return
    }
    var needed = root.dstFs !== "" || root.srcFs !== ""
    // A disconnected drive says nothing about its file system: leave it alone.
    if (needed !== on && (needed || (root.dstInfo.connected && !Locations.unmountedMedia(root.runJob.dst, root.mounts, root.home))))
      root.setOpt("safeNames", needed)
  }
  function adaptPresetToDestination() {
    if (!root.mountsLoaded || root.presetMatch.id === "custom") return
    var limited = root.dstFs !== ""
    if (limited === root.presetMatch.limitedFs) return
    // A disconnected drive says nothing about its file system.
    if (!limited && (!root.dstInfo.connected || Locations.unmountedMedia(root.runJob.dst, root.mounts, root.home))) return
    for (var i = 0; i < Options.PRESETS.length; i++)
      if (Options.PRESETS[i].id === root.presetMatch.id) root.applyPreset(Options.PRESETS[i])
  }

  function setPath(which, text) {
    var changes = {}
    changes[which] = text
    changes[which + "Anchor"] = Locations.anchorFor(text, root.mounts, root.home)
    patchJob(changes)
  }

  function swapPaths() {
    patchJob({ src: job.dst, dst: job.src, srcAnchor: job.dstAnchor, dstAnchor: job.srcAnchor })
  }

  // "Copy contents" = trailing slash on a local or remote source directory
  readonly property bool contentsOnly: /\/$/.test(job.src)
  function setContentsOnly(on) {
    var s = String(job.src || "")
    if (!s) return
    var next = on ? s.replace(/\/*$/, "/") : s.replace(/\/+$/, "")
    if (next === "") next = "/"
    patchJob({ src: next, srcAnchor: job.srcAnchor ? Object.assign({}, job.srcAnchor, { rel: on ? job.srcAnchor.rel.replace(/\/*$/, "/") : job.srcAnchor.rel.replace(/\/+$/, "") }) : null })
  }

  // Resolved view used for running: ~ expanded, drives looked up by UUID.
  function resolvedPath(path, anchor) {
    if (anchor && anchor.uuid) return Locations.resolveAnchor(anchor, root.mounts)
    return Locations.absolutePath(path, root.home)
  }

  readonly property var srcInfo: Locations.describe(job.src, job.srcAnchor, mounts, home)
  readonly property var dstInfo: Locations.describe(job.dst, job.dstAnchor, mounts, home)
  readonly property var runJob: {
    var dst = resolvedPath(job.dst, job.dstAnchor) || job.dst
    var opts = job.opts
    // A relative backup dir lives inside the destination; spelled out for a
    // local one, because safe file names needs it absolute.
    var bdir = String(opts.backupDir || "")
    if (bdir && bdir.charAt(0) !== "/" && dst.charAt(0) === "/" && !Options.isRemote(dst))
      opts = Object.assign({}, opts, { backupDir: dst.replace(/\/+$/, "") + "/" + bdir })
    var src = resolvedPath(job.src, job.srcAnchor) || job.src
    // FAT32 keeps times in 2 s steps: without a tolerance every run copies all
    opts = Locations.fatTimeOpts(opts, src, dst, mounts, home)
    return { src: src, dst: dst,
             opts: opts, filters: job.filters, extra: job.extra, home: home }
  }
  readonly property var easyAnswers: Easy.read(job)
  function easyAnswer(key, value) {
    patchJob(Easy.withAnswer(root.job, key, value))
  }
  function easyGoal(id) {
    for (var i = 0; i < Options.PRESETS.length; i++) if (Options.PRESETS[i].id === id) root.applyPreset(Options.PRESETS[i])
  }
  readonly property var built: Options.runArgs(runJob, defaultRsh, false)
  readonly property var blockers: {
    var list = built.errors.slice()
    if (rsyncProblem) list.unshift(rsyncProblem)
    if (!srcInfo.connected) list.push("Source drive “" + job.srcAnchor.label + "” is not connected")
    if (!dstInfo.connected) list.push("Destination drive “" + job.dstAnchor.label + "” is not connected")
    if (!mountsLoaded && (mediaPath(job.src) || mediaPath(job.dst))) list.push("Checking drives …")
    else {
      var ms = job.srcAnchor ? "" : Locations.unmountedMedia(job.src, mounts, home)
      var md = job.dstAnchor ? "" : Locations.unmountedMedia(job.dst, mounts, home)
      if (ms) list.push("Nothing is mounted at " + ms + " (source)")
      if (md) list.push("Nothing is mounted at " + md + " (destination)")
    }
    if (runJob.dst && !Options.isRemote(runJob.dst) && Options.deletesOnReceiver(built.argv)) {
      var inner = mountsInside(runJob.dst)
      if (inner.length) list.push("Refusing to delete: " + inner[0] + " is mounted inside the destination")
    }
    return list
  }
  // A drive mounted below a deleting local destination would be emptied too.
  // points: further mount points (findmnt) on top of the lsblk drives
  function mountsInside(dst, points) {
    var d = Options.normalizePath(dst)
    return root.mounts.map(function(m) { return m.mount }).concat(points || [])
      .filter(function(p) { return Options.isInside(p, d) })
  }
  function mediaPath(p) { return !Options.isRemote(p) && /^(\/run)?\/media\//.test(Locations.expandHome(p, root.home)) }
  // Safe file names: back to real names when only the source is on FAT/exFAT/NTFS
  readonly property string srcFs: Locations.limitedFs(runJob.src, mounts, home)
  readonly property string dstFs: Locations.limitedFs(runJob.dst, mounts, home)
  readonly property string safeDirection: srcFs && !dstFs ? "from" : "to"
  function runArgv(argv) {
    if (!Options.isOn(root.job.opts, "safeNames")) return argv
    return ["python3", root.safeNamesHelper, root.safeDirection].concat(argv)
  }
  // Includes deleting flags typed into Extra arguments
  readonly property bool destructive: Options.destructiveFlags(built.argv).length > 0

  // The SSH side of the job, if any
  readonly property string remotePath: Options.sshTarget(job.src) ? job.src : (Options.sshTarget(job.dst) ? job.dst : "")
  // user@hostname exactly as ssh will use it (resolved with `ssh -G`, so
  // aliases and User/HostName from ~/.ssh/config are applied). Passwords are
  // stored and handed out only for this identity.
  property string keyringTarget: ""
  property string keyringKey: ""     // the sshResolveKey keyringTarget was resolved for
  readonly property string sshResolveKey: remotePath && plainSsh ? JSON.stringify([Options.sshTarget(remotePath), Options.rshCommand(job.opts, defaultRsh)]) : ""
  onSshResolveKeyChanged: {
    root.keyringTarget = ""
    root.keyringKey = ""
    if (root.sshResolveKey) sshResolveTimer.restart()
  }
  function resolveKeyringTarget() {
    if (!root.sshResolveKey) return
    if (sshResolve.running) { sshResolveTimer.restart(); return }
    sshResolve.forKey = root.sshResolveKey
    sshResolve.command = root.sshBaseArgs().concat(["-G", "--", root.sshHostArg()])
    sshResolve.running = true
  }
  Timer {
    id: sshResolveTimer
    interval: 400
    onTriggered: root.resolveKeyringTarget()
  }
  Process {
    id: sshResolve
    property string forKey: ""
    stdout: StdioCollector {
      id: sshResolveOut
      waitForEnd: true
    }
    onExited: function(code) {
      if (forKey !== root.sshResolveKey) return
      var user = "", host = ""
      var lines = sshResolveOut.text.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = /^(user|hostname) (\S+)$/.exec(lines[i])
        if (m && m[1] === "user") user = m[2]
        else if (m) host = m[2]
      }
      root.keyringTarget = code === 0 && user && host ? user + "@" + host : ""
      root.keyringKey = forKey
      root.launchPending()
    }
  }

  // "user@host" of an ssh password prompt ("u@h's password:" or the
  // keyboard-interactive "(u@h) Password:"), else ""
  function passwordPromptTarget(text) {
    var m = /^([^@\s]+)@(\S+)'s password: ?$/.exec(text) || /^\(([^@\s]+)@([^\s)]+)\) [Pp]assword: ?$/.exec(text)
    return m ? m[1] + "@" + m[2] : ""
  }
  // The key file of ssh's "Enter passphrase for key '/path':", else "". Only
  // ssh on this computer asks like that: a server's questions start with "(u@h)".
  function passphrasePromptKey(text) {
    var m = /^Enter passphrase for key '(\/[^']{1,99})': ?$/.exec(text)
    return m ? m[1] : ""
  }
  // ssh-keygen choosing the passphrase of a key it is creating
  function newKeyPrompt(text) {
    return /\(empty for no passphrase\): ?$|^Enter same passphrase again: ?$/.test(text)
  }
  function fileName(path) { return String(path).replace(/^.*\//, "") }
  readonly property bool plainSsh: {
    var parts = Options.splitArgs(String(job.opts.rsh || defaultRsh))
    return /(^|\/)ssh$/.test(parts && parts[0] || "")
  }

  // ------------------------------------------------------------------ persisted state
  property var profiles: []
  property var history: []
  property bool stateLoaded: false

  FileView {
    id: stateFile
    path: root.configDir + "/state.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (Array.isArray(d.profiles)) root.profiles = d.profiles.filter(function(p) { return p && p.name && p.job })
        if (d.last && typeof d.last === "object") root.job = root.sanitizeJob(d.last)
        if (d.ui && d.ui.mode === "expert") root.uiMode = "expert"
      } catch (e) { console.warn("rsync: state.json unreadable, starting fresh") }
      root.stateLoaded = true
    }
    onLoadFailed: root.stateLoaded = true
  }

  FileView {
    id: historyFile
    path: root.stateDir + "/history.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (Array.isArray(d)) root.history = d.filter(function(h) { return h && h.id && h.job })
      } catch (e) { console.warn("rsync: history.json unreadable") }
    }
  }

  FileView {
    id: sshConfig
    path: root.home + "/.ssh/config"
    printErrors: false
    onLoaded: root.sshHosts = Locations.parseSshConfig(text())
    onLoadFailed: root.sshHosts = []
  }
  property var sshHosts: []

  Timer {
    id: stateSave
    interval: 600
    onTriggered: {
      if (!root.stateLoaded) return
      stateFile.setText(JSON.stringify({ version: 1, ui: { mode: root.uiMode }, profiles: root.profiles, last: root.job }, null, 1) + "\n")
      tightenFiles.restart()
    }
  }

  // FileView writes atomically: it creates the replacement with the default
  // umask (0644) and renames it over the old file, so the mode of the files
  // themselves is out of our hands and only the 0700 directories protect them.
  // Paths, host names and profiles are private, so tighten the files too, once
  // the rename has landed.
  Timer {
    id: tightenFiles
    interval: 1500
    onTriggered: Quickshell.execDetached(["sh", "-c", 'chmod 600 -- "$1" "$2" 2>/dev/null; exit 0',
                                          "chmod", root.configDir + "/state.json", root.stateDir + "/history.json"])
  }

  function sanitizeJob(j) {
    var d = defaultJob()
    if (!j || typeof j !== "object") return d
    return {
      src: typeof j.src === "string" ? j.src : d.src,
      dst: typeof j.dst === "string" ? j.dst : d.dst,
      srcAnchor: Locations.sanitizeAnchor(j.srcAnchor),
      dstAnchor: Locations.sanitizeAnchor(j.dstAnchor),
      opts: j.opts && typeof j.opts === "object" && !Array.isArray(j.opts) ? j.opts : d.opts,
      filters: Array.isArray(j.filters) ? j.filters.filter(function(f) {
        return f && Options.FILTER_TYPES.indexOf(f.type) >= 0 && (f.pattern === undefined || typeof f.pattern === "string")
      }) : [],
      extra: typeof j.extra === "string" ? j.extra : ""
    }
  }

  // Loading a stored job points drive paths at wherever the drive is mounted now.
  function loadJob(j) {
    var job = sanitizeJob(clone(j))
    var s = Locations.resolveAnchor(job.srcAnchor, root.mounts)
    var d = Locations.resolveAnchor(job.dstAnchor, root.mounts)
    if (s) job.src = s
    if (d) job.dst = d
    root.job = job
    root.confirmDestructive = false
    stateSave.restart()
  }

  function saveProfile(name) {
    name = String(name || "").trim()
    if (!name) return
    var list = root.profiles.filter(function(p) { return p.name !== name })
    list.unshift({ name: name, job: clone(root.job), saved: Date.now() })
    root.profiles = list
    root.profileName = name
    stateSave.restart()
  }

  property string armedProfile: ""
  Timer { id: armedProfileReset; interval: 4000; onTriggered: root.armedProfile = "" }

  function deleteProfile(name) {
    root.profiles = root.profiles.filter(function(p) { return p.name !== name })
    if (root.profileName === name) root.profileName = ""
    stateSave.restart()
  }

  function saveHistory() {
    historyFile.setText(JSON.stringify(root.history.slice(0, root.historyLimit), null, 1) + "\n")
    tightenFiles.restart()
  }

  function deleteHistory(id) {
    root.history = root.history.filter(function(h) { return h.id !== id })
    saveHistory()
  }

  // Quick picks for a path field: recent locations, connected drives, SSH hosts
  function choicesFor(which) {
    var out = [], seen = {}
    function add(entry, key) { if (seen[key]) return; seen[key] = true; out.push(entry) }
    var sources = []
    for (var i = 0; i < root.history.length; i++) {
      sources.push({ path: root.history[i].job.src, anchor: root.history[i].job.srcAnchor })
      sources.push({ path: root.history[i].job.dst, anchor: root.history[i].job.dstAnchor })
    }
    for (var p = 0; p < root.profiles.length; p++) {
      sources.push({ path: root.profiles[p].job.src, anchor: root.profiles[p].job.srcAnchor })
      sources.push({ path: root.profiles[p].job.dst, anchor: root.profiles[p].job.dstAnchor })
    }
    for (var s = 0; s < sources.length && out.length < 12; s++) {
      var e = sources[s]
      if (!e.path) continue
      var info = Locations.describe(e.path, e.anchor, root.mounts, root.home)
      var key = e.anchor ? e.anchor.uuid + e.anchor.rel : e.path
      add({ icon: info.kind === "drive" ? root.icons.drive : info.kind === "local" ? root.icons.history : root.icons.server,
            label: Locations.shortLabel(e.path, e.anchor, root.mounts, root.home),
            detail: info.kind === "drive" ? (info.connected ? "Recent · connected" : "Recent · not connected") : "Recent",
            path: e.path, anchor: e.anchor, disabled: !info.connected }, key)
    }
    var ds = Locations.drives(root.mounts)
    for (var d = 0; d < ds.length; d++) {
      add({ icon: root.icons.drive, label: ds[d].label || ds[d].model || ds[d].device, detail: "Drive · " + ds[d].mount + " · " + ds[d].size,
            path: ds[d].mount + "/", anchor: null }, "drive:" + ds[d].uuid)
    }
    for (var h = 0; h < root.sshHosts.length; h++) {
      add({ icon: root.icons.server, label: root.sshHosts[h] + ":", detail: "SSH host from ~/.ssh/config", path: root.sshHosts[h] + ":", anchor: null }, "ssh:" + root.sshHosts[h])
    }
    return out
  }

  function pickChoice(which, choice) {
    if (!choice) return
    var changes = {}
    if (choice.anchor && choice.anchor.uuid) {
      changes[which] = Locations.resolveAnchor(choice.anchor, root.mounts) || choice.path
      changes[which + "Anchor"] = choice.anchor
    } else {
      changes[which] = choice.path
      changes[which + "Anchor"] = Locations.anchorFor(choice.path, root.mounts, root.home)
    }
    patchJob(changes)
  }

  // ------------------------------------------------------------------ drives
  property var mounts: []
  property bool mountsLoaded: false
  property string _mountsJson: ""
  property var pendingRun: null      // IPC run waiting for fresh drive info

  function refreshMounts() {
    if (!lsblk.running) lsblk.running = true
  }

  Process {
    id: lsblk
    command: ["lsblk", "-J", "-o", "NAME,PATH,UUID,LABEL,MOUNTPOINTS,RM,HOTPLUG,TRAN,SIZE,MODEL,FSTYPE"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Locations.parseLsblk(text)
        var json = JSON.stringify(parsed)
        // Reassigning an identical list would rebuild every binding using it.
        if (json !== root._mountsJson) { root._mountsJson = json; root.mounts = parsed }
        root.mountsLoaded = true
        if (root.pendingRun) {
          var r = root.pendingRun
          root.pendingRun = null
          pendingRunTimeout.stop()
          root.runProfileNow(r.name, r.dry)
        }
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refreshMounts()
  }

  // An IPC run waits for fresh drive info. If lsblk never answers, the wait
  // must end, or pendingRun stays set and every later call answers "busy".
  Timer {
    id: pendingRunTimeout
    interval: 15000
    onTriggered: {
      if (!root.pendingRun) return
      var name = root.pendingRun.name
      root.pendingRun = null
      root.mountsLoaded = true
      var why = name + ": could not read the connected drives (lsblk did not answer)"
      if (root.notify)
        Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", "critical", "--", "Sync not started", root.escapeMarkup(why)])
      root.flash(why)
    }
  }

  // ------------------------------------------------------------------ browse
  property string browseTarget: ""   // "src" | "dst" | option key
  property string browseMode: ""     // "folder" | "file"

  function browse(target, mode) {
    if (pickerProc.running) return
    root.browseTarget = target
    root.browseMode = mode
    var current = target === "src" || target === "dst" ? resolvedPath(job[target], job[target + "Anchor"]) : String(job.opts[target] || "")
    var start = current && !Options.isRemote(current) ? current.replace(/\/[^\/]*$/, "") || "/" : root.home
    pickerProc.command = ["python3", root.picker, mode, mode === "folder" ? "Choose folder" : "Choose file", start]
    // The popup is a layer surface above normal windows; step aside for the dialog.
    root.close()
    pickerProc.running = true
  }

  Process {
    id: pickerProc
    stdout: StdioCollector { id: pickerOut; waitForEnd: true }
    onExited: function(code) {
      var path = pickerOut.text.replace(/\n$/, "")
      if (code === 0 && path) {
        if (root.browseTarget === "src" || root.browseTarget === "dst") {
          // A picked folder as source means "copy its contents" unless the user
          // already chose otherwise.
          if (root.browseTarget === "src" && root.browseMode === "folder" && (root.contentsOnly || !root.job.src))
            path = path.replace(/\/*$/, "/")
          root.setPath(root.browseTarget, path)
        } else {
          root.setOpt(root.browseTarget, path)
        }
      } else if (code === 2) {
        root.flash("The file chooser is not available (it needs python-gobject and xdg-desktop-portal): type the path instead")
      }
      root.open()
    }
  }

  // ------------------------------------------------------------------ transient message
  property string flashText: ""
  function flash(t) { root.flashText = t; flashTimer.restart() }
  Timer { id: flashTimer; interval: 5000; onTriggered: root.flashText = "" }

  // ------------------------------------------------------------------ running
  property var current: null          // { id, start, dry, job, command }
  property var progress: null
  property var stats: ({})
  property var counts: ({ "new": 0, update: 0, "delete": 0, attr: 0 })
  property int lastExit: -1
  property double runEnd: 0           // when the last run finished, for its duration
  property string lastStatus: ""
  property bool hostKeyChanged: false
  property bool authFailed: false
  property var lastErrors: []
  readonly property bool running: runSession.active
  // A dry run moves no data, so rsync reports 0 % at an absurd rate with ETA
  // 0:00:00. Its file counter is real, so the display follows that instead.
  readonly property var scan: root.running && root.current && root.current.dry && root.progress
    ? Options.scanProgress(root.progress, Date.now() - root.current.start) : null
  readonly property int shownPercent: root.scan ? root.scan.percent : (root.progress ? root.progress.percent : 0)
  readonly property string shownEta: root.scan ? root.scan.eta : (root.progress ? root.progress.eta : "")
  // Nothing to fill the ring with while rsync is still building the file list
  readonly property real ringProgress: !root.running ? -1
    : root.scan ? root.scan.percent / 100
    : root.current && root.current.dry ? -1
    : root.progress ? root.progress.percent / 100 : -1
  readonly property bool busy: runSession.active || auxSession.active || preflight.running || pendingLaunch !== null

  // What a running job is doing right now, in the three lengths the UI needs:
  // "long" for the bar tooltip, "rate" for the log header, "short" for the
  // footer. A dry run has no meaningful byte rate, so it reports files checked.
  function runDetail(mode) {
    if (root.scan)
      return (mode === "long" ? root.scan.percent + "% · " : "")
        + root.scan.done + " of " + root.scan.total + " files checked"
        + (root.shownEta ? " · about " + root.shownEta + " left" : "")
    if (root.progress && !(root.current && root.current.dry))
      return mode === "long" ? root.progress.percent + "% · " + root.progress.speed + " · " + root.progress.eta
        : mode === "rate" ? root.progress.speed + " · ETA " + root.progress.eta
        : root.progress.percent + "%"
    return "building the file list …"
  }

  // The command as it would run, for the preview and both Copy buttons
  readonly property string commandText: Options.commandLine(root.runArgv(root.built.argv))
  property bool confirmDestructive: false

  ListModel { id: itemModel }
  ListModel { id: logModel }

  function startRun(dry) {
    if (root.busy) return false
    root.refreshMounts()
    var r = Options.runArgs(root.runJob, root.defaultRsh, dry)
    if (r.errors.length || root.blockers.length) { root.tab = "job"; return false }
    if (!dry && root.destructive && !root.confirmDestructive) { root.confirmDestructive = true; confirmReset.restart(); return false }
    root.confirmDestructive = false

    // The checks above are lexical: a symlink (~/backup -> ~) must not slip
    // through, so local paths of a deleting run are resolved first.
    var local = [root.runJob.src, root.runJob.dst].filter(function(p) { return p && !Options.isRemote(p) })
    if (Options.destructiveFlags(r.argv).length && local.length) {
      // realpath prints one line per path, so a path containing a line break
      // would shift every following line into the wrong slot (the resolved
      // destination read as the home folder, for instance) and quietly defeat
      // the checks.
      if (local.concat([root.home]).some(function(p) { return p.indexOf("\n") >= 0 })) {
        root.preflightFailed("Paths containing line breaks are not supported")
        return false
      }
      preflight.dry = dry
      preflight.argv = r.argv
      preflight.forJob = JSON.stringify(root.runJob)
      // The resolved paths, then every mount point: lsblk only knows block
      // devices, not network (NFS, SMB, sshfs) or other FUSE mounts.
      preflight.command = ["sh", "-c", 'realpath -m -- "$1" "$2" "$3" || exit 1; findmnt -J -l -o TARGET 2>/dev/null; exit 0',
                           "preflight", root.runJob.src || "/", root.runJob.dst || "/", root.home]
      preflight.running = true
      return true
    }
    return launchRun(dry, r.argv)
  }

  Process {
    id: preflight
    property bool dry: false
    property var argv: []
    property string forJob: ""
    stdout: StdioCollector { id: preflightOut; waitForEnd: true }
    onExited: function(code) {
      if (forJob !== JSON.stringify(root.runJob)) { root.flash("The job changed before the run started"); return }
      // Three realpath lines (each starting with "/"), then findmnt's JSON
      // starting with a lone "{". Exactly three lines, or nothing runs.
      var lines = preflightOut.text.replace(/\n$/, "").split("\n")
      var json = lines.indexOf("{")
      var real = json < 0 ? lines : lines.slice(0, json)
      if (code !== 0) return root.preflightFailed("Could not resolve the local paths")
      if (real.length !== 3) return root.preflightFailed("Paths containing line breaks are not supported")
      var points = []
      if (json >= 0) {
        try { points = Locations.parseFindmnt(lines.slice(json).join("\n")) }
        catch (e) { return root.preflightFailed("Could not read the mount points") }
      }

      var errors = [], warnings = []
      var j = root.runJob
      Options.checkSafety(Options.isRemote(j.src) ? j.src : real[0], Options.isRemote(j.dst) ? j.dst : real[1],
                          argv, real[2], errors, warnings)
      if (!Options.isRemote(j.dst) && Options.deletesOnReceiver(argv)) {
        var inner = root.mountsInside(real[1], points)
        if (inner.length) errors.push("Refusing to delete: " + inner[0] + " is mounted inside the destination")
      }
      if (errors.length) return root.preflightFailed(errors[0] + " (after following symlinks)")
      // runs after this process has exited, so busy no longer counts it
      Qt.callLater(root.launchRun, dry, argv)
    }
  }

  function preflightFailed(message) {
    root.tab = "job"
    root.flash(message)
    if (root.notify && !root.opened)
      Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", "critical", "--", "Sync not started", root.escapeMarkup(message)])
  }

  // The Log tab's Stop button; the IPC stop() additionally cancels a pending
  // run and the SSH helpers.
  function stopRun() { runSession.stop() }

  // A run waiting for its user@host to be resolved
  property var pendingLaunch: null   // { dry, argv, forJob }

  // keyringChecked: the wait below is over (resolved, or given up on)
  function launchRun(dry, argv, keyringChecked) {
    if (root.busy) return false
    // An IPC run or a rerun from the history has just loaded its job, and the
    // new job's user@host isn't resolved yet. Starting now would leave the
    // saved password unused, so resolve it first.
    if (!keyringChecked && root.sshResolveKey && root.keyringKey !== root.sshResolveKey) {
      root.pendingLaunch = { dry: dry, argv: argv, forJob: JSON.stringify(root.runJob) }
      pendingLaunchTimeout.restart()
      sshResolveTimer.stop()
      root.resolveKeyringTarget()
      return true
    }
    argv = root.runArgv(argv)

    itemModel.clear()
    logModel.clear()
    root.progress = null
    root.stats = {}
    root._stats = {}
    root.counts = { "new": 0, update: 0, "delete": 0, attr: 0 }
    root._live = { counts: { "new": 0, update: 0, "delete": 0, attr: 0 }, listed: {}, items: [], logs: [], progress: null, dirty: false }
    root.lastExit = -1
    root.runEnd = 0
    root.lastStatus = ""
    root.hostKeyChanged = false
    root.authFailed = false
    root.lastErrors = []
    root.keyringUsedInSession = false
    root.keyringKeysUsed = []
    root.current = { id: Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36), start: Date.now(), dry: dry,
                     job: clone(root.job), command: Options.redactSecrets(Options.commandLine(argv)) }
    root.tab = "log"
    return runSession.start(argv, root.keyringTarget)
  }

  function launchPending() {
    var l = root.pendingLaunch
    if (!l) return
    root.pendingLaunch = null
    pendingLaunchTimeout.stop()
    if (l.forJob !== JSON.stringify(root.runJob)) { root.flash("The job changed before the run started"); return }
    Qt.callLater(root.launchRun, l.dry, l.argv, true)
  }

  // ssh -G normally answers at once; if it hangs (a Match exec in
  // ~/.ssh/config, say), run without the keyring rather than not at all.
  Timer { id: pendingLaunchTimeout; interval: 5000; onTriggered: root.launchPending() }

  Timer { id: confirmReset; interval: 4000; onTriggered: root.confirmDestructive = false }

  property var _stats: ({})

  // Output arrives line by line, tens of thousands of lines per run. Updating
  // the bound properties for each one rebuilt the log view (and its filter
  // buttons) every time and froze the shell, so lines collect in _live and
  // reach the UI a few times per second.
  property var _live: null
  readonly property int itemsPerKind: 2000
  readonly property int itemTotal: {
    var n = 0
    for (var k in root.counts) n += root.counts[k]
    return n
  }

  function flushLive() {
    var l = root._live
    if (!l || !l.dirty) return
    l.dirty = false
    if (l.items.length) {
      itemModel.append(l.items)
      l.items = []
    }
    if (l.logs.length) {
      var drop = logModel.count + l.logs.length - 400
      if (drop > 0) logModel.remove(0, Math.min(drop, logModel.count))
      logModel.append(l.logs.slice(-400))
      var errs = l.logs.filter(function(e) { return e.error }).map(function(e) { return e.text })
      if (errs.length) root.lastErrors = root.lastErrors.concat(errs).slice(-4)
      l.logs = []
    }
    root.counts = Object.assign({}, l.counts)
    if (l.progress) root.progress = l.progress
  }

  Timer {
    interval: 250
    repeat: true
    running: runSession.active
    onTriggered: root.flushLive()
  }

  function appendLog(text, isError) {
    if (root._live) {
      root._live.logs.push({ text: text, error: isError })
      root._live.dirty = true
      return
    }
    if (logModel.count >= 400) logModel.remove(0, 50)
    logModel.append({ text: text, error: isError })
    if (isError) root.lastErrors = root.lastErrors.concat([text]).slice(-4)
  }

  function onRunStdout(line, cr) {
    var l = root._live
    if (!l) return
    if (root.authState === "checking") root.authResolved(true)
    var p = Options.parseProgress(line)
    if (p) { l.progress = p; l.dirty = true; root.authSucceeded(); return }
    if (Options.parseStat(line, root._stats)) return
    var item = Options.parseItem(line)
    if (item) {
      root.authSucceeded()
      l.counts[item.kind] = (l.counts[item.kind] || 0) + 1
      // capped per kind, so thousands of deletions can't crowd out new files
      if ((l.listed[item.kind] || 0) < root.itemsPerKind) {
        l.listed[item.kind] = (l.listed[item.kind] || 0) + 1
        l.items.push({ kind: item.kind, path: item.path, code: item.code })
      }
      l.dirty = true
      return
    }
    if (line.trim() !== "" && !/^(sending|receiving) incremental file list$/.test(line) && !/^building file list/.test(line))
      appendLog(line, false)
  }

  function onRunStderr(line) {
    if (/REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed/.test(line)) root.hostKeyChanged = true
    if (/Permission denied \(|Too many authentication failures/.test(line)) root.authFailed = true
    if (line.trim() !== "") appendLog(line, true)
  }

  function onRunFinished(code, stopped) {
    root.flushLive()
    if (root.authState === "checking") {
      if (code === 0 || code === 23 || code === 24 || code === 25) root.authResolved(true)
      else if (root.authFailed) root.authResolved(false)
      else root.authState = ""
    }
    root._live = null
    root.stats = Object.assign({}, root._stats)
    root.lastExit = code
    root.runEnd = Date.now()
    root.lastStatus = Options.exitStatus(code, stopped, root.itemTotal)
    root.dropPrompts("run")
    if (code === 0 || code === 23 || code === 24 || code === 25) root.authSucceeded()
    root.pendingSecret = ""
    var cur = root.current
    if (!cur) return
    var entry = {
      id: cur.id, start: cur.start, end: Date.now(), dry: cur.dry, job: Options.redactJob(cur.job), command: cur.command,
      code: code, status: root.lastStatus, exitText: stopped ? "Stopped" : Options.exitText(code),
      stats: root.stats, counts: root.counts, errors: root.lastErrors
    }
    root.history = [entry].concat(root.history).slice(0, root.historyLimit)
    root.saveHistory()
    if (root.notify) {
      var title = (cur.dry ? "Dry run " : "Sync ") + (root.lastStatus === "ok" ? "finished" : root.lastStatus === "stopped" ? "stopped" : root.lastStatus === "partial" ? "partly finished" : "failed")
      // the notification daemon renders markup: escape paths and file names
      var body = root.escapeMarkup(root.historyTitle(entry) + "\n" + root.historySummary(entry))
      Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", root.lastStatus === "failed" ? "critical" : "normal", "--", title, body])
    }
  }

  Session {
    id: runSession
    helper: root.helper
    onStdoutLine: function(line, cr) { root.onRunStdout(line, cr) }
    onStderrLine: function(line) { root.onRunStderr(line) }
    onPrompt: function(id, kind, text) { root.enqueuePrompt("run", runSession.dir, id, kind, text, runSession.keyringTarget) }
    onPromptTimedOut: function(id) { root.dropPrompt(id) }
    onKeyringUsed: function(kind, keyFile) { root.keyringAnswered(runSession, kind, keyFile) }
    onFinished: function(code, stopped) { root.onRunFinished(code, stopped) }
  }

  // ------------------------------------------------------------------ SSH helpers (test / key setup)
  property string auxKind: ""        // "test" | "setup"
  property string auxResult: ""
  property bool auxOk: false
  property var auxErrors: []

  function sshBaseArgs() {
    var rsh = Options.rshCommand(job.opts, root.defaultRsh) || root.defaultRsh
    return Options.splitArgs(rsh) || ["ssh"]
  }

  // rsync takes [::1]:path, ssh takes ::1
  function sshHostArg() {
    var t = Options.sshTarget(root.remotePath)
    return t ? (t.user ? t.user + "@" : "") + t.host.replace(/^\[(.*)\]$/, "$1") : ""
  }

  function testConnection() {
    if (root.busy || !root.sshHostArg()) return
    root.auxKind = "test"
    root.auxResult = "Connecting to " + root.sshHostArg() + " …"
    root.auxOk = false
    root.auxErrors = []
    root.keyringUsedInSession = false
    root.keyringKeysUsed = []
    auxSession.start(sshBaseArgs().concat(["-o", "ConnectTimeout=10", "--", root.sshHostArg(), "true"]), root.keyringTarget)
  }

  // Installs the key the job is set to use (Options > Connection > SSH identity
  // file), so the sync afterwards logs in with the key that was just installed;
  // ~/.ssh/id_ed25519 when none is set. Creates it when missing and derives the
  // .pub from a key that has none (passphrase asked in the popup).
  readonly property string setupKeyFile: Locations.absolutePath(String(job.opts.sshIdentity || "").trim(), root.home) || (root.home + "/.ssh/id_ed25519")
  function setupKeyLogin() {
    if (root.busy || !root.sshHostArg()) return
    var base = sshBaseArgs()
    var copyArgs = []
    // Hand -p, -o, -F and -J of the remote shell on to ssh-copy-id, spelled
    // "-p 22" or "-p22" (the SSH port option ends up there as -p too), so the
    // key is installed where rsync connects.
    for (var i = 1; i < base.length; i++) {
      var m = /^-([opFJ])(.*)$/.exec(base[i])
      if (!m) continue
      var value = m[2] !== "" ? m[2] : base[++i]
      if (value === undefined) break
      if (m[1] === "J") copyArgs.push("-o", "ProxyJump=" + value)
      else copyArgs.push("-" + m[1], value)
    }
    copyArgs.push("--", root.sshHostArg())
    var script = 'set -e; umask 077; key=$1; shift; mkdir -p -m 700 "${key%/*}"; '
      + 'if [ ! -f "$key" ]; then echo "Creating $key" >&2; ssh-keygen -q -t ed25519 -C omarchy-rsync -f "$key"; fi; '
      + 'if [ ! -f "$key.pub" ]; then echo "Deriving $key.pub" >&2; '
      + 'ssh-keygen -y -f "$key" > "$key.pub.new" || { rm -f -- "$key.pub.new"; exit 1; }; mv -- "$key.pub.new" "$key.pub"; fi; '
      + 'exec ssh-copy-id -i "$key.pub" "$@"'
    root.auxKind = "setup"
    root.auxResult = "Setting up key login for " + root.sshHostArg() + " with " + root.setupKeyFile + " …"
    root.auxOk = false
    root.auxErrors = []
    root.keyringUsedInSession = false
    root.keyringKeysUsed = []
    keyCheck.keyFile = root.setupKeyFile
    auxSession.start(["bash", "-c", script, "setup-key", root.setupKeyFile].concat(copyArgs), root.keyringTarget)
  }

  // After the key setup: a key with a passphrase still asks for it on every
  // connection until the keyring remembers it, so say which one it is.
  Process {
    id: keyCheck
    property string keyFile: ""
    onExited: function(code) {
      if (root.auxKind !== "setup" || !root.auxOk) return
      root.auxResult = code === 0
        ? "Key login is set up. Syncs with this server no longer need a password."
        : root.savedPassphrase && keyFile === root.setupKeyFile
          ? "Key login is set up. The key's passphrase is saved in the keyring, so syncs run without questions."
          : "Key login is set up. The key " + keyFile + " has a passphrase: the next sync asks for it — tick Remember, and syncs run without questions from then on."
    }
  }

  // The Job tab shows and cancels the SSH helper without reaching into it.
  readonly property bool auxRunning: auxSession.active
  function stopAux() { auxSession.stop() }

  Session {
    id: auxSession
    helper: root.helper
    onStderrLine: function(line) {
      if (line.trim() === "") return
      if (/REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed/.test(line)) root.hostKeyChanged = true
      root.auxErrors = root.auxErrors.concat([line]).slice(-3)
    }
    onPrompt: function(id, kind, text) { root.enqueuePrompt("aux", auxSession.dir, id, kind, text, auxSession.keyringTarget) }
    onPromptTimedOut: function(id) { root.dropPrompt(id) }
    onKeyringUsed: function(kind, keyFile) { root.keyringAnswered(auxSession, kind, keyFile) }
    onFinished: function(code, stopped) {
      root.dropPrompts("aux")
      if (root.authState === "checking") {
        if (code === 0) root.authResolved(true)
        else if (root.auxErrors.some(function(e) { return /Permission denied|Too many authentication failures/.test(e) })) root.authResolved(false)
        else root.authState = ""
      }
      root.auxOk = code === 0
      if (code === 0) root.authSucceeded()
      root.pendingSecret = ""
      if (root.auxKind === "test")
        root.auxResult = code === 0 ? "Connection works" : stopped ? "Cancelled" : "Connection failed" + (root.auxErrors.length ? ": " + root.auxErrors[root.auxErrors.length - 1] : "")
      else if (code === 0) {
        root.auxResult = "Key login is set up."
        // no passphrase <=> an empty one opens the key
        keyCheck.command = ["ssh-keygen", "-y", "-P", "", "-f", keyCheck.keyFile]
        keyCheck.running = true
      } else
        root.auxResult = stopped ? "Cancelled" : "Key setup failed" + (root.auxErrors.length ? ": " + root.auxErrors[root.auxErrors.length - 1] : "")
      root.checkSaved()
    }
  }

  // ------------------------------------------------------------------ prompts & keyring
  property var prompts: []           // [{ source, dir, id, kind, text, keyringTarget }]
  readonly property var prompt: prompts.length ? prompts[0] : null
  property bool keyringUsedInSession: false
  property var keyringKeysUsed: []   // key files the keyring unlocked in this session
  property bool savedPassword: false
  property bool savedPassphrase: false   // for setupKeyFile
  property string pendingSecret: ""
  property string pendingTarget: ""
  property string promptNote: ""

  onKeyringTargetChanged: checkSaved()
  onSetupKeyFileChanged: checkSaved()

  function keyringAnswered(session, kind, keyFile) {
    if (kind === "key") {
      root.keyringKeysUsed = root.keyringKeysUsed.concat([keyFile])
      root.authChecking(root.sshHostArg(), true, keyFile)
    } else {
      root.keyringUsedInSession = true
      root.authChecking(session.keyringTarget, true, "")
    }
  }

  // hostkey | confirm | secret | text
  function promptType(p) {
    if (!p) return ""
    if (/authenticity of host|continue connecting/i.test(p.text)) return "hostkey"
    if (p.kind === "confirm") return "confirm"
    if (/password|passphrase|pin\b|code|token|otp|verification/i.test(p.text)) return "secret"
    return "text"
  }

  // A password prompt for exactly the user@host its session was started for
  function rememberablePassword(p) {
    return !!p && p.keyringTarget !== "" && root.passwordPromptTarget(p.text) === p.keyringTarget
  }
  // True when the keyring may be offered for this prompt: such a password, or
  // a key's passphrase (checked against the key file before it is stored)
  function rememberable(p) {
    if (!root.keyringAvailable) return false   // no secret-tool (libsecret)
    return root.rememberablePassword(p) || (!!p && root.passphrasePromptKey(p.text) !== "")
  }

  function enqueuePrompt(source, dir, id, kind, text, keyringTarget) {
    var p = { source: source, dir: dir, id: id, kind: kind, text: text, keyringTarget: keyringTarget || "" }
    root.promptNote = ""
    var target = root.passwordPromptTarget(text)
    var key = root.passphrasePromptKey(text)
    if (root.keyringUsedInSession && root.rememberablePassword(p)) {
      // The stored password was just rejected.
      root.promptNote = "The saved password was rejected and has been removed from the keyring."
      Quickshell.execDetached(["bash", root.helper, "forget", p.keyringTarget])
      root.keyringUsedInSession = false
      if (p.keyringTarget === root.keyringTarget) root.savedPassword = false
    }
    if (key && root.keyringKeysUsed.indexOf(key) >= 0) {
      // It was checked when saved, so the key's passphrase has changed since.
      root.promptNote = "The saved passphrase no longer unlocks this key and has been removed from the keyring."
      Quickshell.execDetached(["bash", root.helper, "forget-key", key])
      root.keyringKeysUsed = root.keyringKeysUsed.filter(function(k) { return k !== key })
      if (key === root.setupKeyFile) root.savedPassphrase = false
    }
    // Another password prompt means the remembered one did not work.
    if (target) root.pendingSecret = ""
    if (root.authState === "checking" && root.isLoginPrompt(p)) {
      root.authResolved(false)
      if (!root.promptNote) root.promptNote = "That was not accepted. Please try again."
    }
    // ssh asks one question at a time: a new one replaces anything still
    // queued for the same session.
    root.prompts = root.prompts.filter(function(q) { return q.source !== source }).concat([p])
    // Never pop up on our own: the popup takes keyboard focus, and whatever
    // the user is typing elsewhere could end up in the password field.
    if (!root.opened && root.notify)
      Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", "critical", "--", root.appName + " needs your input",
                               root.escapeMarkup(root.promptHeadline(p) + ". Click the rs icon in the bar.")])
  }

  function dropPrompt(id) {
    root.prompts = root.prompts.filter(function(p) { return p.id !== id })
  }

  function dropPrompts(source) {
    root.prompts = root.prompts.filter(function(p) { return p.source !== source })
  }

  function promptHeadline(p) {
    switch (promptType(p)) {
    case "hostkey": return "New server: confirm its identity"
    case "confirm": return "Confirmation needed"
    case "secret":
      if (root.passphrasePromptKey(p.text)) return "Passphrase of the key " + root.fileName(root.passphrasePromptKey(p.text))
      if (root.newKeyPrompt(p.text)) return /again/i.test(p.text) ? "New key: repeat the passphrase" : "New key: choose a passphrase"
      return /passphrase/i.test(p.text) ? "Passphrase" : /password/i.test(p.text) ? "Password" : "Verification code"
    default: return "Question from ssh"
    }
  }

  // ---- login feedback: after a password or key passphrase was given, show
  // whether ssh accepted it. Success is evidence based (rsync output, a
  // finished test); another prompt of the same kind means it was rejected.
  property string authState: ""      // "" | "checking" | "ok" | "rejected"
  property string authWho: ""
  property string authKey: ""        // key file being unlocked, "" for a password
  property bool authFromKeyring: false
  Timer { id: authClear; interval: 6000; onTriggered: if (root.authState === "ok") root.authState = "" }

  // login secret prompts: "u@h's password:", "(u@h) Password:", key passphrase
  function isLoginPrompt(p) {
    return !!p && (root.passwordPromptTarget(p.text) !== "" || root.passphrasePromptKey(p.text) !== "")
  }
  function authChecking(who, fromKeyring, key) {
    root.authState = "checking"
    root.authWho = who
    root.authKey = key || ""
    root.authFromKeyring = fromKeyring
  }
  function authResolved(ok) {
    if (root.authState !== "checking") return
    root.authState = ok ? "ok" : "rejected"
    if (ok) authClear.restart()
  }

  // Sends the answer through askpass.sh (stdin -> FIFO); the secret is never
  // part of a command line and the field is cleared right away.
  function answerPrompt(value, accepted, remember) {
    var p = root.prompt
    if (!p) return
    root.dropPrompt(p.id)
    var key = root.passphrasePromptKey(p.text)
    if (accepted && root.isLoginPrompt(p))
      root.authChecking(root.passwordPromptTarget(p.text) || root.sshHostArg(), false, key)
    else if (!accepted && root.isLoginPrompt(p))
      root.authState = ""
    if (accepted && remember && value && root.rememberablePassword(p)) {
      root.pendingSecret = value
      root.pendingTarget = p.keyringTarget
    } else if (accepted && remember && value && key) {
      root.storePassphrase(key, value)
    }
    var proc = answerComponent.createObject(root, {
      command: ["bash", root.helper, "answer", p.dir, p.id],
      payload: (accepted ? "Y" + value : "N") + "\n"
    })
    proc.running = true
  }

  Component {
    id: answerComponent
    Process {
      property string payload: ""
      stdinEnabled: true
      onStarted: { write(payload); payload = "" }
      onExited: destroy()
    }
  }

  // Called once authentication evidently worked: store a password the user
  // asked to remember.
  function authSucceeded() {
    if (!root.pendingSecret) return
    var proc = answerComponent.createObject(root, {
      command: ["bash", root.helper, "store", root.pendingTarget],
      payload: root.pendingSecret + "\n"
    })
    root.pendingSecret = ""
    proc.exited.connect(function(code) {
      if (code !== 0) root.flash("Could not save the password: the login keyring is missing or locked. The sync is not affected.")
      root.checkSaved()
    })
    proc.running = true
  }

  // A passphrase is checked against its key file before it is stored, so
  // unlike a password it needn't wait for the login to succeed.
  function storePassphrase(key, value) {
    var proc = answerComponent.createObject(root, { command: ["bash", root.helper, "store-key", key], payload: value + "\n" })
    proc.exited.connect(function(code) {
      root.flash(code === 0 ? "The passphrase of " + root.fileName(key) + " is saved in the keyring"
        : code === 2 ? "Not saved: that passphrase does not unlock " + key
        : "Could not save the passphrase: the login keyring is missing or locked")
      root.checkSaved()
    })
    proc.running = true
  }

  function forgetPassword() {
    if (!root.keyringTarget) return
    var proc = answerComponent.createObject(root, { command: ["bash", root.helper, "forget", root.keyringTarget], payload: "" })
    proc.exited.connect(function() { root.checkSaved() })
    proc.running = true
  }

  function forgetPassphrase() {
    var proc = answerComponent.createObject(root, { command: ["bash", root.helper, "forget-key", root.setupKeyFile], payload: "" })
    proc.exited.connect(function() { root.checkSaved() })
    proc.running = true
  }

  function checkSaved() {
    if (hasSecret.running) { hasSecret.again = true; return }
    // one exit status per question: 0 = saved
    hasSecret.command = ["sh", "-c", 'bash "$1" has "$2"; p=$?; bash "$1" has-key "$3"; echo "$p $?"',
                         "has", root.helper, root.keyringTarget, root.setupKeyFile]
    hasSecret.running = true
  }

  Process {
    id: hasSecret
    property bool again: false
    stdout: StdioCollector { id: hasSecretOut; waitForEnd: true }
    onExited: function() {
      var r = hasSecretOut.text.trim().split(" ")
      root.savedPassword = !!root.keyringTarget && r[0] === "0"
      root.savedPassphrase = r[1] === "0"
      if (again) { again = false; Qt.callLater(root.checkSaved) }
    }
  }

  // ------------------------------------------------------------------ history helpers
  function escapeMarkup(t) {
    return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function historyTitle(h) {
    return Locations.shortLabel(h.job.src, h.job.srcAnchor, root.mounts, root.home) + "  →  "
      + Locations.shortLabel(h.job.dst, h.job.dstAnchor, root.mounts, root.home)
  }

  function historySummary(h) {
    var parts = []
    var c = h.counts || {}
    var s = h.stats || {}
    if (h.status === "ok" || h.status === "partial") {
      parts.push((c["new"] || 0) + " new, " + (c.update || 0) + " updated" + (c["delete"] ? ", " + c["delete"] + " deleted" : ""))
      if (s.transferredSize && !h.dry) parts.push(s.transferredSize + " bytes")
    }
    if (h.status !== "ok") parts.push(h.exitText)
    return parts.join(" · ")
  }

  function relativeTime(ms) {
    var d = (Date.now() - ms) / 1000
    if (d < 60) return "just now"
    if (d < 3600) return Math.floor(d / 60) + " min ago"
    if (d < 86400) return Math.floor(d / 3600) + " h ago"
    if (d < 86400 * 7) return Math.floor(d / 86400) + " d ago"
    return Qt.formatDate(new Date(ms), "d MMM yyyy")
  }

  function duration(ms) {
    var s = Math.round(ms / 1000)
    if (s < 60) return s + " s"
    if (s < 3600) return Math.floor(s / 60) + " min " + (s % 60) + " s"
    return Math.floor(s / 3600) + " h " + Math.floor((s % 3600) / 60) + " min"
  }

  function statusColor(status) {
    return status === "ok" ? root.fg : status === "partial" ? Color.accent : status === "failed" ? Color.urgent : root.dim
  }

  property string confirmRerun: ""
  Timer { id: rerunReset; interval: 4000; onTriggered: root.confirmRerun = "" }

  function rerun(h) {
    if (root.busy) return
    if (root.confirmRerun !== h.id) { root.confirmRerun = h.id; rerunReset.restart(); return }
    root.confirmRerun = ""
    root.loadJob(h.job)
    if (root.blockers.length) { root.tab = "job"; return }
    root.confirmDestructive = true   // "Confirm: run now" was the confirmation
    root.startRun(h.dry)
  }

  // ------------------------------------------------------------------ IPC
  function runProfile(name, dry) {
    if (!root.profiles.some(function(p) { return p.name === name })) return "no such profile"
    if (root.busy || root.pendingRun) return "busy"
    // Drive paths must be checked against fresh lsblk data first.
    root.pendingRun = { name: name, dry: dry }
    root.mountsLoaded = false
    pendingRunTimeout.restart()
    root.refreshMounts()
    return "starting"
  }

  function runProfileNow(name, dry) {
    for (var i = 0; i < root.profiles.length; i++) {
      if (root.profiles[i].name !== name) continue
      if (root.busy) return "busy"
      root.loadJob(root.profiles[i].job)
      root.profileName = name
      if (root.blockers.length) {
        if (root.notify) Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", "critical", "--", "Sync not started", root.escapeMarkup(name + ": " + root.blockers.join("; "))])
        return "blocked: " + root.blockers.join("; ")
      }
      root.confirmDestructive = true   // an explicit IPC call is the confirmation
      return root.startRun(dry) ? "started" : "not started"
    }
    return "no such profile"
  }

  IpcHandler {
    target: "io.github.arikisonfire.rsync.jobs"
    // Run a saved profile, e.g. from a keybinding or a systemd timer:
    //   omarchy-shell io.github.arikisonfire.rsync.jobs run "Laptop → USB"
    function run(profile: string): string { return root.runProfile(profile, false) }
    function dryRun(profile: string): string { return root.runProfile(profile, true) }
    function stop(): string {
      var stopped = []
      if (root.pendingRun) {
        root.pendingRun = null
        pendingRunTimeout.stop()
        root.mountsLoaded = true
        stopped.push("pending run")
      }
      if (root.pendingLaunch) {
        root.pendingLaunch = null
        pendingLaunchTimeout.stop()
        stopped.push("starting run")
      }
      if (runSession.active) { runSession.stop(); stopped.push(root.current && root.current.dry ? "dry run" : "sync") }
      if (auxSession.active) { auxSession.stop(); stopped.push(root.auxKind === "setup" ? "key setup" : "connection test") }
      return stopped.length ? "stopping " + stopped.join(", ") : "nothing to stop"
    }
    function show(tab: string): void {
      if (["job", "options", "filters", "history", "log"].indexOf(tab) >= 0) {
        if (tab === "options" || tab === "filters") root.setUiMode("expert")
        root.tab = tab
      }
      root.open()
    }
    function status(): string {
      if (root.pendingRun || root.pendingLaunch) return "starting"
      if (!root.running) return root.lastStatus || "idle"
      return (root.current && root.current.dry ? "dry run " : "running ")
        + (root.scan || root.progress ? root.shownPercent + "%" : "starting")
    }
  }

  // ------------------------------------------------------------------ bar button
  // "done" badge shows briefly after a successful run
  property bool justFinished: false
  Timer { id: doneBadge; interval: 6000; onTriggered: root.justFinished = false }
  onLastStatusChanged: if (lastStatus === "ok") { justFinished = true; doneBadge.restart() }

  readonly property string iconBadge: root.prompt ? "prompt"
    : root.running && root.current && root.current.dry ? "dry"
    : root.busy ? ""
    : root.lastStatus === "failed" ? "failed"
    : root.justFinished ? "done" : ""

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      RsyncIcon {
        color: button.foreground
        urgent: button.activeColor
        fontFamily: button.fontFamily
        running: root.busy && root.prompt === null
        progress: root.ringProgress
        badge: root.iconBadge
      }
    }
    tooltipText: root.prompt ? root.appName + " needs your input"
      : root.running ? (root.current && root.current.dry ? "Dry run (nothing is changed) · " : "Syncing · ") + root.runDetail("long")
      : root.lastStatus ? root.appName + ": last run " + root.lastStatus : root.appName
    onPressed: function(b) {
      if (b === Qt.RightButton && root.running) { root.tab = "log"; root.open() }
      else root.toggle()
    }

  }

  // ------------------------------------------------------------------ popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(660))
    contentHeight: panel.fittedContentHeight(Style.space(720), Style.space(720))

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Column {
        id: head
        width: parent.width
        spacing: Style.spacing.lg

        // hero
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight)

          RsyncIcon {
            id: heroIcon
            width: Style.font.display * 1.4
            height: width
            color: root.fg
            urgent: Color.urgent
            fontFamily: root.ff
            running: root.busy && root.prompt === null
            progress: root.ringProgress
            badge: root.iconBadge
            anchors.verticalCenter: parent.verticalCenter
          }
          Column {
            id: heroText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: modeSwitch.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              textFormat: Text.PlainText
              text: root.appName
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: root.prompt ? "WAITING FOR YOU"
                : root.running ? (root.current && root.current.dry ? "DRY RUN " : "SYNCING ")
                    + (root.scan || (root.progress && !(root.current && root.current.dry)) ? root.shownPercent + "%" : "· CHECKING")
                : root.authState === "checking" && root.busy ? "LOGGING IN"
                : auxSession.active ? "CONNECTING"
                : root.lastStatus ? "LAST RUN: " + root.lastStatus.toUpperCase() : "READY"
              color: root.prompt || root.lastStatus === "failed" ? Color.urgent : root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
          ButtonGroup {
            id: modeSwitch
            anchors.right: tabs.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            foreground: root.fg
            fontFamily: root.ff
            fontSize: Style.font.caption
            value: root.uiMode
            options: [
              { value: "easy", label: "Easy", tooltip: "Simple questions; the options are set for you" },
              { value: "expert", label: "Expert", tooltip: "Every rsync option, filters and the command" }
            ]
            onChanged: function(v) { root.setUiMode(v) }
          }
          ButtonGroup {
            id: tabs
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            foreground: root.fg
            fontFamily: root.ff
            fontSize: Style.font.caption
            value: root.tab
            options: [
              { value: "job", label: "Job" },
              { value: "options", label: "Options" },
              { value: "filters", label: "Filters" + (root.job.filters.length ? " " + root.job.filters.length : "") },
              { value: "history", label: "History" },
              { value: "log", label: root.running ? "Log •" : "Log" }
            ].filter(function(t) { return root.expert || (t.value !== "options" && t.value !== "filters") })
            onChanged: function(v) { root.tab = v }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- SSH prompt card
        PromptCard {
          width: parent.width
          visible: root.prompt !== null
          panel: root
        }

        Text {
          visible: root.authState !== "" && (root.prompt === null || root.authState === "ok")
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.authState === "checking"
              ? root.icons.key + (root.authKey
                  ? "  Unlocking the key " + root.fileName(root.authKey) + (root.authFromKeyring ? " with the saved passphrase" : "") + " and logging in to " + root.authWho + " …"
                  : "  Logging in to " + root.authWho + (root.authFromKeyring ? " with the saved password …" : " …"))
            : root.authState === "ok" ? root.icons.check + "  Logged in to " + root.authWho
            : root.authKey ? root.icons.alert + "  That passphrase does not unlock the key " + root.fileName(root.authKey)
            : root.icons.alert + "  Login to " + root.authWho + " failed: the password was not accepted"
          color: root.authState === "rejected" ? Color.urgent : root.authState === "ok" ? root.fg : root.dim
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: root.flashText !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.flashText
          color: Color.urgent
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }
      }

      // ---- tab bodies
      Item {
        id: body
        anchors.top: head.bottom
        anchors.topMargin: Style.spacing.lg
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: footer.visible ? Style.spacing.lg : 0

        // ================================================================ JOB
        JobTab {
          anchors.fill: parent
          visible: root.tab === "job"
          panel: root
        }

        // ================================================================ OPTIONS
        OptionsTab {
          anchors.fill: parent
          visible: root.tab === "options"
          panel: root
        }

        // ================================================================ FILTERS
        FiltersTab {
          anchors.fill: parent
          visible: root.tab === "filters"
          panel: root
        }

        // ================================================================ HISTORY
        HistoryTab {
          anchors.fill: parent
          visible: root.tab === "history"
          panel: root
        }

        // ================================================================ LOG
        LogTab {
          anchors.fill: parent
          visible: root.tab === "log"
          panel: root
          itemModel: itemModel
          logModel: logModel
        }

      }
      // ---- footer: run buttons, reachable from Job, Options and Filters
      Item {
        id: footer
        visible: root.tab === "job" || root.tab === "options" || root.tab === "filters"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? runButton.height + Style.spacing.lg : 0

        PanelSeparator { width: parent.width; foreground: root.fg }

        Text {
          anchors.left: parent.left
          anchors.right: footerButtons.left
          anchors.rightMargin: Style.spacing.lg
          anchors.bottom: parent.bottom
          height: runButton.height
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.blockers.length ? root.icons.alert + "  " + root.blockers[0]
            : root.confirmDestructive ? root.icons.alert + "  This run deletes files. Click again to confirm."
            : root.running ? (root.current && root.current.dry ? "Dry run · " : "Syncing · ") + root.runDetail("short")
            : "Tip: a dry run shows what would change"
          color: root.blockers.length || root.confirmDestructive ? Color.urgent : root.dim
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        Row {
          id: footerButtons
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.spacing.md
          Button {
            text: "Dry run"
            tooltipText: "Show what would change without changing anything"
            bordered: true
            enabled: !root.busy && root.blockers.length === 0
            opacity: enabled ? 1 : 0.45
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.startRun(true)
          }
          Button {
            id: runButton
            text: root.running ? "Show progress" : root.confirmDestructive ? "Confirm run" : "Run"
            iconText: root.running ? "" : root.icons.play
            bordered: true
            active: true
            enabled: root.running || (!root.busy && root.blockers.length === 0)
            opacity: enabled ? 1 : 0.45
            foreground: root.confirmDestructive ? Color.urgent : root.fg
            fontFamily: root.ff
            onClicked: root.running ? (root.tab = "log") : root.startRun(false)
          }
        }
      }
    }
  }

  // The shell recreates this panel when the shell restarts or a plugin file
  // changes, which kills a running job. Say so, otherwise the run just stops
  // without a word and never reaches the history.
  Component.onDestruction: {
    if (!runSession.active) return
    runSession.stop()
    if (root.notify)
      Quickshell.execDetached(["notify-send", "-a", root.appName, "-u", "critical", "--",
        (root.current && root.current.dry ? "Dry run stopped" : "Sync stopped"),
        "The " + root.appName + " widget was reloaded (shell restart or plugin change), so the run was cancelled."])
  }
}
