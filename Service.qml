import QtQuick
import Quickshell
import Quickshell.Io

// OmaBackup service -- the single source of truth for the bar widget.
//
// All judgment lives in bin/omabackup and lib/*.sh (versioned, linted and
// self-tested with the engine). This file only:
//   * watches ~/.local/state/omabackup/status.json (XDG_STATE_HOME honoured,
//     written by the engine via atomic rename after every verb)
//   * exposes actions that run CLI verbs as argv, never a shell string
//
// Mounted once by the shell (kind "service", keepLoaded); Panel instances
// (one per monitor) read from it via bar.shell.serviceFor(pluginId) -- the
// shell's own service cache is what makes this a singleton, not a QML
// `pragma Singleton` (the shell loads it via Qt.createComponent + createObject,
// not a module import, so a pragma-Singleton root just produces a duplicate-
// registration warning; QtObject is the same root the sibling omarecorder
// plugin's Service.qml uses for the identical loading path).
QtObject {
  id: svc

  // decodeURIComponent: a plugin dir under a home directory with a space in
  // it arrives %20-escaped otherwise (mirrors omarecorder's Service.qml).
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString()).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: pluginDir + "/bin/omabackup"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omabackup"
  readonly property string statusPath: stateDir + "/status.json"

  property var st: null
  property string cliError: ""
  property bool busy: false
  readonly property string setup: st && st.setup ? st.setup : (cliError ? "fault" : "not-configured")
  readonly property string sysState: cliError ? "fault" : (st && st.state ? st.state : "unknown")

  // The engine writes status.json by atomic rename; watch the directory so a
  // replaced file is picked up, then re-read. QtObject has no default
  // property (unlike Item/Singleton), so this has to be an explicit property
  // rather than an anonymous child -- same as omarecorder's stateView.
  property FileView statusFile: FileView {
    id: statusFile
    path: svc.statusPath
    watchChanges: true
    onFileChanged: statusFile.reload()
    onLoaded: svc.parse(statusFile.text())
    onLoadFailed: svc.st = null
  }

  function parse(text) {
    try { svc.st = JSON.parse(text); svc.cliError = "" } catch (e) { svc.cliError = "status.json unreadable" }
  }
  function refresh() { act(["status"], function (o) { if (o && o.state) svc.st = o }) }

  // act: one CLI verb, argv only, --json appended. Never a shell string. A
  // second call while one is in flight is dropped, not queued (matches
  // Panel.qml's existing runner) -- the CLI itself would just serialize the
  // two behind its own flock, but busy would then clear on whichever exits
  // first while the other is still running, and a button gated on busy
  // would lie about that.
  function act(args, onDone) {
    if (svc.busy) return
    svc.busy = true
    var p = actionComponent.createObject(svc, { callback: onDone || null, command: [svc.cli].concat(args).concat(["--json"]) })
    p.running = true
  }
  property Component actionComponent: Component {
    Process {
      id: p
      property var callback: null
      stdout: StdioCollector { id: aOut; waitForEnd: true }
      stderr: StdioCollector { id: aErr; waitForEnd: true }
      onExited: function (code) {
        svc.busy = false
        var obj = null
        try { obj = JSON.parse(aOut.text) } catch (e) {
          svc.cliError = String(aErr.text || aOut.text || ("omabackup returned no JSON (exit " + code + ")")).trim()
        }
        // The engine's refusal shape for a write verb is {ok:false,
        // problems:[...]}; only die/usage_die emit {ok:false, error}.
        // problems[0] wins when present, and must not be cleared by the
        // absence of `error` on the same reply.
        if (obj && obj.problems && obj.problems.length) svc.cliError = obj.problems[0]
        else if (obj && obj.error) svc.cliError = obj.error
        else if (obj) svc.cliError = ""
        if (p.callback) p.callback(obj, code)
        p.destroy()
      }
    }
  }

  // The proven daily path is the systemd unit, so the button asks for that
  // first ("timer run"). The engine replies {ok:false, problems:[...]} when it
  // could start neither the unit nor a detached run (no systemd session, no
  // setsid); only then does the panel run the snapshot itself and wait on it.
  function snapshotNow() {
    act(["timer", "run"], function (o) {
      if (o && o.ok === true) { svc.refresh(); return }
      act(["snapshot"], function () { svc.refresh() })
    })
  }
  function pushOrConfirm(confirm, onDone) { act(confirm ? ["push", "--confirm"] : ["push"], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function timer(verb) { act(["timer", verb], function () { svc.refresh() }) }
  function allow(path, onDone) { act(["allow", path], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function ignore(path, reason, onDone) { act(reason ? ["ignore", path, reason] : ["ignore", path], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function resolveGone(path, verb, onDone) { act(["resolve-gone", path, verb], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function openTerminal() { act(["open"], null) }
  function runSetup() { Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", svc.cli, "setup"]) }

  Component.onCompleted: refresh()
}
