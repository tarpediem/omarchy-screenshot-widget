import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Capture launcher for the Omarchy bar.
//
// Left click opens a keyboard-driven panel listing every capture flow Omarchy
// ships (omarchy-capture-*). Right click takes a smart screenshot straight
// away — or stops a running recording — and middle click grabs a region.
// The bar icon turns into a pulsing record dot while an Omarchy recording runs
// (asked of omarchy-capture-screenrecording --status, whichever recorder it uses).
Panel {
  id: root
  moduleName: "tarpediem.screenshot"
  ipcTarget: "tarpediem.screenshot"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits — needed for the screenshot/stop methods below.
  manageIpc: false

  property bool recording: false
  property int cursor: -1
  property string pendingCommand: ""

  // Webcam viewfinder shown inside the panel: an ffmpeg side process writes
  // frames to one tmpfs JPEG (atomically) and an Image reloads it ~11x/s.
  property bool webcamPreview: false
  property int frameSeq: 0
  readonly property string webcamFrameFile: Quickshell.env("XDG_RUNTIME_DIR") + "/tarpediem-webcam-preview.jpg"
  readonly property string webcamFullFile: Quickshell.env("XDG_RUNTIME_DIR") + "/tarpediem-webcam-full.jpg"
  readonly property string webcamDevice: {
    var d = Quickshell.env("WEBCAM_DEVICE")
    return d ? d : "/dev/video0"
  }

  // What happens to a screenshot once captured — the second argument of
  // omarchy-capture-screenshot. Persisted in shell.json the way the clock
  // persists its format, so the choice survives a shell restart.
  //
  // Clamped to the documented enum: this value and the IPC screenshot mode
  // both end up inside command strings, so anything outside the known
  // variants is discarded — IPC calls or a hand-edited shell.json must not
  // be able to inject shell syntax.
  readonly property string processing: {
    var p = setting("processing", "slurp")
    return isProcessingMode(p) ? p : "slurp"
  }
  readonly property var screenshotModes: ["smart", "region", "windows", "fullscreen", "scroll"]

  function isProcessingMode(p) {
    for (var i = 0; i < processingModes.length; i++)
      if (processingModes[i].id === p) return true
    return false
  }
  readonly property var processingModes: [
    { id: "slurp", icon: "\uf040", label: "Edit", detail: "Save + clipboard, Open/Edit from the notification" },
    { id: "copy",  icon: "\uf0c5", label: "Copy", detail: "Clipboard only" },
    { id: "save",  icon: "\uf0c7", label: "Save", detail: "File only, no editor" }
  ]

  // Flat list rendered top to bottom; headers are skipped by the cursor, so
  // every action carries its own cursor index.
  readonly property var entries: {
    var p = " " + processing
    var list = [
      { type: "header", label: "SCREENSHOT" },
      { type: "action", icon: "\uf030", label: "Smart region", hint: "s", cmd: "omarchy-capture-screenshot smart" + p },
      { type: "action", icon: "\uf125", label: "Region",       hint: "r", cmd: "omarchy-capture-screenshot region" + p },
      { type: "action", icon: "\uf2d0", label: "Window",       hint: "w", cmd: "omarchy-capture-screenshot windows" + p },
      { type: "action", icon: "\uf065", label: "Full screen",  hint: "f", cmd: "omarchy-capture-screenshot fullscreen" + p },
      { type: "action", icon: "\uf07d", label: "Scrolling",    hint: "d", cmd: "omarchy-capture-screenshot scroll" + p },
      { type: "action", icon: "\u{F05A0}", label: "Webcam photo", hint: "b", webcam: true },
      { type: "header", label: "RECORDING" }
    ]
    if (recording) {
      list.push({ type: "action", icon: "\uf04d", label: "Stop recording", hint: "x", urgent: true,
                  cmd: "omarchy-capture-screenrecording --stop-recording" })
    } else {
      list.push({ type: "action", icon: "\uf03d", label: "Record region",      hint: "v", cmd: "omarchy-capture-screenrecording" })
      list.push({ type: "action", icon: "\uf03d", label: "Record full screen", hint: "V", cmd: "omarchy-capture-screenrecording --fullscreen" })
      list.push({ type: "action", icon: "\uf130", label: "Record with audio",  hint: "a", cmd: "omarchy-capture-screenrecording --with-desktop-audio --with-microphone-audio" })
      list.push({ type: "action", icon: "\u{F05A0}", label: "Record with webcam", hint: "W", cmd: "omarchy-capture-screenrecording --with-desktop-audio --with-microphone-audio --with-webcam" })
    }
    list.push({ type: "header", label: "TOOLS" })
    list.push({ type: "action", icon: "\u{F0D11}", label: "Text (OCR)",   hint: "t", cmd: "omarchy-capture-text" })
    list.push({ type: "action", icon: "\u{F0432}", label: "QR code",      hint: "q", cmd: "omarchy-capture-qr" })
    list.push({ type: "action", icon: "\u{F00C9}", label: "Color picker", hint: "c", cmd: "pkill hyprpicker || hyprpicker -a" })

    var n = 0
    for (var i = 0; i < list.length; i++) {
      list[i].index = i
      list[i].actionIndex = list[i].type === "action" ? n++ : -1
    }
    return list
  }
  readonly property int actionCount: entries.filter(function(e) { return e.type === "action" }).length

  function actionAt(actionIndex) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].actionIndex === actionIndex) return entries[i]
    return null
  }

  function moveCursor(delta) {
    var n = actionCount
    if (n === 0) return
    if (cursor < 0) { cursor = delta > 0 ? 0 : n - 1; return }
    cursor = ((cursor + delta) % n + n) % n
  }

  function activateEntry(entry) {
    if (!entry) return
    if (entry.webcam) startWebcamPreview()
    else run(entry.cmd)
  }

  function activateCursor() { activateEntry(actionAt(cursor)) }

  function runHint(key) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].type === "action" && entries[i].hint === key) { activateEntry(entries[i]); return true }
    return false
  }

  function processingIndex() {
    for (var i = 0; i < processingModes.length; i++)
      if (processingModes[i].id === processing) return i
    return 0
  }

  function cycleProcessing(delta) {
    var n = processingModes.length
    setProcessing(processingModes[((processingIndex() + delta) % n + n) % n].id)
  }

  function setProcessing(mode) {
    if (!isProcessingMode(mode) || mode === processing) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.processing = mode

    // Applied locally first so the row highlights on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The popup is a layer-shell overlay and would end up in the capture, so
  // close first and launch once the 140 ms fade-out has finished.
  function run(cmd) {
    // Ignore an empty or missing command instead of assigning undefined.
    if (typeof cmd !== "string" || cmd === "") return
    pendingCommand = cmd
    close()
    launchTimer.restart()
  }

  function quickShot(mode) {
    if (screenshotModes.indexOf(mode) === -1) return
    run("omarchy-capture-screenshot " + mode + " " + processing)
  }
  function stopRecording() { run("omarchy-capture-screenrecording --stop-recording") }

  function startWebcamPreview() {
    webcamPreview = true
    previewProc.running = true
  }
  function stopWebcamPreview() {
    webcamPreview = false
    previewProc.running = false
  }
  // The photo IS the frame on screen: the viewfinder keeps a full-resolution
  // copy of its latest frame on tmpfs, and shooting just picks that file up —
  // no camera restart, no delay. booth mode = save + clipboard + notification.
  //
  // The command is a fixed literal on purpose: interpolating $HOME or
  // $XDG_RUNTIME_DIR into a shell string would break (or worse) on exotic
  // values. Tilde expansion is not subject to word splitting, and the script
  // resolves the frame path from its own environment.
  function shootWebcam() {
    run("bash ~/.config/omarchy/plugins/tarpediem.screenshot/webcam-shot.sh booth --from-frame")
  }
  function probeRecording() { if (!probe.running) probe.running = true }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) { cursor = -1; probeRecording() }
    else stopWebcamPreview()
  }
  onRecordingChanged: {
    if (cursor >= actionCount) cursor = -1
    if (!recording) button.dimmed = false
  }

  Timer {
    id: launchTimer
    interval: 260
    onTriggered: {
      var cmd = root.pendingCommand
      root.pendingCommand = ""
      if (cmd === "") return
      Util.execDetached(cmd)
      settleTimer.ticks = 0
      settleTimer.restart()
    }
  }

  // The recorder only appears once the user has picked a region, so re-probe
  // for a while after any launch instead of waiting for the slow poll.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    onTriggered: {
      root.probeRecording()
      if (++ticks >= 12) stop()
    }
  }

  Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.probeRecording() }

  Timer {
    interval: 700
    running: root.recording
    repeat: true
    onTriggered: button.dimmed = !button.dimmed
  }

  Process {
    id: probe
    command: ["omarchy-capture-screenrecording", "--status"]
    onExited: function(exitCode) { root.recording = (exitCode === 0) }
  }

  // Viewfinder frames: -update 1 rewrites the same file, -atomic_writing
  // keeps readers from ever seeing a half-written JPEG. Two outputs from the
  // one camera stream: a downscaled preview for the panel, and the latest
  // frame at full 1080p that shootWebcam() picks up as the photo.
  Process {
    id: previewProc
    command: ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
      "-f", "v4l2", "-framerate", "30", "-video_size", "1920x1080",
      "-i", root.webcamDevice,
      "-vf", "fps=12,scale=720:-2",
      "-f", "image2", "-update", "1", "-atomic_writing", "1",
      root.webcamFrameFile,
      "-vf", "fps=12",
      "-f", "image2", "-update", "1", "-atomic_writing", "1",
      root.webcamFullFile]
  }

  Timer {
    interval: 90
    running: root.webcamPreview
    repeat: true
    onTriggered: root.frameSeq++
  }

  IpcHandler {
    target: "tarpediem.screenshot"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function screenshot(mode: string): void { root.quickShot(mode === "" ? "smart" : mode) }
    function stop(): void { root.stopRecording() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.recording ? "\uf111" : "\uf030"
    active: root.recording
    tooltipText: root.recording ? "Recording — right click to stop" : "Screenshot"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.recording) root.stopRecording()
        else root.quickShot("smart")
      } else if (b === Qt.MiddleButton) {
        root.quickShot("region")
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.webcamPreview) return
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.cycleProcessing(dx)
      }
      onActivateRequested: root.webcamPreview ? root.shootWebcam() : root.activateCursor()
      onCloseRequested: root.webcamPreview ? root.stopWebcamPreview() : root.close()
      onDeleteRequested: if (root.recording) root.stopRecording()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.webcamPreview) { if (t === " ") root.shootWebcam(); return }
        if (t === "1" || t === "2" || t === "3") { root.setProcessing(root.processingModes[parseInt(t) - 1].id); return }
        if (t === "m") { root.cycleProcessing(1); return }
        root.runHint(t)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          title: "Capture"
          meta: root.webcamPreview ? "Webcam — photo goes to clipboard + Pictures"
                                   : root.recording ? "Recording — gpu-screen-recorder running"
                                                    : "Ready — screenshots land in Pictures"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.recording ? "\uf111" : "\uf030"
              color: root.recording ? root.bar.urgent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---------- Webcam viewfinder ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.webcamPreview

          Rectangle {
            width: parent.width
            height: Math.round(width * 9 / 16)
            radius: Style.space(6)
            color: "#000000"
            clip: true

            // Double-buffered viewfinder: each new frame is loaded into the
            // hidden Image and only swapped in once fully decoded. A single
            // reloading Image goes blank during every async load, which
            // flickers at 11 fps.
            Item {
              id: viewfinder
              anchors.fill: parent
              property int shown: -1
              readonly property bool ready: shown >= 0

              Connections {
                target: root
                function onFrameSeqChanged() {
                  if (!root.webcamPreview) return
                  var back = viewfinder.shown === 0 ? imgB : imgA
                  back.source = "file://" + root.webcamFrameFile + "?s=" + root.frameSeq
                }
                function onWebcamPreviewChanged() {
                  if (!root.webcamPreview) {
                    viewfinder.shown = -1
                    imgA.source = ""
                    imgB.source = ""
                  }
                }
              }

              Image {
                id: imgA
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                cache: false
                asynchronous: true
                visible: viewfinder.shown === 0
                onStatusChanged: if (status === Image.Ready) viewfinder.shown = 0
              }

              Image {
                id: imgB
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                cache: false
                asynchronous: true
                visible: viewfinder.shown === 1
                onStatusChanged: if (status === Image.Ready) viewfinder.shown = 1
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.webcamPreview && !viewfinder.ready
              textFormat: Text.PlainText
              text: "Starting camera…"
              color: "#dddddd"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.shootWebcam()
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Space / click — photo        Esc — back"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- After-capture mode ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.webcamPreview

          PanelSectionHeader {
            text: "AFTER CAPTURE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (root.processingModes.length - 1)) / root.processingModes.length

            Repeater {
              model: root.processingModes
              Button {
                required property var modelData
                width: modeRow.cellWidth
                iconText: modelData.icon
                text: modelData.label
                tooltipText: modelData.detail
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.processing === modelData.id
                onClicked: root.setProcessing(modelData.id)
              }
            }
          }
        }

        // ---------- Actions ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: !root.webcamPreview

          Repeater {
            model: root.entries

            Item {
              id: entryItem
              required property var modelData
              readonly property bool isHeader: modelData.type === "header"
              readonly property bool isUrgent: modelData.urgent === true
              width: parent ? parent.width : 0
              height: isHeader
                ? sectionHeader.implicitHeight + Style.space(modelData.index > 0 ? 16 : 4)
                : Style.space(34)

              PanelSeparator {
                visible: entryItem.isHeader && entryItem.modelData.index > 0
                anchors.top: parent.top
                foreground: root.bar.foreground
              }

              PanelSectionHeader {
                id: sectionHeader
                visible: entryItem.isHeader
                anchors.bottom: parent.bottom
                text: entryItem.modelData.label
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              CursorSurface {
                visible: !entryItem.isHeader
                anchors.fill: parent
                foreground: root.bar.foreground
                accent: entryItem.isUrgent ? root.bar.urgent : Color.accent
                hasCursor: !entryItem.isHeader && root.cursor === entryItem.modelData.actionIndex

                Text {
                  id: rowIcon
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(22)
                  horizontalAlignment: Text.AlignHCenter
                  text: entryItem.modelData.icon || ""
                  color: entryItem.isUrgent ? root.bar.urgent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: rowIcon.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: rowHint.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: entryItem.modelData.label || ""
                  color: entryItem.isUrgent ? root.bar.urgent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: rowHint
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: entryItem.modelData.hint || ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = entryItem.modelData.actionIndex
                  onClicked: root.activateEntry(entryItem.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
