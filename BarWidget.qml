import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ucmz851.omagpu"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function getStatusColor(panelItem) {
    if (!panelItem || !panelItem.currentGpu) return root.bar ? root.bar.barForeground : Color.foreground
    
    var t = panelItem.currentGpu.thermal || {}
    var v = panelItem.currentGpu.vram || {}
    var tun = panelItem.currentGpu.tuning || {}

    var temp = t.coreTemp || 0
    var fanPwm = t.fanPwmPercent || 0
    var vramPct = v.percent || 0
    var perfLevel = tun.performanceLevel || "auto"
    var profile = tun.activeProfile || "Auto"

    // 1. Critical / High Heat or Extreme Fan Speed (Red / Urgent)
    if (temp >= 80 || fanPwm >= 85 || vramPct >= 92) {
      return root.bar ? root.bar.urgent : Color.urgent
    }

    // 2. High Performance / Gaming Profile / Warm (Gold / Accent)
    if (perfLevel === "high" || perfLevel === "profile_peak" || profile.indexOf("High") !== -1 || profile.indexOf("Gaming") !== -1 || temp >= 68 || fanPwm >= 60) {
      return Color.accent
    }

    // 3. Low Power / Eco / Quiet Mode (Soft Green)
    if (perfLevel === "low" || profile.indexOf("Low") !== -1 || profile.indexOf("Saving") !== -1) {
      return "#87c095"
    }

    // 4. Default Balanced State
    return root.bar ? root.bar.barForeground : Color.foreground
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢮"
    foreground: getStatusColor(panelLoader.item)
    slotSize: Style.bar.statusSlot
    tooltipText: (panelLoader.item && panelLoader.item.currentGpu && panelLoader.item.currentGpu.thermal)
      ? "OmaGPU: " + Math.round(panelLoader.item.currentGpu.thermal.coreTemp) + "°C · " + Math.round(panelLoader.item.currentGpu.vram.usedMb) + "M VRAM (" + panelLoader.item.currentGpu.tuning.activeProfile + ")"
      : "OmaGPU Telemetry & Controller"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
