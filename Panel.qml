import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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

  // Read back by BarWidget.qml to tint the bar icon and pick its tooltip. An
  // unconfigured widget is not a broken one, so the bar stays neutral and says
  // so rather than painting the urgent colour at someone who has installed the
  // plugin thirty seconds ago.
  readonly property bool lastCallFailed: svc.failed
  readonly property string errorMessage: svc.errorMessage
  readonly property bool configured: svc.configured

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
  readonly property string hostSetting: String(setting("host", ""))
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
    if (!root.configured) return "Not configured"
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

  // Inserting or removing rows relays out the column, and for the frame it is
  // short the Flickable clamps contentY toward 0. Ordinary refreshes only
  // update roles in place and never come through here; the service signals
  // just before a structural change, so the position is captured while it is
  // still real and put back once the new delegates have laid out (callLater
  // for the common case, plus one timer tick for late positioner passes).
  // ---- trackpad kinetic scrolling (ported from andrew.daily-bible).
  //
  // On Linux/Wayland there are no OS-synthesized momentum wheel events, so
  // Flickable's stock wheel handling is direct-drive and sluggish: content
  // stops dead the moment fingers leave the pad. Wheel events are intercepted
  // by an overlay MouseArea, scaled, and their velocity measured over a
  // trailing window; when the stream goes quiet the tail velocity is handed to
  // Flickable's own flick() physics, which already knows how to decelerate.
  // Default compensates the Hyprland touchpad scroll_factor (0.4 here):
  // 4.0 × 0.4 ≈ 1.6× effective, comparable to a browser's feel.
  readonly property real wheelSpeed: Number(setting("scrollSpeed", 4.0)) || 4.0
  property var wheelSamples: []

  function wheelScroll(dy) {
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    flick.cancelFlick()
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    flick.contentY = Math.max(0, Math.min(maxY, flick.contentY - dy))
    var now = Date.now()
    var samples = wheelSamples
    samples.push({ t: now, dy: dy })
    while (samples.length > 0 && now - samples[0].t > 120) samples.shift()
    flickHandoff.restart()
  }

  Timer {
    id: flickHandoff
    interval: 70  // longer than any inter-event gap while fingers move
    onTriggered: {
      var samples = root.wheelSamples
      root.wheelSamples = []
      if (samples.length < 2) return
      var flick = scrollArea.contentItem
      if (!flick || flick.contentY === undefined) return
      var span = (samples[samples.length - 1].t - samples[0].t) / 1000
      if (span <= 0) return
      var sum = 0
      for (var i = 0; i < samples.length; i++) sum += samples[i].dy
      var velocity = sum / span  // px/s; positive = upward swipe direction
      velocity = Math.max(-flick.maximumFlickVelocity, Math.min(flick.maximumFlickVelocity, velocity))
      // Ignore the tail of a slow, deliberate scroll — only real swipes glide.
      if (Math.abs(velocity) > 300) flick.flick(0, velocity)
    }
  }

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
        Binding { target: scrollArea.contentItem; property: "boundsBehavior"; value: Flickable.StopAtBounds }
        Binding { target: scrollArea.contentItem; property: "flickableDirection"; value: Flickable.VerticalFlick }
        Binding { target: scrollArea.contentItem; property: "maximumFlickVelocity"; value: 4000 }
        Binding { target: scrollArea.contentItem; property: "flickDeceleration"; value: 1200 }

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

            // The remedy is the half of a failure banner worth reading, so it
            // is not a dimmer footnote under the symptom: same size as the
            // message, near-full foreground, and arrow-led so the eye lands on
            // "here is what to do" rather than "here is what broke".
            Text {
              width: parent.width
              visible: svc.errorRemedy !== ""
              text: "󰁔  " + svc.errorRemedy  // nf-md-arrow_right
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              lineHeight: 1.2
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

          // ---------- First run: no host set yet ----------
          //
          // Stands in for the whole scenes/accessories body rather than sitting
          // above it, because with no host there is nothing to sit above. The
          // steps are the actual chain this widget depends on, in the order it
          // walks them (app on the Mac -> sshd -> a name that resolves -> the
          // setting), so whichever link a reader has not done yet is the one
          // they are looking at.
          Column {
            id: setupCard
            width: parent.width
            spacing: Style.space(8)
            visible: !root.configured

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: "Point this at a Mac running HomeClaw"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [
                  "Install HomeClaw from the Mac App Store. Open it once so macOS can grant it HomeKit access, and turn on launch-at-login in its menu bar item.",
                  "On the Mac, enable Remote Login (System Settings \u2192 General \u2192 Sharing), then add this machine's ssh public key to ~/.ssh/authorized_keys there.",
                  "Make the Mac reachable from here \u2014 a Tailscale MagicDNS name, or a Host alias in ~/.ssh/config. Running \"ssh <name> true\" should succeed with no password prompt.",
                  "Then set the host:"
                ]

                Item {
                  id: step
                  required property int index
                  required property var modelData

                  width: setupCard.width
                  implicitHeight: stepText.implicitHeight

                  Text {
                    id: stepNumber
                    text: (step.index + 1) + "."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    id: stepText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(18)
                    anchors.right: parent.right
                    text: String(step.modelData)
                    color: root.foreground
                    opacity: 0.9
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    lineHeight: 1.25
                  }
                }
              }
            }

            // The one line a reader is meant to copy, so it gets its own row
            // at full foreground rather than being buried in step 4's prose.
            Text {
              x: Style.space(18)
              width: parent.width - Style.space(18)
              text: "omarchy bar set andrew.homekit host <your-mac>"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              wrapMode: Text.WrapAnywhere
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: "Stuck? Run bin/homekit-doctor <your-mac> from the plugin directory "
                  + "(~/.config/omarchy/plugins/andrew.homekit) \u2014 it checks each step above "
                  + "and says which one is failing. The README there has the long version."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              lineHeight: 1.25
            }
          }

          // ---------- Scenes ----------
          PanelSeparator {
            width: parent.width
            visible: root.configured && svc.scenes.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: root.configured && svc.scenes.length > 0
            text: "Scenes"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Scenes are short names, so they pack as a wrapping flow of pill
          // buttons rather than one full-width row each: quicker to scan and
          // a fraction of the height. Keyboard order is still left-to-right,
          // top-to-bottom, matching the model order.
          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.configured && svc.scenes.length > 0

            Repeater {
              model: svc.scenesModel

              Button {
                id: sceneRow
                required property string name
                required property string subtitle
                required property bool runnable

                readonly property bool busy: svc.isSceneBusy(sceneRow.name)

                bordered: true
                text: sceneRow.name
                iconText: busy ? "󰑐" : "󰐊"  // nf-md-refresh / nf-md-play
                iconSpinning: busy
                tooltipText: sceneRow.subtitle
                foreground: root.foreground
                accent: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.rowHasCursor("scene", sceneRow.name)
                // An empty scene is shown for context but cannot be run.
                enabled: sceneRow.runnable && !busy
                opacity: sceneRow.runnable ? 1.0 : 0.4

                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneRow)
                onHovered: function(on) { if (on) root.focusRow("scene", sceneRow.name) }
                onClicked: svc.triggerScene(sceneRow.name)
              }
            }
          }

          // ---------- Devices, grouped by room ----------
          //
          // One flat model of room-header and device rows (Model.projectRooms
          // builds it) rendered by a single Repeater, so a refresh diffs into
          // the existing delegates instead of tearing down a nest of them.
          // Rows inside a room sit closer together than the sections above, so
          // a header row pads itself back out to the section gap.
          Column {
            id: deviceColumn
            width: parent.width
            visible: root.configured && svc.rowsModel.count > 0
            spacing: Style.space(4)

            Repeater {
              model: svc.rowsModel

              Column {
                id: row
                required property int index
                required property string kind
                required property string name
                required property string category
                required property string readingsText
                required property bool controllable
                required property bool reachable
                required property bool unknown
                required property bool hasBrightness
                required property bool power
                required property int brightness

                readonly property bool isDevice: row.kind === "device"
                readonly property bool busy: row.isDevice && svc.isDeviceBusy(row.name)

                width: deviceColumn.width
                spacing: row.isDevice ? 0 : Style.space(4)

                Item {
                  visible: !row.isDevice && row.index > 0
                  width: 1
                  height: Style.space(2)
                }

                PanelSeparator {
                  visible: !row.isDevice
                  width: parent.width
                  foreground: root.foreground
                }

                PanelSectionHeader {
                  visible: !row.isDevice
                  text: row.name
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // Controllable accessory: an optimistic labeled toggle. The
                // service flips the value the moment it is clicked, so the
                // switch answers immediately and only snaps back if the
                // write actually fails.
                Toggle {
                  id: deviceToggle
                  visible: row.isDevice && row.controllable
                  width: parent.width
                  label: row.name
                  description: {
                    if (row.busy) return "Switching…"
                    if (!row.reachable) return "Unreachable"
                    if (row.unknown) return "State unknown"
                    if (row.hasBrightness && row.brightness >= 0 && row.power)
                      return row.brightness + "%"
                    return row.category
                  }
                  checked: row.power
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.rowHasCursor("device", row.name)
                  enabled: row.reachable
                  opacity: row.reachable ? (row.busy ? 0.7 : 1.0) : 0.45

                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(deviceToggle)
                  onHovered: function(on) { if (on) root.focusRow("device", row.name) }
                  onClicked: {
                    if (row.busy) return
                    svc.setPower(row.name, !row.power)
                  }
                }

                // Dimmer for lights that report brightness. The write fires
                // on release only — a drag emits `moved` every frame, and
                // each one would be a full SSH round trip. Dimmer.qml rather
                // than qs.Ui.PanelSlider because upstream turns every wheel
                // tick into a `released`, i.e. an SSH write per notch of a
                // scroll gesture that was only meant to scroll the list.
                Dimmer {
                  visible: row.isDevice && row.controllable && row.hasBrightness
                  width: parent.width - Style.space(24)
                  x: Style.space(12)
                  bar: root.bar
                  minimum: 0
                  maximum: 100
                  step: 5
                  integer: true
                  // -1 is "has the characteristic, has never reported a
                  // value"; the track sits at zero rather than guessing.
                  value: row.brightness < 0 ? 0 : row.brightness
                  enabled: row.reachable && !row.busy
                  opacity: row.reachable ? (row.busy ? 0.7 : 1.0) : 0.45

                  onReleased: function(value) { svc.setBrightness(row.name, value) }
                }

                // Read-only accessory (sensors, and anything whose category
                // has no power characteristic worth flipping).
                Item {
                  visible: row.isDevice && !row.controllable
                  width: parent.width
                  implicitHeight: Style.spacing.popupRowHeight
                  opacity: row.reachable ? 1.0 : 0.45

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * 0.5
                    text: row.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.readingsText !== ""
                      ? row.readingsText
                      : (row.reachable ? row.category : "Unreachable")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }

          // ---------- Empty state ----------
          Text {
            width: parent.width
            visible: root.configured && svc.everLoaded && svc.rooms.length === 0 && !svc.failed
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
            visible: root.configured && !svc.everLoaded && !svc.failed
            text: "Loading accessories…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Footer hint ----------
          Text {
            width: parent.width
            visible: root.configured
            text: "↑/↓ select · ⏎ toggle · ←/→ dim · R refresh"
            horizontalAlignment: Text.AlignRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Wheel interceptor: topmost overlay MouseArea (the same idiom the
      // shell's bar widgets use for trackpad scroll). NoButton keeps clicks
      // and drags falling through to the rows beneath; wheel events —
      // including the phased per-frame pixelDelta stream a trackpad produces —
      // are consumed here so the ScrollView's laggy drag-emulation path never
      // engages, and so no slider or toggle ever sees them. Discrete mouse
      // wheels deliver only angleDelta, scaled so one notch is a comfortable
      // step.
      MouseArea {
        anchors.fill: scrollArea
        z: 10
        acceptedButtons: Qt.NoButton
        onWheel: function(w) {
          var dy = w.pixelDelta.y !== 0
            ? w.pixelDelta.y * root.wheelSpeed
            : (w.angleDelta.y / 120) * Style.space(90)
          root.wheelScroll(dy)
          w.accepted = true
        }
      }
    }
  }
}
