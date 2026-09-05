import QtQuick
import qs.Commons
import qs.Ui

// Shown above the drift list while Service.setup has not reached "ready":
// one line explaining what is blocking push (or setup itself), plus a single
// action button. Panel.qml owns visibility (hidden once ready, and also on
// fault, where the problems list already covers it).
Column {
  id: root
  property string mode: "not-configured"   // not-configured | gitleaks-missing | remote-unverified
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  signal action()

  readonly property var copy: ({
    "not-configured":    { title: "OmaBackup is not set up", body: "Create a private data repo, seed the lists, and install the daily timer.", button: "Set up OmaBackup" },
    "gitleaks-missing":  { title: "Push is off: gitleaks is not installed", body: "Snapshots commit locally. Install gitleaks to let them push.", button: "Copy install command" },
    "remote-unverified": { title: "Push is off: remote not verified", body: "OmaBackup cannot check that this remote is private. Setup opens in a terminal and asks whether to push to it anyway.", button: "Review remote in setup" }
  })
  readonly property var entry: root.copy[root.mode] || root.copy["not-configured"]

  // A brief inline confirmation after the copy click. There is no shared
  // toast component in this kit, so the button label itself carries the
  // feedback for a couple of seconds instead.
  property bool justCopied: false
  Timer { id: copiedTimer; interval: 2500; onTriggered: root.justCopied = false }

  width: parent ? parent.width : Style.space(300)
  spacing: Style.spacing.xs

  PanelSectionHeader { text: "SETUP"; foreground: root.urgent; fontFamily: root.fontFamily }

  Text {
    width: root.width
    text: root.entry.title
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    wrapMode: Text.Wrap
  }

  Text {
    width: root.width
    text: root.entry.body
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.8
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  Button {
    width: root.width
    text: root.mode === "gitleaks-missing" && root.justCopied ? "Copied. Paste it in a terminal" : root.entry.button
    iconText: "󰒓"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: {
      if (root.mode === "gitleaks-missing") { root.justCopied = true; copiedTimer.restart() }
      root.action()
    }
  }
}
