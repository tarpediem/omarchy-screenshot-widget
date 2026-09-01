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
// The bar icon turns into a pulsing record dot while gpu-screen-recorder runs.
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

  // What happens to a screenshot once captured — the second argument of
  // omarchy-capture-screenshot. Persisted in shell.json the way the clock
  // persists its format, so the choice survives a shell restart.
  readonly property string processing: setting("processing", "slurp")
  readonly property var processingModes: [
    { id: "slurp", icon: "\uf040", label: "Edit", detail: "Save + clipboard + editor" },
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
      { type: "header", label: "RECORDING" }
    ]
    if (recording) {
      list.push({ type: "action", icon: "\uf04d", label: "Stop recording", hint: "x", urgent: true,
                  cmd: "omarchy-capture-screenrecording --stop-recording" })
    } else {
      list.push({ type: "action", icon: "\uf03d", label: "Record region",      hint: "v", cmd: "omarchy-capture-screenrecording" })
      list.push({ type: "action", icon: "\uf03d", label: "Record full screen", hint: "V", cmd: "omarchy-capture-screenrecording --fullscreen" })
      list.push({ type: "action", icon: "\uf130", label: "Record with audio",  hint: "a", cmd: "omarchy-capture-screenrecording --with-desktop-audio --with-microphone-audio" })
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

  function activateCursor() {
    var entry = actionAt(cursor)
    if (entry) run(entry.cmd)
  }

  function runHint(key) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].type === "action" && entries[i].hint === key) { run(entries[i].cmd); return true }
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
    if (mode === processing) return
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
    pendingCommand = cmd
    close()
    launchTimer.restart()
  }

  function quickShot(mode) { run("omarchy-capture-screenshot " + mode + " " + processing) }
  function stopRecording() { run("omarchy-capture-screenrecording --stop-recording") }
  function probeRecording() { if (!probe.running) probe.running = true }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) { cursor = -1; probeRecording() }
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
    command: ["pgrep", "-f", "^gpu-screen-recorder"]
    onExited: function(exitCode) { root.recording = (exitCode === 0) }
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
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.cycleProcessing(dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: if (root.recording) root.stopRecording()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
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
          meta: root.recording ? "Recording — gpu-screen-recorder running" : "Ready — screenshots land in Pictures"
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

        // ---------- After-capture mode ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

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
                  onClicked: root.run(entryItem.modelData.cmd)
                }
              }
            }
          }
        }
      }
    }
  }
}
