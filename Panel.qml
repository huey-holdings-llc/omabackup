import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"

// OmaBackup bar widget: a glanceable badge for the config-backup engine, and
// a popup that renders Service.qml's status.json.
//
// ALL judgment lives in bin/omabackup and lib/*.sh -- versioned, linted and
// self-tested with the engine. This file is a view over the Service
// singleton: it renders svc.st and calls svc functions, which run CLI verbs
// as argv (never a shell string) and never decide anything about backups
// themselves.
//
// Triage is meant to feel like clearing a todo list: drifting files are
// grouped by folder so one click can take a whole directory, handled rows
// disappear immediately, and notes are optional (a toggle, off by default).
Panel {
  id: root
  moduleName: "io.github.huey-holdings-llc.omabackup"
  ipcTarget: "io.github.huey-holdings-llc.omabackup"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // The Service.qml singleton, handed over by the shell host the same way
  // omarecorder's Panel.qml pulls its own service (there is no QML module
  // import for it -- Service.qml is loaded and registered by the shell,
  // keyed by plugin id, and shared across every panel/widget instance).
  readonly property var svc: bar && bar.shell && bar.shell.serviceFor ? bar.shell.serviceFor(moduleName) : null
  readonly property bool svcReady: svc !== null

  // Last parsed status JSON; null until the service's first read answers.
  readonly property var st: svcReady ? svc.st : null
  readonly property string helperError: svcReady ? svc.cliError : "OmaBackup service unavailable"
  property string actionError: ""
  readonly property bool busy: svcReady ? svc.busy : false
  readonly property string setupState: svcReady ? svc.setup : "not-configured"
  property bool confirmOpen: false
  // Off by default: Ignore acts immediately with a dated default reason.
  // On: the shared note field opens first so a reason can be recorded.
  property bool askNotes: false
  // {path: ...} while the note field waits for a reason for that ignore.
  property var pendingNote: null

  // Decisions taken this session. The drift report itself only changes on the
  // next snapshot, so handled entries are filtered out locally: rows vanish
  // as they are dealt with. handledRev bumps to recompute the bindings.
  property var handledPaths: ({})
  property var handledPrefixes: []
  property int handledRev: 0

  readonly property string sysState: helperError ? "fault" : (st && st.state ? st.state : "unknown")
  readonly property var drift: st && st.drift ? st.drift : []
  readonly property int driftCount: st && st.drift_count ? st.drift_count : 0
  readonly property var problems: st && st.problems ? st.problems : []
  readonly property var uncommitted: st && st.uncommitted ? st.uncommitted : []
  readonly property int unpushed: st && st.unpushed ? st.unpushed : 0
  readonly property bool timerKnown: !!(st && st.timers_checked)
  readonly property bool timerArmed: !!(st && st.timer_enabled && st.timer_active)

  // Folder bucket for a drift path: per-app under the XDG-ish roots, the
  // top-level folder otherwise, null for a file that has no useful bucket.
  function groupKey(path) {
    var p = String(path).replace(/^~\//, "").replace(/\/$/, "")
    var segs = p.split("/")
    var take = 1
    if (segs[0] === ".config" || segs[0] === ".cache") take = 2
    else if (segs[0] === ".local" && segs.length > 1 && (segs[1] === "share" || segs[1] === "state" || segs[1] === "bin")) take = 3
    if (segs.length <= take) return null
    return "~/" + segs.slice(0, take).join("/") + "/"
  }

  function isHandled(path) {
    if (handledPaths[path]) return true
    for (var i = 0; i < handledPrefixes.length; i++)
      if (path.indexOf(handledPrefixes[i]) === 0) return true
    return false
  }

  // The triage model: NEW files bucketed into folder groups (biggest first),
  // everything else (and single-file buckets) as plain rows, handled entries
  // dropped entirely.
  readonly property var driftView: {
    var _ = handledRev
    var files = [], groups = {}, order = [], handledN = 0
    for (var i = 0; i < drift.length; i++) {
      var e = drift[i]
      if (isHandled(e.path)) { handledN++; continue }
      var k = e.type === "NEW" ? groupKey(e.path) : null
      if (!k) { files.push(e); continue }
      if (!(k in groups)) { groups[k] = []; order.push(k) }
      groups[k].push(e)
    }
    var glist = []
    for (var j = 0; j < order.length; j++) {
      if (groups[order[j]].length === 1) files.push(groups[order[j]][0])
      else glist.push({ path: order[j], entries: groups[order[j]] })
    }
    glist.sort(function(a, b) { return b.entries.length - a.entries.length })
    return { groups: glist, files: files, handledN: handledN }
  }
  readonly property int remainingDrift: Math.max(0, driftCount - driftView.handledN)
  readonly property int shownFiles: 250

  function ageText() {
    if (!st || !st.last_run) return "never"
    var s = Math.max(0, Math.floor(Date.now() / 1000) - st.last_run)
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  readonly property string stateText: helperError ? helperError
    : !st ? "Checking…"
    : sysState === "fault" ? (problems.length ? problems[0] : "Needs attention")
    : sysState === "attention" ? (
        remainingDrift > 0 ? remainingDrift + " path(s) to triage"
        : driftCount > 0 ? "All triaged · Snapshot applies it"
        : "Repo edits pending commit")
    : "Healthy · snapshot " + ageText()

  // Quiet glyph when healthy, a count while there is drift to triage, and the
  // alert triangle in the urgent colour for anything fail-closed would flag.
  readonly property string barGlyph: sysState === "fault" ? "󰀦" : "󰆓"
  readonly property string barLabel: sysState === "attention" && remainingDrift > 0 && !vertical ? " " + remainingDrift : ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { if (root.svc) root.svc.refresh() }

  // ---- actions: every call runs one CLI verb through the service, argv
  // only. actionError mirrors the JSON contract's {ok, error} shape (Task
  // 17's act comment) so a failed action still says why, same as before.
  function act(args, onDone) {
    if (!root.svc) return
    root.svc.act(args, function(rep, code) {
      root.actionError = (rep && rep.ok === true) ? ""
        : (rep && rep.error ? rep.error : "omabackup action failed (exit " + code + ")")
      if (onDone) onDone(rep, code)
    })
  }
  function markHandled(path) {
    if (path.charAt(path.length - 1) === "/") handledPrefixes.push(path)
    else handledPaths[path] = true
    handledRev++
  }
  function allowPath(path) {
    if (!root.svc) return
    root.svc.allow(path, function(rep) {
      root.actionError = (rep && rep.ok === true) ? "" : (rep && rep.error ? rep.error : "allow failed")
      if (rep && rep.ok) root.markHandled(path)
    })
  }
  // The ignore entry point every button uses. With notes on, park the path
  // and let the shared note field collect a reason first.
  function ignorePath(path) {
    if (askNotes) { pendingNote = { path: path }; Qt.callLater(function() { noteField.forceActiveFocus() }); return }
    commitIgnore(path, "")
  }
  function commitIgnore(path, reason) {
    pendingNote = null
    if (!root.svc) return
    root.svc.ignore(path, reason, function(rep) {
      root.actionError = (rep && rep.ok === true) ? "" : (rep && rep.error ? rep.error : "ignore failed")
      if (rep && rep.ok) root.markHandled(path)
    })
  }
  function resolveGone(path, verb) {
    if (!root.svc) return
    root.svc.resolveGone(path, verb, function(rep) {
      root.actionError = (rep && rep.ok === true) ? "" : (rep && rep.error ? rep.error : "resolve failed")
      if (rep && rep.ok) root.markHandled(path)
    })
  }
  function runSnapshot() {
    if (root.svc) root.svc.snapshotNow()
    // The next report is ground truth for what the decisions actually silenced.
    handledPaths = {}; handledPrefixes = []; handledRev++
    snapshotSettle.restart()
  }
  function pushOrConfirm() {
    if (root.uncommitted.length > 0) { confirmOpen = !confirmOpen; return }
    if (!root.svc) return
    if (root.unpushed > 0) root.svc.pushOrConfirm(false, function(rep) {
      root.actionError = (rep && rep.ok === true) ? "" : (rep && rep.error ? rep.error : "push failed")
    })
  }
  function confirmPush() {
    confirmOpen = false
    if (!root.svc) return
    root.svc.pushOrConfirm(true, function(rep) {
      root.actionError = (rep && rep.ok === true) ? "" : (rep && rep.error ? rep.error : "push failed")
    })
  }
  function openTriage() { root.close(); if (root.svc) root.svc.openTerminal() }
  function setupAction() {
    if (!root.svc) return
    if (root.setupState === "not-configured") root.svc.runSetup()
    else if (root.setupState === "gitleaks-missing") Quickshell.execDetached(["wl-copy", "sudo pacman -S gitleaks"])
    else if (root.setupState === "remote-unverified") Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.svc.cli, "setup", "--trust-remote", "--yes"])
  }

  onOpenedChanged: if (opened) {
    confirmOpen = false
    pendingNote = null
    refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  Component.onCompleted: refresh()

  // The badge stays honest while the panel is closed: same 10-minute cadence
  // the config-sync ecosystem uses, cheap read-only git + file reads. The
  // service's FileView already reacts to status.json changing on disk; this
  // is what actually re-triggers a `status` write between snapshots.
  Timer {
    interval: 600000; repeat: true; running: true
    onTriggered: root.refresh()
  }
  Timer { id: snapshotSettle; interval: 45000; onTriggered: root.refresh() }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.stateText }
    function refresh(): void { root.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    Accessible.role: Accessible.Button
    Accessible.name: "Config backup: " + root.stateText
    text: root.barGlyph + root.barLabel
    active: root.sysState === "fault"
    fontSize: root.barLabel ? Style.font.bodySmall : Style.bar.iconFont
    tooltipText: "Config backup: " + root.stateText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: noteField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.runSnapshot()
        else if (t === "p" || t === "P") root.pushOrConfirm()
        else if (t === "t" || t === "T") root.openTriage()
        else if (t === "n" || t === "N") root.askNotes = !root.askNotes
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ThinScrollBar { id: panelBar; foreground: root.foreground }

        Column {
          id: column
          width: panelFlick.width - (panelFlick.contentHeight > panelFlick.height ? panelBar.width + Style.spacing.xs : 0)
          spacing: Style.spacing.md

          PanelHero {
            id: hero
            readonly property string heroState: root.sysState
            width: parent.width
            title: "Config Backup"
            meta: root.stateText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: hero.heroState === "fault" ? "󰀦" : hero.heroState === "attention" ? "󰆓" : "󰄬"
                color: hero.heroState === "fault" ? root.urgent : hero.heroState === "attention" ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.actionError.length > 0
            width: parent.width
            text: root.actionError
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // Every fail-closed reason the helper found, verbatim.
          Column {
            visible: root.problems.length > 0
            width: parent.width
            spacing: Style.spacing.xxs
            Repeater {
              model: root.problems
              delegate: Text {
                required property var modelData
                width: parent.width
                text: "󰀦 " + modelData
                textFormat: Text.PlainText
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }
          }

          // Zone 1: the vitals, one line each.
          Column {
            width: parent.width
            spacing: Style.spacing.xxs
            InfoRow { width: parent.width; label: "Last snapshot"; value: root.ageText(); foreground: root.foreground; dimColor: root.dim; fontFamily: root.fontFamily }
            Item {
              visible: root.timerKnown
              width: parent.width
              implicitHeight: timerRow.implicitHeight
              InfoRow {
                id: timerRow
                anchors.left: parent.left; anchors.right: timerToggle.left; anchors.rightMargin: Style.spacing.sm
                label: "Next run"
                value: root.timerArmed && root.st && root.st.timer_next ? root.st.timer_next.replace(/:\d\d [A-Z]{3,4}$/, "") : "timer paused"
                valueColor: root.timerArmed ? "" : root.urgent
                foreground: root.foreground; dimColor: root.dim; fontFamily: root.fontFamily
              }
              AccessibleActionButton {
                id: timerToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: !root.busy
                iconText: root.timerArmed ? "󰏤" : "󰐊"
                tooltipText: root.timerArmed ? "Pause the daily snapshot timer" : "Resume the daily snapshot timer"
                foreground: root.timerArmed ? root.foreground : root.urgent
                fontFamily: root.fontFamily
                onClicked: root.act(["timer", root.timerArmed ? "pause" : "resume"])
              }
            }
            InfoRow {
              width: parent.width; label: "Pushed"
              value: root.unpushed > 0 ? root.unpushed + " commit(s) waiting" : "up to date"
              valueColor: root.unpushed > 0 ? root.urgent : ""
              foreground: root.foreground; dimColor: root.dim; fontFamily: root.fontFamily
            }
            InfoRow {
              visible: root.uncommitted.length > 0
              width: parent.width; label: "Repo edits"
              value: root.uncommitted.length + " uncommitted"
              foreground: root.foreground; dimColor: root.dim; fontFamily: root.fontFamily
            }
          }

          // Confirm gate for the dynamic push button: show exactly what would
          // be committed (the helper stages exactly these paths, never -A).
          Column {
            visible: root.confirmOpen && root.uncommitted.length > 0
            width: parent.width
            spacing: Style.spacing.xxs
            PanelSectionHeader { text: "COMMIT & PUSH"; foreground: root.foreground; fontFamily: root.fontFamily }
            Repeater {
              model: root.uncommitted
              delegate: Text {
                required property var modelData
                width: parent.width
                text: modelData
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }
            Row {
              width: parent.width
              spacing: Style.spacing.sm
              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Commit & push"
                iconText: "󰛃"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: root.confirmPush()
              }
              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Cancel"
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.confirmOpen = false
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // Not-ready setup states get one card with a single fix-it action;
          // "ready" and "fault" hide it ("fault" is already covered by the
          // problems list above).
          SetupCard {
            visible: root.setupState !== "ready" && root.setupState !== "fault"
            width: parent.width
            mode: root.setupState
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
            onAction: root.setupAction()
          }

          // Zone 2: triage. Header carries the notes toggle; folder groups
          // first (biggest wins), then loose files; handled rows are gone.
          Item {
            width: parent.width
            implicitHeight: driftHeader.implicitHeight
            PanelSectionHeader {
              id: driftHeader
              anchors.left: parent.left
              anchors.right: notesToggle.left
              text: root.remainingDrift > 0 ? "DRIFT · " + root.remainingDrift + " to go" : "DRIFT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            AccessibleActionButton {
              id: notesToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰏫"
              tooltipText: root.askNotes ? "Notes on: each Ignore asks for a reason (n)" : "Notes off: Ignore acts instantly with a dated default (n)"
              foreground: root.askNotes ? Color.accent : root.dim
              fontFamily: root.fontFamily
              onClicked: root.askNotes = !root.askNotes
            }
          }

          Text {
            visible: root.driftView.handledN > 0
            width: parent.width
            text: "󰄬 " + root.driftView.handledN + " handled this session · Snapshot applies the decisions (s)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The shared note field (notes mode): one ignore is parked here
          // until a reason is typed. Enter records it, Esc cancels.
          Column {
            visible: root.pendingNote !== null
            width: parent.width
            spacing: Style.spacing.xxs
            Text {
              width: parent.width
              text: "Note for " + (root.pendingNote ? root.pendingNote.path : "")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
            TextField {
              id: noteField
              width: parent.width
              placeholderText: "why this is not worth backing up · Enter records it, Esc skips the note"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: { var pn = root.pendingNote; if (pn) root.commitIgnore(pn.path, text.trim()); text = ""; keyCatcher.forceActiveFocus() }
              Keys.onEscapePressed: { var pn = root.pendingNote; root.pendingNote = null; text = ""; if (pn) root.commitIgnore(pn.path, ""); keyCatcher.forceActiveFocus() }
            }
          }

          Text {
            visible: root.remainingDrift === 0 && root.st !== null
            width: parent.width
            text: root.driftCount > 0 ? "All triaged. Run Snapshot to apply and re-scan." : "Nothing unbacked. Every allowlisted path is captured."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            id: driftColumn
            width: parent.width
            spacing: Style.spacing.xxs
            Repeater {
              model: root.driftView.groups
              delegate: DriftGroupRow {
                required property var modelData
                width: driftColumn.width
                path: modelData.path
                entries: modelData.entries
                busy: root.busy
                foreground: root.foreground
                dimColor: root.dim
                urgent: root.urgent
                fontFamily: root.fontFamily
                onAllowRequested: function(path) { root.allowPath(path) }
                onIgnoreRequested: function(path) { root.ignorePath(path) }
                onGoneRequested: function(path, verb) { root.resolveGone(path, verb) }
              }
            }
            Repeater {
              model: root.driftView.files.slice(0, root.shownFiles)
              delegate: DriftRow {
                required property var modelData
                width: driftColumn.width
                entry: modelData
                busy: root.busy
                foreground: root.foreground
                dimColor: root.dim
                urgent: root.urgent
                fontFamily: root.fontFamily
                onAllowRequested: function(path) { root.allowPath(path) }
                onIgnoreRequested: function(path) { root.ignorePath(path) }
                onGoneRequested: function(path, verb) { root.resolveGone(path, verb) }
              }
            }
          }

          Text {
            visible: root.driftView.files.length > root.shownFiles || (root.st && root.st.drift_truncated)
            width: parent.width
            text: root.driftView.files.length > root.shownFiles
              ? "… and " + (root.driftView.files.length - root.shownFiles) + " more loose files · handle some and they appear"
              : "… report truncated at " + root.drift.length + " entries"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Zone 3: the footer actions.
          Row {
            width: parent.width
            spacing: Style.spacing.sm
            Button {
              width: (parent.width - parent.spacing * 2) * 0.34
              text: "Snapshot  (s)"
              iconText: "󰆓"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.runSnapshot()
            }
            Button {
              width: (parent.width - parent.spacing * 2) * 0.33
              visible: root.uncommitted.length > 0 || root.unpushed > 0
              text: root.uncommitted.length > 0 ? "Commit…  (p)" : "Push  (p)"
              iconText: "󰛃"
              foreground: root.unpushed > 0 ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.pushOrConfirm()
            }
            Button {
              width: (parent.width - parent.spacing * 2) * 0.33
              text: "Triage  (t)"
              iconText: ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.openTriage()
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "s snapshot · p push · t triage · n notes · r refresh · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
