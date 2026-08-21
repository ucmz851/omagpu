import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "ucmz851.omagpu"
  ipcTarget: "ucmz851.omagpu"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // GPU state
  property var gpus: []
  property int selectedGpuIndex: 0
  readonly property var currentGpu: (gpus && gpus.length > selectedGpuIndex) ? gpus[selectedGpuIndex] : ({})

  property var history: ({ temps: [], vram: [], gpu_busy: [] })
  property var processes: []
  property var software: ({ vulkan: "Vulkan 1.3", opengl: "OpenGL 4.6", driver: "amdgpu" })
  property string lastUpdateTime: ""
  property bool isUpdating: false
  property string activeTab: "telemetry"
  property string copiedNotice: ""

  readonly property var tabList: [
    { label: "Telemetry", key: "telemetry" },
    { label: "Tuning & Power", key: "tuning" },
    { label: "Fan Control", key: "fans" },
    { label: "Hardware & Stack", key: "hardware" }
  ]

  function copyToClipboard(text) {
    if (!text) return
    Quickshell.execDetached(["wl-copy", "--", text])
    root.copiedNotice = text
    noticeTimer.restart()
  }

  function refresh() {
    if (pollProc.running) return
    root.isUpdating = true
    pollProc.running = true
  }

  function setPowerProfile(level) {
    if (!currentGpu || !currentGpu.id) return
    controlProc.command = ["python3", Qt.resolvedUrl("scripts/gpu_engine.py").toString().replace(/^file:\/\//, ""), "--set-power-profile", currentGpu.id, level]
    controlProc.running = true
  }

  function setFanPwm(pwmVal) {
    if (!currentGpu || !currentGpu.id) return
    controlProc.command = ["python3", Qt.resolvedUrl("scripts/gpu_engine.py").toString().replace(/^file:\/\//, ""), "--set-fan", currentGpu.id, pwmVal.toString()]
    controlProc.running = true
  }

  function parseGpuOutput(text) {
    root.isUpdating = false
    if (!text || text.trim() === "") return
    try {
      var data = JSON.parse(text)
      root.gpus = data.gpus || []
      root.history = data.history || ({ temps: [], vram: [], gpu_busy: [] })
      root.processes = data.processes || []
      root.software = data.software || ({})
      root.lastUpdateTime = data.timestamp || ""
      if (historyCanvas) historyCanvas.requestPaint()
    } catch (e) {
      console.log("omagpu JSON parse error:", e)
    }
  }

  Timer {
    id: liveTimer
    interval: 2500
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: noticeTimer
    interval: 2500
    running: false
    repeat: false
    onTriggered: root.copiedNotice = ""
  }

  Process {
    id: pollProc
    command: ["python3", Qt.resolvedUrl("scripts/gpu_engine.py").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseGpuOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text) console.log("omagpu stderr:", text)
    }
    onExited: function(c) { root.isUpdating = false }
  }

  Process {
    id: controlProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") {
          try {
            var res = JSON.parse(text)
            if (res.status === "success") {
              if (res.level) root.copiedNotice = "Applied Power Governor: " + res.level
              else if (res.mode === "auto") root.copiedNotice = "Fan mode set to: Automatic VBIOS"
              else if (res.pwm !== undefined) root.copiedNotice = "Fan speed set to PWM: " + res.pwm
              noticeTimer.restart()
            } else if (res.status === "error") {
              root.copiedNotice = "Tuning Error: " + (res.message || "Permission denied")
              noticeTimer.restart()
            }
          } catch (e) {
            console.log("controlProc parse error:", e)
          }
        }
        root.refresh()
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.refresh()
      Qt.callLater(function() {
        if (keyCatcher) keyCatcher.forceActiveFocus()
      })
    }
  }

  Component.onCompleted: root.refresh()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(mainLayout.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: mainLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ------------------ HERO HEADER ------------------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰢮"
            color: {
              if (currentGpu.thermal && (currentGpu.thermal.coreTemp >= 80 || currentGpu.thermal.fanPwmPercent >= 85)) return root.urgent
              if (currentGpu.tuning && (currentGpu.tuning.performanceLevel === "high" || currentGpu.tuning.performanceLevel === "profile_peak")) return Color.accent
              if (currentGpu.tuning && (currentGpu.tuning.performanceLevel === "low" || currentGpu.tuning.activeProfile.indexOf("Low") !== -1)) return "#87c095"
              return Color.accent
            }
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroAction.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                text: currentGpu.model || "GPU Controller"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: Math.min(implicitWidth, Style.space(260))
              }

              BorderSurface {
                implicitWidth: vendorText.implicitWidth + Style.space(8)
                implicitHeight: vendorText.implicitHeight + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                radius: Style.cornerRadius

                Text {
                  textFormat: Text.PlainText
                  id: vendorText
                  anchors.centerIn: parent
                  text: currentGpu.vendor || "AMD"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: (currentGpu.driver || "amdgpu") + " · VBIOS: " + (currentGpu.vbios || "N/A") + (root.lastUpdateTime ? " · " + root.lastUpdateTime : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: heroAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: root.isUpdating ? "Updating telemetry..." : "Refresh Telemetry ('R')"
            foreground: root.isUpdating ? Color.accent : root.foreground
            rotation: 0
            onClicked: root.refresh()

            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 800
              loops: Animation.Infinite
              running: root.isUpdating
            }
          }
        }

        // ------------------ COPIED NOTICE BANNER ------------------
        BorderSurface {
          visible: root.copiedNotice !== ""
          width: parent.width
          implicitHeight: noticeText.implicitHeight + Style.space(8)
          color: "transparent"
          borderSpec: Border.controlSpec("focus", Color.accent, Color.accent)
          radius: Style.cornerRadius

          Text {
            id: noticeText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "Copied: " + root.copiedNotice
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideMiddle
          }
        }

        // ------------------ NAVIGATION TABS ------------------
        Row {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.tabList
            delegate: BorderSurface {
              readonly property bool isSelected: root.activeTab === modelData.key
              implicitWidth: tabText.implicitWidth + Style.space(14)
              implicitHeight: tabText.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: isSelected ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
              borderSpec: isSelected
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", root.dim, Color.accent)

              Text {
                textFormat: Text.PlainText
                id: tabText
                anchors.centerIn: parent
                text: modelData.label
                color: isSelected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: isSelected
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activeTab = modelData.key
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
        }

        // =========================================================================
        // TAB 1: TELEMETRY & LIVE GAUGES
        // =========================================================================
        Column {
          visible: root.activeTab === "telemetry"
          width: parent.width
          spacing: Style.space(10)

          // 2x2 Telemetry Cards Grid
          Grid {
            columns: 2
            width: parent.width
            spacing: Style.space(8)

            // Card 1: Core & Hotspot Temperature
            BorderSurface {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: tempCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: tempCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "󰔏"
                    color: (currentGpu.thermal && currentGpu.thermal.coreTemp >= 80) ? root.urgent : ((currentGpu.thermal && currentGpu.thermal.coreTemp >= 68) ? Color.accent : "#87c095")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Temperature"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: (currentGpu.thermal ? currentGpu.thermal.coreTemp : 0.0) + " °C"
                  color: (currentGpu.thermal && currentGpu.thermal.coreTemp >= 80) ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Hotspot: " + (currentGpu.thermal ? currentGpu.thermal.hotspotTemp : 0.0) + " °C"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Card 2: Dedicated VRAM
            BorderSurface {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: vramCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: vramCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "󰍛"
                    color: (currentGpu.vram && currentGpu.vram.percent >= 90) ? root.urgent : ((currentGpu.vram && currentGpu.vram.percent >= 75) ? Color.accent : "#6aa6b2")
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Dedicated VRAM"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: (currentGpu.vram ? Math.round(currentGpu.vram.usedMb) : 0) + " / " + (currentGpu.vram ? Math.round(currentGpu.vram.totalMb) : 1024) + " MB"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                // Progress Meter
                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: Style.cornerRadius
                  color: Qt.darker(root.dim, 2.0)

                  Rectangle {
                    width: parent.width * Math.min(1.0, (currentGpu.vram ? currentGpu.vram.percent : 0) / 100.0)
                    height: parent.height
                    radius: Style.cornerRadius
                    color: (currentGpu.vram && currentGpu.vram.percent >= 90) ? root.urgent : Color.accent
                  }
                }
              }
            }

            // Card 3: Fan Speed & PWM
            BorderSurface {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: fanCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: fanCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "󰈐"
                    color: {
                      var fpwm = currentGpu.thermal ? currentGpu.thermal.fanPwmPercent : 0
                      if (fpwm >= 85) return root.urgent
                      if (fpwm >= 60) return Color.accent
                      if (fpwm < 40) return "#87c095"
                      return "#6aa6b2"
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Fan & Cooling"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: (currentGpu.thermal ? currentGpu.thermal.fanPwmPercent : 0) + " %"
                  color: (currentGpu.thermal && currentGpu.thermal.fanPwmPercent >= 85) ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: currentGpu.tuning ? currentGpu.tuning.fanControlMode : "Automatic"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Card 4: Power State & Watts
            BorderSurface {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: powerCol.implicitHeight + Style.space(16)
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
              radius: Style.cornerRadius

              Column {
                id: powerCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: "󰚥"
                    color: {
                      var plevel = currentGpu.tuning ? currentGpu.tuning.performanceLevel : "auto"
                      if (plevel === "high" || plevel === "profile_peak") return Color.accent
                      if (plevel === "low") return "#87c095"
                      return "#6aa6b2"
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "Power Profile"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: (currentGpu.tuning ? currentGpu.tuning.activeProfile : "Auto")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Draw: " + (currentGpu.thermal ? currentGpu.thermal.powerWatts : 25) + " W"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Live Rolling Telemetry Canvas Chart
          BorderSurface {
            width: parent.width
            implicitHeight: Style.space(130)
            color: Style.hoverFillFor(root.foreground, root.foreground)
            borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
            radius: Style.cornerRadius

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              Row {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "Live Temperature & VRAM Telemetry (30s)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Item { Layout.fillWidth: true; width: Style.space(8) }
                Text {
                  textFormat: Text.PlainText
                  text: "── Temp  ·· VRAM"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Canvas {
                id: historyCanvas
                width: parent.width
                height: Style.space(85)

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var w = width
                  var h = height

                  // Draw Grid baseline
                  ctx.strokeStyle = "rgba(255,255,255,0.06)"
                  ctx.lineWidth = 1
                  ctx.beginPath()
                  ctx.moveTo(0, h * 0.5)
                  ctx.lineTo(w, h * 0.5)
                  ctx.stroke()

                  var temps = root.history.temps || []
                  if (temps.length > 1) {
                    // Temperature Line (Accent Color)
                    ctx.strokeStyle = Color.accent.toString()
                    ctx.lineWidth = 2
                    ctx.beginPath()
                    var step = w / Math.max(1, temps.length - 1)
                    for (var i = 0; i < temps.length; i++) {
                      var val = temps[i]
                      // scale 30C - 90C
                      var norm = Math.max(0, Math.min(1, (val - 30) / 60.0))
                      var y = h - (norm * h)
                      if (i === 0) ctx.moveTo(0, y)
                      else ctx.lineTo(i * step, y)
                    }
                    ctx.stroke()
                  }

                  var vramPts = root.history.vram || []
                  if (vramPts.length > 1) {
                    // VRAM Line (Dim White)
                    ctx.strokeStyle = "rgba(255,255,255,0.5)"
                    ctx.lineWidth = 1.5
                    ctx.beginPath()
                    var step2 = w / Math.max(1, vramPts.length - 1)
                    for (var j = 0; j < vramPts.length; j++) {
                      var vpct = vramPts[j]
                      var y2 = h - ((vpct / 100.0) * h)
                      if (j === 0) ctx.moveTo(0, y2)
                      else ctx.lineTo(j * step2, y2)
                    }
                    ctx.stroke()
                  }
                }
              }
            }
          }
        }

        // =========================================================================
        // TAB 2: TUNING & POWER MANAGEMENT
        // =========================================================================
        Column {
          visible: root.activeTab === "tuning"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: "DPM Performance Level & Power States"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Control the GPU power governor and clock frequency behavior. Overrides dynamic scaling for gaming low latency or maximum battery efficiency."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // Power Profiles List
          Repeater {
            model: [
              { id: "auto", title: "Dynamic Balanced (Auto)", desc: "Kernel dynamically clocks up under 3D load and clocks down at idle.", icon: "󰚥" },
              { id: "high", title: "High Performance (Max Clocks)", desc: "Locks GPU core & memory clocks to maximum for lowest latency and stutter-free gaming.", icon: "🚀" },
              { id: "low", title: "Low Power / Silent (Battery)", desc: "Locks clocks to minimum states for quiet operation, cool temps, and maximum power saving.", icon: "🔋" },
              { id: "profile_peak", title: "Peak Profile", desc: "Forces highest power envelope profile for heavy compute and benchmark workloads.", icon: "⚡" }
            ]

            delegate: BorderSurface {
              readonly property bool isCurrent: Boolean(currentGpu && currentGpu.tuning && currentGpu.tuning.performanceLevel === modelData.id)
              width: parent.width
              implicitHeight: profCol.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: isCurrent ? Style.selectedFillFor(root.foreground, root.foreground) : "transparent"
              borderSpec: isCurrent
                ? Border.controlSpec("selected", Color.accent, Color.accent)
                : Border.controlSpec("normal", root.dim, Color.accent)

              Column {
                id: profCol
                anchors.left: parent.left
                anchors.right: applyBtn.left
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.icon
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.title
                    color: isCurrent ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: modelData.desc
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }

              PanelActionButton {
                id: applyBtn
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: isCurrent ? "" : "󰑕"
                tooltipText: isCurrent ? "Active Profile" : "Apply " + modelData.title
                foreground: isCurrent ? Color.accent : root.foreground
                onClicked: root.setPowerProfile(modelData.id)
              }
            }
          }
        }

        // =========================================================================
        // TAB 3: FAN & COOLING CONTROL
        // =========================================================================
        Column {
          visible: root.activeTab === "fans"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: "Acoustics & Fan PWM Controller"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Switch between VBIOS firmware automatic fan curves or lock fixed PWM fan duty cycles for benchmarking and extreme cooling."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // Fan Speed Presets Grid
          Grid {
            columns: 2
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [
                { label: "Automatic VBIOS", pwm: "auto", desc: "Hardware firmware manages fan curve dynamically based on thermal sensors." },
                { label: "35% Silent", pwm: "90", desc: "Quiet desktop mode with inaudible acoustic profile." },
                { label: "60% Balanced", pwm: "153", desc: "Steady airflow with balanced acoustics for light gaming." },
                { label: "80% Aggressive", pwm: "204", desc: "High airflow for heavy 3D rendering and long gaming sessions." },
                { label: "100% Maximum", pwm: "255", desc: "Full 255 PWM duty cycle for maximum thermal dissipation." }
              ]

              delegate: BorderSurface {
                width: (parent.width - Style.space(8)) / 2
                implicitHeight: fanCardCol.implicitHeight + Style.space(14)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.foreground, root.foreground)
                borderSpec: Border.controlSpec("normal", root.dim, Color.accent)

                Column {
                  id: fanCardCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.desc
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                  }

                  PanelActionButton {
                    anchors.right: parent.right
                    iconText: "󰈐"
                    tooltipText: "Set " + modelData.label
                    foreground: Color.accent
                    onClicked: root.setFanPwm(modelData.pwm)
                  }
                }
              }
            }
          }
        }

        // =========================================================================
        // TAB 4: HARDWARE SPECS & GPU PROCESSES
        // =========================================================================
        Column {
          visible: root.activeTab === "hardware"
          width: parent.width
          spacing: Style.space(10)

          // Hardware Specs Box
          BorderSurface {
            width: parent.width
            implicitHeight: hwCol.implicitHeight + Style.space(16)
            color: Style.hoverFillFor(root.foreground, root.foreground)
            borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
            radius: Style.cornerRadius

            Column {
              id: hwCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Hardware & Driver Topology"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Row {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "PCIe Bus Link:"; color: root.dim; width: Style.space(140); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: currentGpu.pcie || "PCIe 3.0 x8"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Row {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "VBIOS Version:"; color: root.dim; width: Style.space(140); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: currentGpu.vbios || "N/A"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Row {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "Vulkan API:"; color: root.dim; width: Style.space(140); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: root.software.vulkan || "Vulkan 1.3"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Row {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "OpenGL / Mesa:"; color: root.dim; width: Style.space(140); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: root.software.opengl || "OpenGL 4.6"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }

              Row {
                width: parent.width
                Text { textFormat: Text.PlainText; text: "GTT Shared RAM:"; color: root.dim; width: Style.space(140); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: (currentGpu.gtt ? Math.round(currentGpu.gtt.usedMb) : 0) + " / " + (currentGpu.gtt ? Math.round(currentGpu.gtt.totalMb) : 0) + " MB"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Active GPU Render Clients (/dev/dri)"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // Active GPU Processes List
          Repeater {
            model: root.processes || []
            delegate: BorderSurface {
              width: parent.width
              implicitHeight: procRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.foreground)
              borderSpec: Border.controlSpec("normal", root.dim, Color.accent)

              RowLayout {
                id: procRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(6)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "󰅒"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Column {
                  Layout.fillWidth: true
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name + " (PID: " + modelData.pid + ")"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Type: " + modelData.type
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                BorderSurface {
                  implicitWidth: pMem.implicitWidth + Style.space(8)
                  implicitHeight: pMem.implicitHeight + Style.space(4)
                  color: "transparent"
                  borderSpec: Border.controlSpec("normal", root.dim, Color.accent)
                  radius: Style.cornerRadius

                  Text {
                    id: pMem
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: modelData.mem_mb + " MB"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }
          }
        }

        // ------------------ FOOTER ------------------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Tip: Press 'R' to refresh · Click any power or fan preset to apply tuning instantly"
          color: Qt.darker(root.dim, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
