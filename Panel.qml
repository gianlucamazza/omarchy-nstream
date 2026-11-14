import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons

// nstream remote: the cast in progress (play/pause, seek, volume, subtitle shift,
// stop) and continue-watching, cast to the TV or played locally in mpv. Data and
// actions come from helper.py, which drives `nstream --json` and validates every
// argument; everything it returns is shown as plain text.
BarWidget {
  id: root
  moduleName: "gianlucamazza.nstream"

  property bool opened: false
  property string target: "cast"
  property bool targetChosen: false

  property var entries: []
  property var session: null
  property var status: null
  property real watchSequence: 0
  property real watchReceived: 0
  property bool watchCompatible: false
  property real sampledAt: 0
  property string connectionState: "idle"
  property real clockNow: Date.now()
  readonly property bool telemetryStale: casting && (connectionState !== "connected" ||
      sampledAt <= 0 || clockNow / 1000 - sampledAt > 10 || clockNow - watchReceived > 5000)
  property int reconnectDelay: 5000
  property string historyError: ""
  property string statusError: ""
  property string localTitle: ""

  property string message: ""
  property bool messageIsError: false
  // Title being started; "" when no continue is running.
  property string starting: ""

  readonly property bool casting: session !== null
  readonly property bool playing: status !== null && status.state === "PLAYING"
  readonly property bool paused: status !== null && status.state === "PAUSED"
  readonly property real duration: status ? status.duration : 0
  readonly property int historyLimit: Math.max(1, Math.min(30, Number(setting("historyLimit", 8)) || 8))
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string helper: Qt.resolvedUrl("helper.py").toString().replace(/^file:\/\//, "")

  readonly property string iconMovie: "󰎁"
  readonly property string iconCast: "󰄙"
  readonly property string iconPlay: "󰐊"
  readonly property string iconPause: "󰏤"
  readonly property string iconStop: "󰓛"
  readonly property string iconBack: "󰑟"
  readonly property string iconForward: "󰈑"

  implicitWidth: iconButton.implicitWidth
  implicitHeight: barSize

  Commons.Translations { id: tr; directory: Qt.resolvedUrl("i18n") }

  function close() { opened = false }
  function helperCommand(args) { return ["python3", "-I", "-B", helper].concat(args) }

  function pollStatus() {
    if (watchProc.running) watchProc.write(JSON.stringify({observe: opened}) + "\n")
  }
  function receiveSnapshot(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { d = null }
    if (!d || d.api_version !== 1 || d.action !== "watch" || !d.ok ||
        !(d.capabilities instanceof Array) || d.capabilities.indexOf("session_guard") < 0 ||
        d.capabilities.indexOf("watch") < 0 || d.capabilities.indexOf("receiver_interest") < 0 ||
        !(d.entries instanceof Array) || d.entries.length > 30 ||
        typeof d.sequence !== "number" || d.sequence <= watchSequence) {
      historyError = tr.t("watch.incompatible")
      watchCompatible = false
      return
    }
    watchCompatible = true
    reconnectDelay = 5000
    watchSequence = d.sequence
    watchReceived = Date.now()
    historyError = ""
    entries = d.entries
    if (!targetChosen) target = d.prefer_cast ? "cast" : "local"
    var next = d.cast_session
    if (next && (typeof next.session_id !== "string" || typeof next.device !== "string")) return
    if (!next || !session || next.session_id !== session.session_id) {
      status = null
      statusError = ""
      message = ""
    }
    session = next || null
    var t = d.telemetry || {}
    connectionState = String(t.connection || "disconnected")
    sampledAt = Number(t.sampled_at || 0)
    if (session && t.status) {
      var s = t.status
      status = { state: String(s.player_state || ""), position: Number(s.position || 0),
        duration: Number(s.duration || 0),
        volume: s.volume_percent === null || s.volume_percent === undefined ? -1 : Number(s.volume_percent) }
      statusError = s.delivery_error ? tr.t("delivery.failed").arg(String(s.delivery_error)) :
        (s.receiver_error ? tr.t("receiver.failed") : "")
    } else if (!session) statusError = ""
  }
  function control(args) {
    if (controlProc.running) return
    message = ""
    if (!watchCompatible || !session) return
    controlProc.sessionId = session.session_id
    controlProc.kind = args[0]
    controlProc.command = helperCommand(args.concat(["--session-id", session.session_id,
      "--device", session.device]))
    controlProc.running = true
  }
  function resumeEntry(entry) {
    if (target === "local") {
      if (localProc.running) return
      localTitle = entry.title
      message = ""
      localProc.command = helperCommand(["continue", "local", entry.title])
      localProc.running = true
      notify(tr.t("notify.local").arg(entry.title), "")
      return
    }
    if (continueProc.running) return
    starting = entry.title
    message = ""
    continueProc.command = helperCommand(["continue", target, entry.title])
    continueProc.running = true
  }

  function notify(summary, body) {
    // Notification bodies support markup even though our panel text is plain.
    var plainBody = String(body).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    Quickshell.execDetached(["notify-send", "-a", "nstream", "-i", "video-x-generic", "--", summary, plainBody])
  }

  function receive(text, kind) {
    var d
    try { d = JSON.parse(text) } catch (e) { d = null }
    if (!d || typeof d !== "object" || d.kind !== kind || typeof d.ok !== "boolean")
      d = { kind: kind, ok: false, error: tr.t("process.failed") }
    if (d.kind === "local") {
      if (!d.ok) {
        messageIsError = true
        message = String(d.error || "")
        notify(tr.t("notify.failed").arg(localTitle), message)
      }
      localTitle = ""
    } else if (d.kind === "continue") {
      var title = starting
      starting = ""
      if (!d.ok) {
        messageIsError = true
        message = String(d.error || "")
        notify(tr.t("notify.failed").arg(title), message)
        return
      }
      messageIsError = false
      message = d.notice ? String(d.notice) : ""
      notify(tr.t("notify.cast").arg(String(d.title || title)), String(d.device || ""))
    } else if (!d.ok) {
      messageIsError = true
      message = String(d.error || "")
    } else if (d.kind === "stop") {
      messageIsError = false
      message = tr.t("command.accepted")
    } else if (d.kind === "open") {
      root.close()
    } else {
      messageIsError = false
      message = tr.t("command.accepted")
    }
  }

  function clock(sec) {
    sec = Math.max(0, Math.floor(Number(sec) || 0))
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
    var mm = (h > 0 && m < 10 ? "0" : "") + m, ss = (s < 10 ? "0" : "") + s
    return (h > 0 ? h + ":" : "") + mm + ":" + ss
  }
  function episodeLabel(e) {
    if (e.type !== "series" || e.season <= 0) return ""
    return "S" + (e.season < 10 ? "0" : "") + e.season + "E" + (e.episode < 10 ? "0" : "") + e.episode
  }
  function entryCaption(e) {
    var parts = []
    var ep = episodeLabel(e)
    if (ep !== "") parts.push(ep)
    if (e.next) parts.push(tr.t("entry.next"))
    else if (e.duration > 0) {
      var pct = Math.round(100 * e.position / e.duration)
      parts.push(tr.t("entry.progress").arg(Commons.I18n.formatNumber(pct, 0)).arg(clock(e.duration - e.position)))
    }
    return parts.join(" · ")
  }
  function heroMeta() {
    if (starting !== "") return tr.t("starting").arg(starting)
    if (!casting) return tr.t("idle")
    var device = session.device || (status ? status.device : "")
    return device !== "" ? tr.t("casting.device").arg(device) : tr.t("casting")
  }
  function stateLabel() {
    if (!status) return connectionState === "disconnected" ? tr.t("state.unavailable") : tr.t("state.unknown")
    if (telemetryStale) return tr.t("state.stale")
    if (playing) return tr.t("state.playing")
    if (paused) return tr.t("state.paused")
    if (status.state === "BUFFERING") return tr.t("state.buffering")
    if (status.state === "IDLE" || status.state === "") return tr.t("state.idle")
    return status.state
  }

  onOpenedChanged: { message = ""; pollStatus() }

  Commons.ShellIpc {
    target: "gianlucamazza.nstream"
    function toggle(): void { root.opened = !root.opened }
    function open(): void { root.opened = true }
    function close(): void { root.opened = false }
    function status(): string {
      return JSON.stringify({api_version: root.watchCompatible ? 1 : null,
        connected: root.watchCompatible && Date.now() - root.watchReceived < 5000,
        sequence: root.watchSequence, connection: root.connectionState,
        stale: root.telemetryStale, observing: root.opened})
    }
  }

  component HelperProcess: Process {
    id: proc
    property string kind: ""
    property string sessionId: ""
    property bool received: false
    onRunningChanged: if (running) received = false
    stdout: StdioCollector {
      onStreamFinished: {
        proc.received = true
        if (proc !== controlProc || (root.session && root.session.session_id === proc.sessionId))
          root.receive(text, proc.kind)
      }
    }
    onExited: {
      if (!received && (proc !== controlProc || (root.session && root.session.session_id === proc.sessionId)))
        root.receive("", kind)
      if (proc === controlProc && root.opened) root.pollStatus()
    }
  }
  HelperProcess { id: controlProc }
  HelperProcess { id: continueProc; kind: "continue" }
  HelperProcess { id: localProc; kind: "local" }

  Process {
    id: watchProc
    command: root.helperCommand(["watch"])
    stdinEnabled: true
    running: true
    onStarted: {
      root.watchSequence = 0
      root.watchCompatible = false
      root.pollStatus()
    }
    stdout: SplitParser { onRead: data => root.receiveSnapshot(data) }
    stderr: StdioCollector {}
    onExited: {
      root.watchCompatible = false
      root.connectionState = "disconnected"
      if (root.historyError === "") root.historyError = tr.t("watch.unavailable")
      reconnectTimer.start()
    }
  }
  Timer {
    id: reconnectTimer
    interval: root.reconnectDelay
    onTriggered: {
      root.reconnectDelay = Math.min(30000, root.reconnectDelay * 2)
      watchProc.running = true
    }
  }
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.clockNow = Date.now()
  }

  component Plain: Text {
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    color: Commons.Color.foreground
    elide: Text.ElideRight
  }
  component Caption: Plain { font.pixelSize: Style.font.caption; opacity: 0.6 }

  BarIconButton {
    id: iconButton
    bar: root.bar
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.casting ? root.iconCast : root.iconMovie
    dimmed: !root.casting && root.starting === ""
    tooltipText: root.casting
      ? tr.t("tooltip.casting").arg(root.session.title || "?")
      : root.starting !== "" ? tr.t("starting").arg(root.starting) : tr.t("title")
    onPressed: function(button) { if (button === Qt.LeftButton) root.opened = !root.opened }
  }

  KeyboardPanel {
    id: panel
    anchorItem: iconButton; owner: root; bar: root.bar; open: root.opened
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(Math.min(Style.space(600), body.implicitHeight))
    focusTarget: viewport
    Flickable {
      id: viewport
      anchors.fill: parent; clip: true
      contentWidth: width; contentHeight: body.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      Keys.onEscapePressed: root.close()
      Column {
        id: body
        width: viewport.width
        spacing: Style.space(10)

        Ui.PanelHero {
          width: parent.width
          title: tr.t("title")
          meta: root.heroMeta()
          trailingControl: Component {
            Ui.Button {
              text: tr.t("open")
              enabled: !controlProc.running
              onClicked: root.control(["open"])
            }
          }
        }
        Plain {
          width: parent.width
          visible: root.message !== ""
          text: root.message
          wrapMode: Text.Wrap; elide: Text.ElideNone
          maximumLineCount: 6
          font.pixelSize: Style.font.bodySmall
          color: root.messageIsError ? root.urgent : Commons.Color.foreground
        }

        // Now playing on the TV
        Plain {
          width: parent.width
          visible: root.statusError !== ""
          text: root.statusError
          color: root.urgent
          wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 4
        }
        Column {
          width: parent.width
          visible: root.casting
          spacing: Style.space(6)
          Plain { width: parent.width; text: root.session ? root.session.title : ""; elide: Text.ElideMiddle }
          Caption {
            width: parent.width
            text: root.stateLabel() + (root.duration > 0
              ? " · " + root.clock(root.status.position) + " / " + root.clock(root.duration) : "")
          }
          Ui.PanelSlider {
            id: seekSlider
            enabled: root.watchCompatible && !controlProc.running
            width: parent.width
            bar: root.bar
            visible: root.duration > 0
            minimum: 0
            maximum: Math.max(1, root.duration)
            step: 1
            value: root.status ? root.status.position : 0
            onReleased: function(value) { root.control(["seekto", String(Math.round(value))]) }
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            Ui.PanelActionButton {
              iconText: root.iconBack; tooltipText: tr.t("act.back")
              enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control(["seek", "-30"])
            }
            Ui.PanelActionButton {
              iconText: root.playing ? root.iconPause : root.iconPlay
              tooltipText: root.playing ? tr.t("act.pause") : tr.t("act.play")
              enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control([root.playing ? "pause" : "resume"])
            }
            Ui.PanelActionButton {
              iconText: root.iconForward; tooltipText: tr.t("act.forward")
              enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control(["seek", "30"])
            }
            Ui.PanelActionButton {
              iconText: root.iconStop; tooltipText: tr.t("act.stop")
              hoverColor: root.urgent
              enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control(["stop"])
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.status !== null && root.status.volume >= 0
            Caption { id: volumeLabel; anchors.verticalCenter: parent.verticalCenter; text: tr.t("volume") }
            Ui.PanelSlider {
              enabled: root.watchCompatible && !controlProc.running
              width: parent.width - volumeLabel.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              minimum: 0; maximum: 100; step: 1; integer: true
              value: root.status ? root.status.volume : 0
              onReleased: function(value) { root.control(["volume", String(Math.round(value))]) }
            }
          }
          Row {
            spacing: Style.space(4)
            Caption { anchors.verticalCenter: parent.verticalCenter; text: tr.t("subtitles") }
            Ui.Button {
              text: tr.t("sub.earlier"); bordered: true; enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control(["subshift", "-0.5"])
            }
            Ui.Button {
              text: tr.t("sub.later"); bordered: true; enabled: root.watchCompatible && !controlProc.running
              onClicked: root.control(["subshift", "0.5"])
            }
          }
          Ui.PanelSeparator { width: parent.width }
        }

        // Continue watching
        Ui.PanelSectionHeader { width: parent.width; text: tr.t("continue") }
        Caption {
          width: parent.width
          visible: root.localTitle !== ""
          text: tr.t("local.pending").arg(root.localTitle)
          wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 3
        }
        Ui.ButtonGroup {
          focusable: false
          value: root.target
          options: [
            { value: "cast", label: tr.t("target.cast") },
            { value: "local", label: tr.t("target.local") }
          ]
          onChanged: function(value) { root.target = value; root.targetChosen = true }
        }
        Column {
          width: parent.width
          spacing: Style.space(2)
          Caption {
            width: parent.width
            visible: root.historyError !== "" || root.entries.length === 0
            text: root.historyError !== "" ? root.historyError : tr.t("empty")
            wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 4
          }
          Repeater {
            model: root.entries.slice(0, root.historyLimit)
            Item {
              id: entryRow
              required property var modelData
              width: parent ? parent.width : 0
              implicitHeight: Math.max(entryText.implicitHeight, playButton.implicitHeight) + Style.space(8)
              opacity: root.starting !== "" && root.starting !== modelData.title ? 0.45 : 1
              Column {
                id: entryText
                anchors.left: parent.left
                anchors.right: playButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Plain { width: parent.width; text: entryRow.modelData.title }
                Caption { width: parent.width; text: root.entryCaption(entryRow.modelData); visible: text !== "" }
              }
              Ui.PanelActionButton {
                id: playButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconPlay
                tooltipText: root.target === "cast" ? tr.t("act.castHere") : tr.t("act.playHere")
                enabled: root.target === "local" ? !localProc.running : !continueProc.running
                onClicked: root.resumeEntry(entryRow.modelData)
              }
            }
          }
        }
      }
    }
  }
}
