pragma Singleton
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
// Task 18 rewires Panel.qml onto this; nothing here renders UI.
Singleton {
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
  // replaced file is picked up, then re-read.
  FileView {
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

  // act: one CLI verb, argv only, --json appended. Never a shell string.
  function act(args, onDone) {
    var p = actionComponent.createObject(svc, { callback: onDone || null, command: [svc.cli].concat(args).concat(["--json"]) })
    svc.busy = true
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
        if (obj && obj.error) svc.cliError = obj.error
        if (p.callback) p.callback(obj, code)
        p.destroy()
      }
    }
  }

  function snapshotNow() { act(["snapshot"], function () { svc.refresh() }) }
  function pushOrConfirm(confirm, onDone) { act(confirm ? ["push", "--confirm"] : ["push"], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function timer(verb) { act(["timer", verb], function () { svc.refresh() }) }
  function allow(path, onDone) { act(["allow", path], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function ignore(path, reason, onDone) { act(reason ? ["ignore", path, reason] : ["ignore", path], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function resolveGone(path, verb, onDone) { act(["resolve-gone", path, verb], function (o) { svc.refresh(); if (onDone) onDone(o) }) }
  function openTerminal() { act(["open"], null) }
  function runSetup() { Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", svc.cli, "setup"]) }

  Component.onCompleted: refresh()
}
