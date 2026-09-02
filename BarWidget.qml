import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for HomeKit control. Same contract the first-party weather and
// dropbox widgets implement: the bar tracks THIS item as the panel identity
// (popout coordinator, open-panel dot, panel switching), so every lifecycle
// call is forwarded down into the lazily loaded Panel.qml.
BarWidget {
  id: root
  moduleName: "ca.orospakr.homekit"

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

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root). Open maps to the
  // panel's hotkey path so summoning suppresses the center hover reveal.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // The panel owns the SSH layer and only polls while it is open, so this is
  // the state of the last call actually made — not a live health check.
  readonly property bool lastCallFailed: panelLoader.item ? panelLoader.item.lastCallFailed === true : false

  // A widget nobody has pointed at a Mac yet has not failed at anything, so it
  // must not wear the urgent colour. Default true while the panel loads so the
  // icon never flashes "unconfigured" during startup.
  readonly property bool configured: panelLoader.item ? panelLoader.item.configured !== false : true

  visible: true
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
    text: String(root.setting("icon", "󰋜"))  // nf-md-home_variant
    slotSize: Style.bar.statusSlot
    // WidgetButton paints `activeColor` (the theme's urgent/error color)
    // instead of the bar foreground while `active` is set.
    active: root.lastCallFailed && root.configured
    tooltipText: !root.configured
      ? "HomeKit: not configured — set a host"
      : (root.lastCallFailed
          ? (panelLoader.item ? String(panelLoader.item.errorMessage) : "HomeKit unavailable")
          : "")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
