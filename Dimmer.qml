import QtQuick
import qs.Commons
// Upstream got BorderSurface for free by living in qs.Ui; from out here the
// knob needs the import spelled out.
import qs.Ui

// qs.Ui.PanelSlider, minus wheel handling. Drag, click-to-set and the
// right-click signal are byte-for-byte the upstream behaviour; only the
// MouseArea's `onWheel` is gone, plus preventStealing/onCanceled so drags
// survive vertical drift inside the scrolling list (see the MouseArea).
//
// Upstream consumes every wheel tick over the track and emits `moved` AND
// `released` per tick, off angleDelta.y — so a two-finger scroll down the
// panel that happens to pass over a dimmer never reaches the Flickable, and
// each tick fires `released`, which here is a real SSH write to a real lamp.
// A MouseArea with nothing connected to `wheel` leaves the event unaccepted
// (Qt only accepts it when the signal has a receiver), so it propagates up to
// the ScrollView and the list scrolls as it should.
Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "#333"
  property color fillColor: bar ? bar.foreground : Color.foreground
  property color knobColor: bar ? bar.foreground : Color.foreground
  property bool dragging: false
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  property real liveValue: value

  // macOS-style notches. When > 1, that many evenly-spaced tick marks are cut
  // into the track (drawn in the panel background color, so only the part
  // crossing the track shows). Purely visual — snapping is the caller's job via
  // `integer`/`step` or an index-based value. Default 0 leaves the track plain.
  property int tickCount: 0
  property color tickColor: bar ? bar.background : Color.background

  onValueChanged: if (!dragging) liveValue = value

  signal moved(real value)
  signal released(real value)

  // Right-click is a secondary action on the whole track — audio uses it to
  // mute the channel the slider belongs to. Dragging stays left-button only.
  signal rightClicked()

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool _hot: mouseArea.containsMouse || root.dragging

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    id: fill
    anchors.verticalCenter: track.verticalCenter
    anchors.left: track.left
    height: track.height
    radius: track.radius
    color: root.fillColor
    width: track.width * root.progress

    Behavior on width {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
  }

  Repeater {
    model: root.tickCount > 1 ? root.tickCount : 0
    Rectangle {
      required property int index
      width: Math.max(1, Style.space(2))
      height: root.trackHeight + Style.space(4)
      radius: 1
      color: root.tickColor
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width,
                              track.width * (index / (root.tickCount - 1)) - width / 2))
    }
  }

  BorderSurface {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
    scale: root._hot ? 1.15 : 1.0

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // Hold the mouse grab for the whole drag. Without this the enclosing
    // Flickable steals the grab as soon as the pointer drifts vertically past
    // Qt's drag threshold, the drag dies mid-gesture, and — since a stolen
    // grab delivers `canceled` rather than `released` — `dragging` was left
    // stuck true, with hover moves steering the knob until the next click.
    // Only mouse.x is read, so wandering above/below the track is fine.
    preventStealing: true

    function valueFromX(x) {
      var clamped = Math.max(0, Math.min(track.width, x))
      var raw = root.minimum + (clamped / track.width) * root.range
      if (root.integer) raw = Math.round(raw)
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = true
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      var next = valueFromX(mouse.x)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
    // Grab lost some other way (popup closed under us, window focus change).
    // Treat it as a release at the last known value so drag state can never
    // be stranded.
    onCanceled: function() {
      if (!root.dragging) return
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
  }
}
