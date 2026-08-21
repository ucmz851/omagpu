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
    if (!panelItem || !panelItem.currentGpu || !panelItem.currentGpu.thermal) return root.bar ? root.bar.barForeground : Color.foreground
    var temp = panelItem.currentGpu.thermal.coreTemp || 0
    if (temp >= 80) return root.bar ? root.bar.urgent : Color.urgent
    if (temp >= 68) return Color.accent
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
