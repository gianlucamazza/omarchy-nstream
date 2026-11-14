import QtQuick
import QtQuick.Controls as QQC
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
  property bool showSubtitleTiming: false

  property var entries: []
  property var historyRows: []
  property string historyRowsSignature: ""
  onTargetChanged: { refreshHistoryRows(); historyViewport.contentY = 0 }
  property var session: null
  property var localSession: null
  property bool canTransfer: false
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
    canTransfer = d.capabilities.indexOf("transfer") >= 0
    var nextLocal = d.local_session || null
    if (JSON.stringify(localSession) !== JSON.stringify(nextLocal)) localSession = nextLocal
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
    if (JSON.stringify(session) !== JSON.stringify(next || null)) session = next || null
    refreshHistoryRows()
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
  function openNstream() {
    if (openProc.running) return
    message = ""
    openProc.command = helperCommand(["open"])
    openProc.running = true
  }
  function transferTo(target, identity) {
    if (!canTransfer || transferProc.running || controlProc.running || continueProc.running || localProc.running) return
    var origin = target === "local" ? session : target === "cast" ? localSession : null
    if (!origin || origin.transferable !== true || origin.session_id !== identity) return
    if (target === "local" ? localSession !== null : session !== null) return
    message = tr.t("transfer.pending")
    messageIsError = false
    transferProc.command = helperCommand(["transfer", target, identity])
    transferProc.running = true
  }
  function control(args) {
    if (controlProc.running || transferProc.running) return
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
    if (d.kind === "transfer") {
      messageIsError = !d.ok
      message = d.ok ? tr.t("transfer.done").arg(d.target === "cast" ? tr.t("target.cast") : tr.t("target.local"))
        : String(d.error || tr.t("transfer.failed"))
    } else if (d.kind === "local") {
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
      if (d.result === "already_open") {
        messageIsError = false
        message = tr.t("open.already")
      } else root.close()
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
  function historyEntries() {
    if (!casting || target !== "cast") return entries
    return entries.filter(function(entry) { return entry.title !== session.title })
  }
  function refreshHistoryRows() {
    var rows = historyEntries()
    var signature = JSON.stringify(rows)
    if (signature !== historyRowsSignature) {
      historyRowsSignature = signature
      historyRows = rows
    }
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
    function launch(): void { root.openNstream() }
    function status(): string {
      return JSON.stringify({api_version: root.watchCompatible ? 1 : null,
        connected: root.watchCompatible && Date.now() - root.watchReceived < 5000,
        sequence: root.watchSequence, connection: root.connectionState,
        stale: root.telemetryStale, observing: root.opened,
        panel: {x: panel.cardOrigin.x, y: panel.cardOrigin.y,
          width: panel.contentWidth, height: panel.contentHeight,
          historyHeight: historyViewport.height, historyContentHeight: historyBody.implicitHeight,
          outerScrollable: viewport.contentHeight > viewport.height}})
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
  HelperProcess { id: transferProc; kind: "transfer" }
  HelperProcess { id: openProc; kind: "open" }
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
    contentHeight: fittedContentHeight(
      playerSection.implicitHeight + libraryHeader.implicitHeight + Style.space(24) +
      Math.min(historyBody.implicitHeight, Style.space(250)), Style.space(600))
    focusTarget: viewport
    Flickable {
      id: viewport
      anchors.fill: parent; clip: true
      contentWidth: width; contentHeight: body.implicitHeight
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      Keys.onEscapePressed: root.close()
      Column {
        id: body
        width: viewport.width
        spacing: Style.space(12)

        Column {
          id: playerSection
          width: parent.width
          spacing: Style.space(10)
          Row {
            width: parent.width
            spacing: Style.space(12)
            Plain {
              width: parent.width - openButton.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: tr.t("title")
              font.bold: true
              font.pixelSize: Style.font.bodySmall
            }
            Ui.Button {
              id: openButton
              text: tr.t("open")
              enabled: !openProc.running
              focusable: true
              onClicked: root.openNstream()
            }
          }
          Plain {
            width: parent.width
            visible: root.message !== ""
            text: root.message
            wrapMode: Text.Wrap; elide: Text.ElideNone
            maximumLineCount: 4
            font.pixelSize: Style.font.bodySmall
            color: root.messageIsError ? root.urgent : Commons.Color.foreground
          }
          Caption {
            width: parent.width
            visible: !root.casting
            text: root.heroMeta()
          }
          Column {
            width: parent.width
            visible: root.casting
            spacing: Style.space(8)
            Plain {
              width: parent.width
              text: root.session ? root.session.title : ""
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
            Row {
              width: parent.width
              spacing: Style.space(12)
              Caption {
                width: Math.max(0, parent.width - stateText.width - parent.spacing)
                text: root.heroMeta()
              }
              Caption {
                id: stateText
                width: Math.min(implicitWidth, parent.width * 0.55)
                text: root.stateLabel()
              }
            }
            Plain {
              width: parent.width
              visible: root.statusError !== ""
              text: root.statusError
              color: root.urgent
              wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 4
              font.pixelSize: Style.font.bodySmall
            }
            Ui.PanelSlider {
              id: seekSlider
              enabled: root.watchCompatible && !root.telemetryStale && !controlProc.running && !transferProc.running
              width: parent.width
              bar: root.bar
              visible: root.duration > 0
              minimum: 0; maximum: Math.max(1, root.duration); step: 1
              value: root.status ? root.status.position : 0
              onReleased: function(value) { root.control(["seekto", String(Math.round(value))]) }
            }
            Row {
              width: parent.width
              visible: root.duration > 0
              Caption { width: parent.width / 2; text: root.clock(root.status ? root.status.position : 0) }
              Caption {
                width: parent.width / 2
                horizontalAlignment: Text.AlignRight
                text: tr.t("time.remaining").arg(root.clock(Math.max(0,
                  root.duration - (root.status ? root.status.position : 0))))
              }
            }
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(12)
              Ui.Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconBack
                text: tr.t("seek.back")
                tooltipText: tr.t("act.back")
                focusable: true
                enabled: root.watchCompatible && !root.telemetryStale && !controlProc.running && !transferProc.running
                onClicked: root.control(["seek", "-30"])
              }
              Ui.PanelActionButton {
                size: Style.space(42)
                fontSize: Style.font.title
                bordered: true
                focusable: true
                iconText: root.playing ? root.iconPause : root.iconPlay
                tooltipText: root.playing ? tr.t("act.pause") : tr.t("act.play")
                enabled: root.watchCompatible && !root.telemetryStale && !controlProc.running && !transferProc.running
                onClicked: root.control([root.playing ? "pause" : "resume"])
              }
              Ui.Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconForward
                text: tr.t("seek.forward")
                tooltipText: tr.t("act.forward")
                focusable: true
                enabled: root.watchCompatible && !root.telemetryStale && !controlProc.running && !transferProc.running
                onClicked: root.control(["seek", "30"])
              }
              Ui.PanelActionButton {
                size: Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.iconStop; tooltipText: tr.t("act.stop")
                hoverColor: root.urgent
                focusable: true
                enabled: root.watchCompatible && !controlProc.running && !transferProc.running
                onClicked: root.control(["stop"])
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: root.status !== null && root.status.volume >= 0
              Caption { id: volumeLabel; anchors.verticalCenter: parent.verticalCenter; text: tr.t("volume") }
              Ui.PanelSlider {
                width: Math.max(0, parent.width - volumeLabel.width - volumeValue.width - parent.spacing * 2)
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.watchCompatible && !root.telemetryStale && !controlProc.running && !transferProc.running
                bar: root.bar
                minimum: 0; maximum: 100; step: 1; integer: true
                value: root.status ? root.status.volume : 0
                onReleased: function(value) { root.control(["volume", String(Math.round(value))]) }
              }
              Caption {
                id: volumeValue
                width: Style.space(36)
                horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
                text: tr.t("volume.percent").arg(Commons.I18n.formatNumber(root.status ? root.status.volume : 0, 0))
              }
            }
            Ui.Button {
              text: tr.t("transfer.local")
              focusable: true
              visible: root.canTransfer
              enabled: root.session && root.session.transferable === true && !root.localSession &&
                !transferProc.running && !controlProc.running && !continueProc.running && !localProc.running
              onClicked: root.transferTo("local", root.session.session_id)
            }
            Ui.Button {
              text: tr.t("subtitles.timing")
              iconText: root.showSubtitleTiming ? "󰅃" : "󰅀"
              focusable: true
              onClicked: root.showSubtitleTiming = !root.showSubtitleTiming
            }
            Row {
              width: parent.width
              visible: root.showSubtitleTiming
              spacing: Style.space(8)
              Caption {
                width: Math.max(0, parent.width - subtitleEarlier.width - subtitleLater.width - parent.spacing * 2)
                anchors.verticalCenter: parent.verticalCenter
                text: tr.t("subtitles.hint")
              }
              Ui.Button {
                id: subtitleEarlier
                text: tr.t("sub.earlier"); bordered: true; focusable: true
                enabled: root.watchCompatible && !controlProc.running && !transferProc.running
                onClicked: root.control(["subshift", "-0.5"])
              }
              Ui.Button {
                id: subtitleLater
                text: tr.t("sub.later"); bordered: true; focusable: true
                enabled: root.watchCompatible && !controlProc.running && !transferProc.running
                onClicked: root.control(["subshift", "0.5"])
              }
            }
          }
          Column {
            width: parent.width
            visible: root.localSession !== null
            spacing: Style.space(6)
            Caption { text: tr.t("local.active") }
            Plain { width: parent.width; text: root.localSession ? root.localSession.title : "" }
            Ui.Button {
              text: tr.t("transfer.tv")
              focusable: true
              visible: root.canTransfer
              enabled: root.localSession && root.localSession.transferable === true && !root.casting &&
                !transferProc.running && !controlProc.running && !continueProc.running && !localProc.running
              onClicked: root.transferTo("cast", root.localSession.session_id)
            }
          }
          Ui.PanelSeparator { width: parent.width }
        }

        Column {
          id: libraryHeader
          width: parent.width
          spacing: Style.space(8)
          Row {
            width: parent.width
            spacing: Style.space(12)
            Ui.PanelSectionHeader {
              width: Math.max(0, parent.width - targetPicker.width - parent.spacing)
              anchors.verticalCenter: parent.verticalCenter
              text: tr.t("continue")
            }
            Ui.ButtonGroup {
              id: targetPicker
              value: root.target
              options: [
                { value: "cast", label: tr.t("target.cast") },
                { value: "local", label: tr.t("target.local") }
              ]
              onChanged: function(value) { root.target = value; root.targetChosen = true }
            }
          }
          Caption {
            width: parent.width
            visible: root.localTitle !== ""
            text: tr.t("local.pending").arg(root.localTitle)
            wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 3
          }
          Caption {
            width: parent.width
            visible: root.historyError !== "" || root.historyRows.length === 0
            text: root.historyError !== "" ? root.historyError :
              (root.entries.length === 0 ? tr.t("empty") : tr.t("empty.other"))
            wrapMode: Text.Wrap; elide: Text.ElideNone; maximumLineCount: 4
          }
        }
        Flickable {
          id: historyViewport
          width: parent.width
          height: Math.min(historyBody.implicitHeight, Math.max(Style.space(60),
            viewport.height - playerSection.implicitHeight - libraryHeader.implicitHeight - body.spacing * 2))
          contentWidth: width; contentHeight: historyBody.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          QQC.ScrollBar.vertical: QQC.ScrollBar {
            id: historyScroll
            policy: QQC.ScrollBar.AsNeeded
            active: visible
            width: Style.space(4)
            padding: 0
            contentItem: Rectangle {
              implicitWidth: Style.space(3)
              radius: width / 2
              color: root.foreground
              opacity: 0.35
            }
            background: null
          }
          Column {
            id: historyBody
            width: historyViewport.width - (historyScroll.visible ? historyScroll.width + Style.space(4) : 0)
            Repeater {
              model: root.historyRows.slice(0, root.historyLimit)
              Ui.CursorSurface {
                id: entryRow
                required property var modelData
                width: historyBody.width
                implicitHeight: Math.max(entryText.implicitHeight, playButton.implicitHeight) + Style.space(16)
                activeFocusOnTab: true
                onActiveFocusChanged: {
                  if (!activeFocus) return
                  var top = y
                  var bottom = y + height
                  if (top < historyViewport.contentY) historyViewport.contentY = top
                  else if (bottom > historyViewport.contentY + historyViewport.height)
                    historyViewport.contentY = bottom - historyViewport.height
                }
                hasCursor: entryMouse.containsMouse || activeFocus
                enabled: !transferProc.running && (root.target === "local" ? !localProc.running : !continueProc.running)
                opacity: root.starting !== "" && root.starting !== modelData.title ? 0.45 : 1
                Keys.onReturnPressed: if (enabled) root.resumeEntry(modelData)
                Keys.onSpacePressed: if (enabled) root.resumeEntry(modelData)
                MouseArea {
                  id: entryMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.resumeEntry(entryRow.modelData)
                }
                Column {
                  id: entryText
                  anchors.left: parent.left; anchors.leftMargin: Style.space(8)
                  anchors.right: playButton.left; anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)
                  Plain { width: parent.width; text: entryRow.modelData.title }
                  Caption { width: parent.width; text: root.entryCaption(entryRow.modelData); visible: text !== "" }
                  Rectangle {
                    width: parent.width
                    height: Style.space(2)
                    visible: entryRow.modelData.duration > 0 && !entryRow.modelData.next
                    color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
                    Rectangle {
                      height: parent.height
                      width: parent.width * Math.max(0, Math.min(1,
                        entryRow.modelData.position / Math.max(1, entryRow.modelData.duration)))
                      color: root.foreground
                      opacity: 0.55
                    }
                  }
                }
                Ui.PanelActionButton {
                  id: playButton
                  anchors.right: parent.right; anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.iconPlay
                  tooltipText: root.target === "cast" ? tr.t("act.castHere") : tr.t("act.playHere")
                  onClicked: root.resumeEntry(entryRow.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
