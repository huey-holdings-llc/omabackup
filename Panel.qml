import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"

// Backup Status bar widget: a glanceable badge for the hp-laptop-config backup
// engine, and a popup that renders `bin/widget-helper.sh status` verbatim.
//
// ALL judgment lives in the helper -- it is versioned, linted and self-tested
// with the engine (self-test groups 50/51). This file renders that JSON and
// shells back into helper subcommands; it never decides anything about
// backups itself, and it never builds shell strings (argv only).
Panel {
  id: root
  moduleName: "io.github.coreytyhurst.backup-status"
  ipcTarget: "io.github.coreytyhurst.backup-status"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string repoDir: String(setting("repoDir", "~/projects/hp-laptop-config")).replace(/^~/, home)
  readonly property string helper: repoDir + "/bin/widget-helper.sh"

  // Last parsed status JSON; null until the first poll answers.
  property var st: null
  property string helperError: ""
  property string actionError: ""
  property bool busy: false
  property bool confirmOpen: false
  // path -> "allowlisted" | "ignored" | "resolved": decisions taken in this
  // session, so handled rows dim instead of re-offering their buttons (the
  // drift report itself only changes on the next snapshot).
  property var handled: ({})
  // How many drift rows the popup lists before folding into "and N more".
  readonly property int driftShown: 10

  readonly property string sysState: helperError ? "fault" : (st && st.state ? st.state : "unknown")
  readonly property var drift: st && st.drift ? st.drift : []
  readonly property int driftCount: st && st.drift_count ? st.drift_count : 0
  readonly property var problems: st && st.problems ? st.problems : []
  readonly property var uncommitted: st && st.uncommitted ? st.uncommitted : []
  readonly property int unpushed: st && st.unpushed ? st.unpushed : 0
  readonly property bool timerKnown: !!(st && st.timers_checked)
  readonly property bool timerArmed: !!(st && st.timer_enabled && st.timer_active)

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
    : sysState === "attention" ? (driftCount > 0 ? driftCount + " path(s) to triage" : "Repo edits pending commit")
    : "Healthy · snapshot " + ageText()

  // Quiet glyph when healthy, a count while there is drift to triage, and the
  // alert triangle in the urgent colour for anything fail-closed would flag.
  readonly property string barGlyph: sysState === "fault" ? "󰀦" : "󰆓"
  readonly property string barLabel: sysState === "attention" && driftCount > 0 && !vertical ? " " + driftCount : ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { if (!statusProc.running) statusProc.running = true }

  // ---- actions: every button is one helper subcommand, argv only ----
  function act(args, onDone) {
    if (busy) return
    busy = true
    var p = actionComponent.createObject(root, { command: [helper].concat(args), callback: onDone || null })
    p.running = true
  }
  function allowPath(path) {
    act(["allow", path], function(rep) { if (rep && rep.ok) root.markHandled(path, "allowlisted") })
  }
  function ignorePath(path, reason) {
    var args = reason && reason.length ? ["ignore", path, reason] : ["ignore", path]
    act(args, function(rep) { if (rep && rep.ok) root.markHandled(path, "ignored") })
  }
  function resolveGone(path, verb) {
    act(["resolve-gone", path, verb], function(rep) { if (rep && rep.ok) root.markHandled(path, "resolved") })
  }
  function markHandled(path, verdict) {
    var h = {}
    for (var k in handled) h[k] = handled[k]
    h[path] = verdict
    handled = h
  }
  function runSnapshot() {
    act(["snapshot"])
    // The scan rewrites drift.txt over the next minute or so; re-poll when it
    // has had a chance to finish instead of showing a mid-write report.
    handled = {}
    snapshotSettle.restart()
  }
  function pushOrConfirm() {
    if (root.uncommitted.length > 0) { confirmOpen = !confirmOpen; return }
    if (root.unpushed > 0) act(["push"])
  }
  function confirmPush() {
    confirmOpen = false
    act(["push", "--confirm"])
  }
  function openTriage() { root.close(); act(["triage-terminal"]) }

  onOpenedChanged: if (opened) {
    confirmOpen = false
    refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      try {
        root.st = JSON.parse(statusOut.text)
        root.helperError = ""
      } catch (e) {
        root.st = null
        root.helperError = "Backup helper unreachable (" + root.helper + ")"
      }
    }
  }

  property Component actionComponent: Component {
    Process {
      id: p
      property var callback: null
      stdout: StdioCollector { id: aOut; waitForEnd: true }
      stderr: StdioCollector { waitForEnd: true }
      onExited: function(code) {
        var rep = null
        try { rep = JSON.parse(aOut.text) } catch (e) {}
        root.actionError = (rep && rep.ok === true) ? ""
          : (rep && rep.problems && rep.problems.length ? rep.problems[0] : "helper action failed (exit " + code + ")")
        if (callback) callback(rep)
        root.busy = false
        root.refresh()
        p.destroy()
      }
    }
  }

  // The badge stays honest while the panel is closed: same 10-minute cadence
  // the config-sync ecosystem uses, cheap read-only git + file reads.
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: driftColumn.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.runSnapshot()
        else if (t === "p" || t === "P") root.pushOrConfirm()
        else if (t === "t" || t === "T") root.openTriage()
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

          PanelSectionHeader {
            text: root.driftCount > 0 ? "DRIFT · " + root.driftCount : "DRIFT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.driftCount === 0 && root.st !== null
            width: parent.width
            text: "Nothing unbacked. Every allowlisted path is captured."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            id: driftColumn
            width: parent.width
            spacing: Style.spacing.xxs
            // Reason fields grab the keyboard; the key catcher must let them.
            readonly property bool editing: {
              for (var i = 0; i < driftRepeater.count; i++) {
                var it = driftRepeater.itemAt(i)
                if (it && it.reasonOpen) return true
              }
              return false
            }
            Repeater {
              id: driftRepeater
              model: root.drift.slice(0, root.driftShown)
              delegate: DriftRow {
                required property var modelData
                width: driftColumn.width
                entry: modelData
                verdict: root.handled[modelData.path] || ""
                busy: root.busy
                foreground: root.foreground
                dimColor: root.dim
                urgent: root.urgent
                fontFamily: root.fontFamily
                onAllowRequested: function(path) { root.allowPath(path) }
                onIgnoreRequested: function(path, reason) { root.ignorePath(path, reason) }
                onGoneRequested: function(path, verb) { root.resolveGone(path, verb) }
              }
            }
          }

          Text {
            visible: root.driftCount > root.driftShown
            width: parent.width
            text: "… and " + (root.driftCount - root.driftShown) + " more · Full triage handles the rest (t)"
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
            text: "s snapshot · p push · t triage · r refresh · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
