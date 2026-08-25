import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// HomeKit control popup: scenes on top, then every controllable accessory
// grouped by room, driven by homeclaw-cli running on a Mac over SSH.
//
// Polling is deliberately open-only (Service.qml explains why), so the panel
// keeps whatever it last parsed and re-renders it instantly on reopen while a
// fresh read lands underneath.
Panel {
  id: root
  moduleName: "andrew.homekit"
  ipcTarget: "andrew.homekit"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by (popout
  // coordinator, open-panel dot, panel switching) has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Read back by BarWidget.qml to tint the bar icon.
  readonly property bool lastCallFailed: svc.failed
  readonly property string errorMessage: svc.errorMessage

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    svc.refresh()
  }

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar && "urgent" in bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- settings
  //
  // Read through setting() with fallbacks so the phantom onSettingsChanged
  // that fires before the real inline entry arrives is simply the defaults;
  // every consumer below is a binding, so the real values slot in when they
  // land without any imperative re-application.
  readonly property string hostSetting: String(setting("host", "snively"))
  readonly property string cliPathSetting: String(setting("cliPath", "/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli"))
  readonly property int pollSeconds: Math.max(3, Math.min(120, Number(setting("pollSeconds", 10)) || 10))
  readonly property var hiddenRoomsSetting: {
    var value = setting("hiddenRooms", [])
    return Array.isArray(value) ? value : []
  }

  Service {
    id: svc
    host: root.hostSetting
    cliPath: root.cliPathSetting
    hiddenRooms: root.hiddenRoomsSetting
  }

  // Pointing the widget at a different Mac invalidates everything on screen.
  onHostSettingChanged: if (root.opened) root.refresh()

  Timer {
    running: root.opened
    interval: root.pollSeconds * 1000
    repeat: true
    onTriggered: svc.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }

    // Write routes, so a Hyprland bind can run a scene or flip a light without
    // opening anything. Accessory and scene names are the ones `list`/`scenes`
    // report, spaces and all.
    function scene(name: string): void { svc.triggerScene(name) }
    function power(name: string, value: string): void {
      var on = value === "true" || value === "on" || value === "1"
      svc.setPower(name, on)
    }
    function brightness(name: string, value: string): void {
      svc.setBrightness(name, Number(value))
    }
  }

  // --------------------------------------------------------- status lines
  readonly property string statusLine: {
    if (svc.failed) return svc.errorMessage
    if (svc.loading && !svc.everLoaded) return "Connecting to " + root.hostSetting + "…"
    if (!svc.everLoaded) return root.hostSetting
    return svc.deviceCount + " accessories · " + svc.scenes.length + " scenes · " + root.hostSetting
  }

  readonly property string onPill: svc.everLoaded && svc.poweredOnCount > 0 ? svc.poweredOnCount + " on" : ""

  // ------------------------------------------------------- keyboard cursor
  //
  // One flat list of everything Enter can act on, in visual order: scenes
  // first, then each room's controllable, reachable accessories.
  readonly property var flatRows: {
    var out = []
    for (var s = 0; s < svc.scenes.length; s++) {
      // HomeKit's stock Arrive/Leave/Wake scenes exist with no actions until
      // someone fills them in, and homeclaw-cli refuses to trigger those
      // ("No actions in action set", exit 64). They stay on screen as context
      // but are not something Enter should land on.
      if (svc.scenes[s].actionCount > 0) out.push({ kind: "scene", name: svc.scenes[s].name })
    }
    for (var r = 0; r < svc.rooms.length; r++) {
      var devices = svc.rooms[r].devices
      for (var d = 0; d < devices.length; d++) {
        var device = devices[d]
        if (device.controllable && device.reachable)
          out.push({ kind: "device", name: device.name, brightness: device.hasBrightness })
      }
    }
    return out
  }

  property bool cursorActive: false
  property int cursorIndex: 0

  onFlatRowsChanged: clampCursor()

  function clampCursor() {
    if (flatRows.length === 0) {
      cursorIndex = 0
      cursorActive = false
      return
    }
    cursorIndex = Math.max(0, Math.min(flatRows.length - 1, cursorIndex))
  }

  function moveCursor(delta) {
    if (flatRows.length === 0) return
    cursorIndex = Math.max(0, Math.min(flatRows.length - 1, cursorIndex + delta))
  }

  function focusRow(kind, name) {
    for (var i = 0; i < flatRows.length; i++) {
      if (flatRows[i].kind === kind && flatRows[i].name === name) {
        cursorActive = true
        cursorIndex = i
        return
      }
    }
  }

  function rowHasCursor(kind, name) {
    if (!cursorActive) return false
    var row = flatRows[cursorIndex]
    return !!row && row.kind === kind && row.name === name
  }

  function deviceByName(name) {
    for (var r = 0; r < svc.rooms.length; r++) {
      var devices = svc.rooms[r].devices
      for (var d = 0; d < devices.length; d++) if (devices[d].name === name) return devices[d]
    }
    return null
  }

  function activateCursor() {
    var row = flatRows[cursorIndex]
    if (!row) return
    if (row.kind === "scene") { svc.triggerScene(row.name); return }
    var device = deviceByName(row.name)
    if (device) svc.setPower(device.name, device.power !== true)
  }

  // Horizontal keys nudge the brightness of whatever light the cursor is on.
  function nudgeCursorBrightness(direction) {
    var row = flatRows[cursorIndex]
    if (!row || row.kind !== "device") return
    var device = deviceByName(row.name)
    if (!device || !device.hasBrightness) return
    var current = device.brightness === null ? (device.power === true ? 100 : 0) : device.brightness
    svc.setBrightness(device.name, current + direction * 10)
  }

  // A model rebuild recreates every Repeater delegate, which collapses the
  // column for a frame and the Flickable clamps contentY to 0. The service
  // signals just before it reassigns rooms/scenes, so the position is captured
  // while it is still real and put back once the new delegates have laid out
  // (callLater for the common case, plus one timer tick for late positioner
  // passes).
  property real savedScrollY: 0

  Connections {
    target: svc
    function onModelAboutToChange() {
      var flick = scrollArea.contentItem
      if (!flick || flick.contentY === undefined) return
      root.savedScrollY = flick.contentY
      Qt.callLater(root.restoreScroll)
      scrollRestoreTimer.restart()
    }
  }

  Timer {
    id: scrollRestoreTimer
    interval: 50
    onTriggered: root.restoreScroll()
  }

  function restoreScroll() {
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    flick.contentY = Math.max(0, Math.min(maxY, root.savedScrollY))
  }

  // Copied from the audio panel: keep the keyboard cursor inside the viewport
  // without disturbing the scroll position when everything already fits.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = Style.space(6)
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= 0) { flick.contentY = 0; return }
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  // ----------------------------------------------------------------- view
  readonly property int panelWidth: Style.space(400)
  readonly property int panelMaxHeight: Style.space(620)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight, root.panelMaxHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.activateCursor()
      }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.nudgeCursorBrightness(dx)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      QQC.ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
        QQC.ScrollBar.vertical.policy: column.implicitHeight > height ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: column.implicitHeight > scrollArea.height
        }

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---------- Hero: home name · connection status · refresh ----------
          PanelHero {
            width: parent.width
            title: svc.homeName !== "" ? svc.homeName : "HomeKit"
            meta: root.statusLine
            detail: root.onPill
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: svc.failed ? 0.5 : 1.0

            iconComponent: Component {
              Text {
                text: "󰋜"  // nf-md-home_variant
                color: svc.failed ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"  // nf-md-refresh
                tooltipText: svc.loading ? "Refreshing…" : "Refresh now"
                foreground: root.foreground
                fontFamily: root.fontFamily
                opacity: svc.loading ? 0.5 : 1.0
                onClicked: root.refresh()
              }
            }
          }

          // ---------- Failure banner with the remedy, not just the symptom ----------
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: svc.failed

            Text {
              width: parent.width
              text: svc.errorMessage
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: svc.errorRemedy !== ""
              text: svc.errorRemedy
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            visible: !svc.failed && svc.actionStatus !== ""
            text: svc.actionStatus
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // ---------- Scenes ----------
          PanelSeparator {
            width: parent.width
            visible: svc.scenes.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: svc.scenes.length > 0
            text: "Scenes"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: svc.scenes

            Button {
              id: sceneRow
              required property var modelData

              readonly property bool busy: svc.isSceneBusy(modelData.name)
              readonly property bool runnable: modelData.actionCount > 0

              width: column.width
              leftAlign: true
              text: modelData.name
              iconText: busy ? "󰑐" : "󰐊"  // nf-md-refresh / nf-md-play
              iconSpinning: busy
              tooltipText: Model.sceneSubtitle(modelData)
              foreground: root.foreground
              accent: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.rowHasCursor("scene", modelData.name)
              // An empty scene is shown for context but cannot be run.
              enabled: runnable && !busy
              opacity: runnable ? 1.0 : 0.4

              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneRow)
              onHovered: function(on) { if (on) root.focusRow("scene", modelData.name) }
              onClicked: svc.triggerScene(modelData.name)
            }
          }

          // ---------- Devices, grouped by room ----------
          Repeater {
            model: svc.rooms

            Column {
              id: roomGroup
              required property var modelData

              width: column.width
              spacing: Style.space(4)

              PanelSeparator {
                width: parent.width
                foreground: root.foreground
              }

              PanelSectionHeader {
                text: roomGroup.modelData.room
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: roomGroup.modelData.devices

                Column {
                  id: deviceGroup
                  required property var modelData

                  readonly property bool busy: svc.isDeviceBusy(modelData.name)
                  readonly property bool live: modelData.reachable && !busy

                  width: roomGroup.width
                  spacing: 0

                  // Controllable accessory: an optimistic labeled toggle. The
                  // service flips the value the moment it is clicked, so the
                  // switch answers immediately and only snaps back if the
                  // write actually fails.
                  Toggle {
                    id: deviceToggle
                    visible: deviceGroup.modelData.controllable
                    width: parent.width
                    label: deviceGroup.modelData.name
                    description: {
                      if (deviceGroup.busy) return "Switching…"
                      if (!deviceGroup.modelData.reachable) return "Unreachable"
                      if (deviceGroup.modelData.unknown) return "State unknown"
                      if (deviceGroup.modelData.hasBrightness && deviceGroup.modelData.brightness !== null
                          && deviceGroup.modelData.power === true)
                        return deviceGroup.modelData.brightness + "%"
                      return deviceGroup.modelData.category
                    }
                    checked: deviceGroup.modelData.power === true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    hasCursor: root.rowHasCursor("device", deviceGroup.modelData.name)
                    enabled: deviceGroup.modelData.reachable
                    opacity: deviceGroup.modelData.reachable ? (deviceGroup.busy ? 0.7 : 1.0) : 0.45

                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(deviceToggle)
                    onHovered: function(on) { if (on) root.focusRow("device", deviceGroup.modelData.name) }
                    onClicked: {
                      if (deviceGroup.busy) return
                      svc.setPower(deviceGroup.modelData.name, deviceGroup.modelData.power !== true)
                    }
                  }

                  // Dimmer for lights that report brightness. The write fires
                  // on release only — a drag emits `moved` every frame, and
                  // each one would be a full SSH round trip.
                  PanelSlider {
                    id: dimmer
                    visible: deviceGroup.modelData.controllable && deviceGroup.modelData.hasBrightness
                    width: parent.width - Style.space(24)
                    x: Style.space(12)
                    bar: root.bar
                    minimum: 0
                    maximum: 100
                    step: 5
                    integer: true
                    value: deviceGroup.modelData.brightness === null ? 0 : deviceGroup.modelData.brightness
                    enabled: deviceGroup.modelData.reachable && !deviceGroup.busy
                    opacity: deviceGroup.modelData.reachable ? (deviceGroup.busy ? 0.7 : 1.0) : 0.45

                    onReleased: function(value) { svc.setBrightness(deviceGroup.modelData.name, value) }
                  }

                  // Read-only accessory (sensors, and anything whose category
                  // has no power characteristic worth flipping).
                  Item {
                    visible: !deviceGroup.modelData.controllable
                    width: parent.width
                    implicitHeight: Style.spacing.popupRowHeight
                    opacity: deviceGroup.modelData.reachable ? 1.0 : 0.45

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.spacing.rowPaddingX
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width * 0.5
                      text: deviceGroup.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.rightMargin: Style.spacing.rowPaddingX
                      anchors.verticalCenter: parent.verticalCenter
                      text: deviceGroup.modelData.readings.length > 0
                        ? deviceGroup.modelData.readings.join(" · ")
                        : (deviceGroup.modelData.reachable ? deviceGroup.modelData.category : "Unreachable")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }

          // ---------- Empty state ----------
          Text {
            width: parent.width
            visible: svc.everLoaded && svc.rooms.length === 0 && !svc.failed
            text: root.hiddenRoomsSetting.length > 0
              ? "Every room is hidden by the hiddenRooms setting."
              : "No accessories reported by HomeClaw."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !svc.everLoaded && !svc.failed
            text: "Loading accessories…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Footer hint ----------
          Text {
            width: parent.width
            text: "↑/↓ select · ⏎ toggle · ←/→ dim · R refresh"
            horizontalAlignment: Text.AlignRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
