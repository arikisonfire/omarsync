import QtQuick
import Quickshell.Io

// One command run through askpass.sh: turns the raw output streams into lines
// and the token-marked control lines into prompt signals. Output that merely
// looks like a control line (e.g. printed by a remote host) is passed through
// as normal stderr because it can't know the session token.
Item {
  id: root

  required property string helper       // askpass.sh
  property bool active: proc.running
  property string dir: ""
  property string token: ""
  // user@host the keyring may answer for in this session (fixed at start, so
  // editing the job while a prompt waits can't retarget it)
  property string keyringTarget: ""
  property bool stopRequested: false

  signal started()
  signal stdoutLine(string line, bool carriageReturn)
  signal stderrLine(string line)
  signal prompt(string id, string kind, string text)
  signal promptTimedOut(string id)
  // kind "password" (for keyringTarget) or "key" (keyFile's passphrase)
  signal keyringUsed(string kind, string keyFile)
  signal finished(int exitCode, bool stopped)

  property string _outBuf: ""
  property string _errBuf: ""

  // argv: command to run; keyringTarget_: "user@host" (as ssh -G resolves it) or ""
  function start(argv, keyringTarget_) {
    if (proc.running) return false
    dir = ""
    token = ""
    stopRequested = false
    keyringTarget = keyringTarget_ || ""
    _outBuf = ""
    _errBuf = ""
    var cmd = ["bash", helper, "run"]
    if (keyringTarget) cmd.push("--keyring", keyringTarget)
    proc.command = cmd.concat(["--"], argv)
    proc.running = true
    return true
  }

  function stop() {
    if (!proc.running) return
    stopRequested = true
    proc.signal(15)
  }

  function _drainOut(chunk, flush) {
    var buf = _outBuf + chunk
    var re = /[\r\n]/g
    var last = 0, m
    while ((m = re.exec(buf)) !== null) {
      root.stdoutLine(buf.slice(last, m.index), m[0] === "\r")
      last = m.index + 1
    }
    _outBuf = buf.slice(last)
    if (flush && _outBuf !== "") { root.stdoutLine(_outBuf, false); _outBuf = "" }
  }

  function _drainErr(chunk, flush) {
    var buf = _errBuf + chunk
    var parts = buf.split("\n")
    _errBuf = parts.pop()
    if (flush && _errBuf !== "") { parts.push(_errBuf); _errBuf = "" }
    for (var i = 0; i < parts.length; i++) _handleErr(parts[i].replace(/\r$/, ""))
  }

  function _handleErr(line) {
    // A control line can land behind an unterminated line of the command's
    // own stderr: split it off instead of losing the prompt. It holds no
    // \x1e of its own, so it starts at the last one (a stray \x1e in the
    // command's output must not hide it).
    var at = line.lastIndexOf("\x1e")
    if (at > 0) {
      root.stderrLine(line.slice(0, at))
      line = line.slice(at)
    }
    if (line.charAt(0) === "\x1e") {
      var f = line.slice(1).split(" ")
      // The first control line announces the session and fixes the token.
      if (root.token === "" && f.length === 3 && f[1] === "session" && /^[0-9a-f]{32}$/.test(f[0])) {
        root.token = f[0]
        root.dir = f[2]
        return
      }
      if (root.token !== "" && f[0] === root.token) {
        if (f[1] === "ask" && f.length === 5 && /^[0-9a-f]{16}$/.test(f[2])) {
          root.prompt(f[2], f[3] === "confirm" ? "confirm" : "text", _decode(f[4]))
        } else if (f[1] === "timeout" && f.length === 3) {
          root.promptTimedOut(f[2])
        } else if (f[1] === "keyring" && f[2] === "password" && f.length === 3) {
          root.keyringUsed("password", "")
        } else if (f[1] === "keyring" && f[2] === "key" && f.length === 4) {
          root.keyringUsed("key", _decode(f[3]))
        }
        return
      }
    }
    root.stderrLine(line)
  }

  // base64 -> UTF-8 string
  function _decode(b64) {
    var bin = ""
    try { bin = Qt.atob(b64) } catch (e) { return "" }
    try { return decodeURIComponent(escape(bin)) } catch (e2) { return bin }
  }

  Process {
    id: proc
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root._drainOut(data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root._drainErr(data, false) }
    }
    onStarted: root.started()
    onExited: function(exitCode, exitStatus) {
      root._drainOut("", true)
      root._drainErr("", true)
      var stopped = root.stopRequested
      root.dir = ""
      root.token = ""
      root.finished(exitCode, stopped)
    }
  }
}
