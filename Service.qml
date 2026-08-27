import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// SSH/CLI data layer for the HomeKit panel.
//
// Every HomeKit call is one `ssh <host> homeclaw-cli …` invocation, launched
// as an argv array so nothing on this side is ever handed to a local shell
// (Model.quote handles the *remote* shell, which ssh unavoidably interposes).
// Reads run only while the panel is open — an SSH round trip per tick is far
// too heavy to leave running behind a closed panel, and the bar icon needs no
// live accessory state.
//
// Writes are optimistic: the requested value is overlaid on the parsed model
// immediately so the switch answers the click, held through the round trip and
// for a settling window afterwards (HomeKit reports a new value back through
// the bridge a beat late), and dropped on failure so the row snaps back to the
// truth alongside the error.
Item {
  id: root

  property string host: ""
  property string cliPath: "/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli"
  property var hiddenRooms: []

  // A fresh install has no host at all. Nothing here may launch ssh until one
  // is set: an empty host would make ssh try to connect to the literal string
  // "" and the widget would report an unreachable Mac the user never named.
  readonly property bool configured: String(host).trim() !== ""

  // Emptying the host retires whatever the previous one failed with; the panel
  // shows the setup card in place of the error.
  onConfiguredChanged: if (!configured) clearFailure()

  // Per-user runtime dir keeps the control socket out of shared /tmp. %C is
  // ssh's hash of host/port/user, so several hosts never collide.
  readonly property string controlPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/homekit-ssh-%C"

  // ---------------------------------------------------------------- state
  property var rawAccessories: []
  property var rooms: []
  property var scenes: []
  property string homeName: ""

  property bool loading: false
  property bool everLoaded: false

  property string errorKind: ""
  property string errorMessage: ""
  property string errorRemedy: ""
  readonly property bool failed: errorKind !== ""

  // Transient one-line feedback for a write or a scene trigger.
  property string actionStatus: ""

  // `rooms`/`scenes` above stay the source of truth for logic — counts, the
  // panel's keyboard cursor, name lookups. What the panel *renders* is these
  // two ListModels, kept in step by a diff so a refresh touches only the rows
  // that actually changed; see the render projections in Model.js for why.
  ListModel { id: sceneRows }
  ListModel { id: deviceRows }
  readonly property alias scenesModel: sceneRows
  readonly property alias rowsModel: deviceRows

  // Property-only updates leave the delegates — and therefore the scroll
  // position — alone. Inserting or removing rows still relays out the column,
  // so the panel gets a beat of warning before those and only those.
  signal modelAboutToChange()

  readonly property int deviceCount: Model.countDevices(rooms)
  readonly property int poweredOnCount: Model.countPoweredOn(rooms)

  // name -> { power?, brightness?, until: <ms epoch> }
  property var overrides: ({})
  // name -> number of writes in flight
  property var writesInFlight: ({})
  // scene name -> true while triggering
  property var scenesInFlight: ({})

  // How long an override outlives its write before the live value is believed
  // again. Long enough for a DIRIGERA/Hue bridge to report back, short enough
  // that a light someone else changed corrects itself quickly.
  readonly property int settleMs: 2500

  function isDeviceBusy(name) { return (writesInFlight[name] || 0) > 0 }
  function isSceneBusy(name) { return scenesInFlight[name] === true }

  // --------------------------------------------------------- process pool
  //
  // Reads and writes overlap freely (toggle two lights, then a refresh lands),
  // so each invocation gets its own Process created on demand and destroyed on
  // exit rather than contending for a fixed set of declared ones.
  Component {
    id: jobComponent

    Process {
      id: job
      property var callback: null
      running: false
      stdout: StdioCollector { id: jobOut; waitForEnd: true }
      stderr: StdioCollector { id: jobErr; waitForEnd: true }
      onExited: function(exitCode, exitStatus) {
        var cb = job.callback
        job.callback = null
        if (cb) cb(exitCode, String(jobOut.text || ""), String(jobErr.text || ""))
        job.destroy()
      }
    }
  }

  function runJob(args, callback) {
    var job = jobComponent.createObject(root, {
      command: Model.sshArgs(root.host, root.cliPath, args, root.controlPath)
    })
    if (!job) {
      console.warn("andrew.homekit: could not create ssh process for", args.join(" "))
      if (callback) callback(-1, "", "could not start ssh")
      return null
    }
    job.callback = callback
    job.running = true
    return job
  }

  // ------------------------------------------------------------- failures
  function setFailure(failure) {
    root.errorKind = failure.kind
    root.errorMessage = failure.message
    root.errorRemedy = failure.remedy || ""
  }

  function clearFailure() {
    root.errorKind = ""
    root.errorMessage = ""
    root.errorRemedy = ""
  }

  function flashStatus(text) {
    root.actionStatus = text
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 3000
    onTriggered: root.actionStatus = ""
  }

  // ------------------------------------------------------------ overrides
  function applyOverride(name, values) {
    var next = {}
    for (var key in root.overrides) next[key] = root.overrides[key]
    var entry = next[name] ? next[name] : {}
    var merged = {}
    for (var existing in entry) merged[existing] = entry[existing]
    for (var k in values) merged[k] = values[k]
    merged.until = Date.now() + root.settleMs
    next[name] = merged
    root.overrides = next
    rebuild()
  }

  function extendOverride(name) {
    if (!root.overrides[name]) return
    var next = {}
    for (var key in root.overrides) next[key] = root.overrides[key]
    var merged = {}
    for (var existing in next[name]) merged[existing] = next[name][existing]
    merged.until = Date.now() + root.settleMs
    next[name] = merged
    root.overrides = next
  }

  function dropOverride(name) {
    if (!root.overrides[name]) return
    var next = {}
    for (var key in root.overrides) if (key !== name) next[key] = root.overrides[key]
    root.overrides = next
    rebuild()
  }

  // Drop settled overrides so the live value is believed again. Anything with
  // a write still in flight is kept regardless of its timestamp.
  function pruneOverrides() {
    var now = Date.now()
    var next = {}
    var changed = false
    for (var key in root.overrides) {
      var entry = root.overrides[key]
      if (root.isDeviceBusy(key) || now < Number(entry.until || 0)) next[key] = entry
      else changed = true
    }
    if (changed) root.overrides = next
  }

  function markWrite(name, delta) {
    var next = {}
    for (var key in root.writesInFlight) next[key] = root.writesInFlight[key]
    var count = (next[name] || 0) + delta
    if (count > 0) next[name] = count
    else delete next[name]
    root.writesInFlight = next
  }

  function markScene(name, active) {
    var next = {}
    for (var key in root.scenesInFlight) next[key] = root.scenesInFlight[key]
    if (active) next[name] = true
    else delete next[name]
    root.scenesInFlight = next
  }

  function rebuild() {
    root.rooms = Model.buildRooms(root.rawAccessories, root.hiddenRooms, root.overrides)
    syncInto(deviceRows, Model.projectRooms(root.rooms))
  }

  function syncScenes() {
    syncInto(sceneRows, Model.projectScenes(root.scenes))
  }

  function syncInto(model, rows) {
    // Asked before the sync rather than reported by it: the panel has to
    // capture contentY while the old delegates are still standing.
    if (Model.structureDiffers(model, rows)) root.modelAboutToChange()
    Model.syncModel(model, rows)
  }

  onHiddenRoomsChanged: rebuild()

  // ---------------------------------------------------------------- reads
  function refresh() {
    if (!root.configured) return
    if (root.loading) return
    root.loading = true

    var remaining = 2
    var failure = null

    function settle() {
      remaining -= 1
      if (remaining > 0) return
      root.loading = false
      if (failure) setFailure(failure)
      else clearFailure()
    }

    runJob(["list", "--json"], function(exitCode, out, err) {
      if (exitCode === 0) {
        var parsed = Model.parseJson(out)
        if (parsed.ok && parsed.value && parsed.value.length !== undefined) {
          root.rawAccessories = parsed.value
          root.pruneOverrides()
          root.rebuild()
          root.everLoaded = true
        } else if (!failure) {
          failure = { kind: "cli", message: parsed.message || "Unexpected output from list", remedy: "" }
        }
      } else if (!failure) {
        failure = Model.classifyFailure(exitCode, err, root.host, root.cliPath)
      }
      settle()
    })

    runJob(["scenes", "--json"], function(exitCode, out, err) {
      if (exitCode === 0) {
        var parsed = Model.parseJson(out)
        if (parsed.ok && parsed.value && parsed.value.length !== undefined) {
          var built = Model.buildScenes(parsed.value)
          if (built.homeName !== "") root.homeName = built.homeName
          root.scenes = built.scenes
          root.syncScenes()
        } else if (!failure) {
          failure = { kind: "cli", message: parsed.message || "Unexpected output from scenes", remedy: "" }
        }
      } else if (!failure) {
        failure = Model.classifyFailure(exitCode, err, root.host, root.cliPath)
      }
      settle()
    })
  }

  // A write is confirmed by the CLI before HomeKit has necessarily propagated
  // it, so the follow-up read is deferred rather than fired immediately.
  Timer {
    id: settleRefresh
    interval: 900
    onTriggered: root.refresh()
  }

  // --------------------------------------------------------------- writes
  function setCharacteristic(name, property, value, optimistic, label) {
    if (!root.configured) { root.flashStatus("Set a host first"); return }
    if (root.isDeviceBusy(name)) return
    markWrite(name, 1)
    applyOverride(name, optimistic)

    runJob(["set", name, property, String(value), "--json"], function(exitCode, out, err) {
      markWrite(name, -1)
      if (exitCode === 0) {
        root.clearFailure()
        root.extendOverride(name)
        if (label) root.flashStatus(label)
        settleRefresh.restart()
      } else {
        root.dropOverride(name)
        setFailure(Model.classifyFailure(exitCode, err, root.host, root.cliPath))
      }
    })
  }

  function setPower(name, on) {
    setCharacteristic(name, "power", on ? "true" : "false", { power: on },
                      name + (on ? " on" : " off"))
  }

  function setBrightness(name, level) {
    var clamped = Math.max(0, Math.min(100, Math.round(level)))
    // Dimming a light that HomeKit believes is off turns it on; reflect that
    // in the same optimistic pass so the row does not read "off at 60%".
    setCharacteristic(name, "brightness", clamped,
                      { brightness: clamped, power: clamped > 0 ? true : undefined },
                      name + " " + clamped + "%")
  }

  function triggerScene(name) {
    if (!root.configured) { root.flashStatus("Set a host first"); return }
    if (root.isSceneBusy(name)) return
    markScene(name, true)
    runJob(["trigger", name], function(exitCode, out, err) {
      markScene(name, false)
      if (exitCode === 0) {
        root.clearFailure()
        root.flashStatus("Ran " + name)
        settleRefresh.restart()
      } else {
        setFailure(Model.classifyFailure(exitCode, err, root.host, root.cliPath))
      }
    })
  }
}
