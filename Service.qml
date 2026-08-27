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
// Accessories and scenes are identified by their HomeKit UUID everywhere below
// — overrides, in-flight maps, the rows the panel renders, and the argument
// `set`/`trigger` receive. Names are display text and nothing else: two rooms
// may each hold a "Lamp", and homeclaw-cli resolving a name picks the first
// one it finds.
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

  // Surrounding whitespace is a typo, not an intention; anything else odd
  // (leading dash, embedded spaces, control characters) is refused outright
  // rather than escaped, because ssh reads a leading dash as an option and
  // -oProxyCommand=… runs a command on THIS machine.
  readonly property string sshHost: String(host).trim()
  readonly property bool hostValid: Model.hostIsValid(sshHost)

  // A fresh install has no host at all. Nothing here may launch ssh until one
  // is set: an empty host would make ssh try to connect to the literal string
  // "" and the widget would report an unreachable Mac the user never named.
  // A host that cannot be used safely counts as no host, plus a stated reason.
  readonly property bool configured: sshHost !== "" && hostValid

  readonly property string invalidHostRemedy:
    "A host is a plain name, an ~/.ssh/config alias, or user@name — no leading dash, "
    + "no spaces. Set it with: omarchy bar set andrew.homekit host <your-mac>"

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

  // A refresh asked for while one is already in flight is remembered rather
  // than dropped: the caller wanted a read newer than the one running (a write
  // just landed, or the user hit R), and silently discarding it is how the
  // panel keeps showing a value the Mac no longer holds.
  property bool refreshPending: false

  property string errorKind: ""
  property string errorMessage: ""
  property string errorRemedy: ""
  readonly property bool failed: errorKind !== ""

  // Transient one-line feedback for a write or a scene trigger.
  property string actionStatus: ""

  // Every call gets a sequence number so completion order stops deciding which
  // error is on screen: a stale success cannot clear a failure reported after
  // it was launched. Without this an old refresh landing late wipes the error
  // from the write that just failed, and the bar goes back to healthy.
  property int opSeq: 0

  // The sequence number of the newest result the banner reflects — advanced by
  // successes as well as failures. One watermark rather than a failure-only
  // one: with the latter, op 2 failing, op 3 succeeding and clearing it, then
  // slow op 1 failing put op 1's error on screen, because nothing had recorded
  // that the health of the endpoint was last established at 3.
  property int statusSeq: -1

  // Which endpoint the state below belongs to. Changing host or cliPath points
  // the widget at a different Mac — quite possibly a different home with the
  // same accessory names — so everything derived from the old one is dropped
  // at once and every callback still in flight is discarded when it lands.
  property int endpointGeneration: 0

  // `rooms`/`scenes` above stay the source of truth for logic — counts, the
  // panel's keyboard cursor, id lookups. What the panel *renders* is these
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

  // All three are keyed by accessory/scene UUID, and all three are created
  // without a prototype: a HomeKit name (or a bridge-invented id) of
  // `__proto__` or `constructor` in an ordinary {} reads as already present
  // and quietly corrupts every lookup that follows.
  //
  // uuid -> { power?, brightness?, until: <ms epoch> }
  property var overrides: Object.create(null)
  // uuid -> number of writes in flight
  property var writesInFlight: Object.create(null)
  // scene uuid -> true while triggering
  property var scenesInFlight: Object.create(null)

  // How long an override outlives its write before the live value is believed
  // again. Long enough for a DIRIGERA/Hue bridge to report back, short enough
  // that a light someone else changed corrects itself quickly.
  readonly property int settleMs: 2500

  function isDeviceBusy(id) { return (root.writesInFlight[id] || 0) > 0 }
  function isSceneBusy(id) { return root.scenesInFlight[id] === true }

  function cloneMap(map) {
    var next = Object.create(null)
    for (var key in map) next[key] = map[key]
    return next
  }

  // --------------------------------------------------------- process pool
  //
  // Reads and writes overlap freely (toggle two lights, then a refresh lands),
  // so each invocation gets its own Process created on demand and destroyed on
  // exit rather than contending for a fixed set of declared ones.
  // An Item wrapping the Process rather than the bare Process the first draft
  // used: Process is a plain QObject with no default property, so it cannot
  // hold the watchdog Timer as a child.
  Component {
    id: jobComponent

    Item {
      id: job
      property var callback: null
      property bool finished: false

      // Set from Process.started. Quickshell reports QProcess::FailedToStart —
      // ssh missing, fork/exec refused by the OS — by clearing `running`, not
      // by emitting `exited`, so a job that never sets this and then stops
      // running never got off the ground and nothing else would ever call the
      // caller back: `loading`, or a row's busy state, would stay set forever.
      property bool launched: false
      property alias command: proc.command
      property alias running: proc.running

      // The single place a callback is allowed to run, so the watchdog and a
      // real exit can race without the caller's bookkeeping running twice.
      function finish(exitCode, out, err) {
        if (job.finished) return
        job.finished = true
        var cb = job.callback
        job.callback = null
        if (!cb) return
        try {
          cb(exitCode, out, err)
        } catch (e) {
          // A callback that throws must not take the job object (or the
          // `loading` flag it was going to clear) down with it.
          console.warn("andrew.homekit: job callback threw:", e)
        }
      }

      Process {
        id: proc
        running: false
        stdout: StdioCollector { id: jobOut; waitForEnd: true }
        stderr: StdioCollector { id: jobErr; waitForEnd: true }
        onStarted: job.launched = true
        onExited: function(exitCode, exitStatus) {
          try {
            job.finish(exitCode, String(jobOut.text || ""), String(jobErr.text || ""))
          } finally {
            job.destroy()
          }
        }
        // The only completion path for a process that never started. Every
        // other transition is uninteresting here: running going true, and
        // running going false after `started` (that one lands in onExited, or
        // has already been answered by the watchdog).
        onRunningChanged: {
          if (proc.running || job.launched || job.finished) return
          console.warn("andrew.homekit: ssh failed to start:", String(proc.command))
          job.finish(-1, "", "ssh could not be started on this machine")
          job.destroy()
        }
      }

      // ConnectTimeout only covers the handshake. A HomeClaw or remote shell
      // that hangs *after* connecting would otherwise leave `loading` or a
      // row's busy state set forever, so every job has a hard deadline: the
      // caller is told it timed out and the child is terminated (setting
      // running to false is Quickshell's terminate), which lands in onExited
      // and destroys the object.
      Timer {
        id: watchdog
        interval: 30000
        running: proc.running && !job.finished
        onTriggered: {
          console.warn("andrew.homekit: ssh job timed out after 30s:", String(proc.command))
          job.finish(-1, "", "timed out")
          proc.running = false
          hardKill.restart()
        }
      }

      // `running = false` is QProcess::terminate(), i.e. SIGTERM, which an ssh
      // stuck in an uninterruptible wait can sit on indefinitely. The caller's
      // bookkeeping was already released by the watchdog, so without this the
      // deadline is advisory and the child, its Process and this Item leak.
      //
      // Trade-off accepted deliberately: there is still no global cap on
      // concurrent jobs, so an IPC caller naming distinct UUIDs (which bypasses
      // the per-accessory busy check) can pile up ssh processes for up to 33 s
      // before this reaps them — the cost of never making a read queue behind
      // an unrelated write.
      Timer {
        id: hardKill
        interval: 3000
        onTriggered: {
          if (!proc.running) return
          console.warn("andrew.homekit: ssh job ignored SIGTERM, sending SIGKILL:", String(proc.command))
          proc.signal(9)
        }
      }
    }
  }

  function runJob(args, callback) {
    var command = Model.sshArgs(root.sshHost, root.cliPath, args, root.controlPath)
    if (!command) {
      console.warn("andrew.homekit: refusing to run ssh for an unusable host")
      if (callback) callback(-1, "", "invalid host")
      return null
    }
    var job = jobComponent.createObject(root, { command: command })
    if (!job) {
      console.warn("andrew.homekit: could not create ssh process for", args.join(" "))
      if (callback) callback(-1, "", "could not start ssh")
      return null
    }
    job.callback = callback
    job.running = true
    return job
  }

  // Wraps a callback so a result from the endpoint we were pointed at *then*
  // cannot write into the state of the endpoint we are pointed at *now*. The
  // Process still exits and destroys itself; the counters the callback would
  // have decremented were already reset wholesale by invalidateEndpoint().
  function guarded(generation, callback) {
    return function(exitCode, out, err) {
      if (generation !== root.endpointGeneration) return
      callback(exitCode, out, err)
    }
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

  function nextSeq() {
    root.opSeq = root.opSeq + 1
    return root.opSeq
  }

  // Global health is decided by the newest result only. Anything older than
  // the watermark is ignored here — it has already finished its own
  // bookkeeping (in-flight counts, overrides, the row it belongs to) by the
  // time it gets this far; all it is refused is the right to speak for the
  // whole endpoint.
  function reportSuccess(seq) {
    if (seq < root.statusSeq) return
    root.statusSeq = seq
    if (root.failed) clearFailure()
  }

  function reportFailure(seq, failure) {
    if (seq < root.statusSeq) return
    root.statusSeq = seq
    setFailure(failure)
  }

  function flashStatus(text) {
    root.actionStatus = Model.displayText(text)
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 3000
    onTriggered: root.actionStatus = ""
  }

  // ------------------------------------------------------------- endpoint
  //
  // Emitted once the old endpoint's state is *fully* gone, which is why the
  // panel listens for this rather than for endpointGeneration: the generation
  // has to change first (so callbacks in flight are discarded), but a refresh
  // triggered by that change ran while `loading` was still set from the old
  // read, marked itself pending, and was then wiped by the very clear it was
  // reacting to. No read of the new Mac started until the next poll.
  signal endpointInvalidated()

  function invalidateEndpoint() {
    root.endpointGeneration = root.endpointGeneration + 1

    root.rawAccessories = []
    root.scenes = []
    root.homeName = ""
    root.overrides = Object.create(null)
    root.writesInFlight = Object.create(null)
    root.scenesInFlight = Object.create(null)
    root.loading = false
    root.refreshPending = false
    root.everLoaded = false
    root.actionStatus = ""
    settleRefresh.stop()
    overrideExpiry.stop()
    clearFailure()
    root.statusSeq = -1

    rebuild()
    syncScenes()

    // Named but unusable is a configuration error worth stating; named as
    // nothing at all is a fresh install, and the panel shows the setup card.
    //
    // Computed from `host` rather than read off sshHost/hostValid: this runs
    // from onHostChanged, and a derived binding has not necessarily caught up
    // by the time the handler for the property it derives from is called.
    var trimmed = String(root.host).trim()
    if (trimmed !== "" && !Model.hostIsValid(trimmed)) {
      reportFailure(nextSeq(), {
        kind: "config",
        message: "Invalid host",
        remedy: root.invalidHostRemedy
      })
    }

    // Deferred one turn rather than emitted here, for two reasons. First, this
    // has to come after every flag above has settled, or a listener that
    // refreshes marks itself pending against the *old* read and is then wiped
    // by the clear it was reacting to. Second — and this is why callLater and
    // not just "last statement" — invalidateEndpoint runs from onHostChanged,
    // and sshHost/hostValid are bindings on `host` that have not necessarily
    // been re-evaluated yet: a read started inline goes to the OLD Mac under
    // the NEW generation, so its failure is accepted as the new endpoint's and
    // the Mac just pointed at is never read at all. By the next turn the
    // bindings have caught up.
    //
    // Generation-checked because a second change landing in that turn makes
    // this invalidation's listener call redundant — the newer one will emit.
    var generation = root.endpointGeneration
    Qt.callLater(function() {
      if (generation !== root.endpointGeneration) return
      root.endpointInvalidated()
    })
  }

  onHostChanged: invalidateEndpoint()
  onCliPathChanged: invalidateEndpoint()

  // A host that arrives with the object — the widget's saved setting, read
  // once at startup — never fires onHostChanged, so the state the two handlers
  // above establish has to be established here too. Nothing can be in flight
  // this early, so the generation bump costs nothing.
  Component.onCompleted: invalidateEndpoint()

  // ------------------------------------------------------------ overrides
  function applyOverride(id, values) {
    var next = cloneMap(root.overrides)
    var entry = next[id] ? next[id] : {}
    var merged = {}
    for (var existing in entry) merged[existing] = entry[existing]
    for (var k in values) merged[k] = values[k]
    merged.until = Date.now() + root.settleMs
    next[id] = merged
    root.overrides = next
    overrideExpiry.restart()
    rebuild()
  }

  function extendOverride(id) {
    if (!root.overrides[id]) return
    var next = cloneMap(root.overrides)
    var merged = {}
    for (var existing in next[id]) merged[existing] = next[id][existing]
    merged.until = Date.now() + root.settleMs
    next[id] = merged
    root.overrides = next
    overrideExpiry.restart()
  }

  function dropOverride(id) {
    if (!root.overrides[id]) return
    var next = Object.create(null)
    for (var key in root.overrides) if (key !== id) next[key] = root.overrides[key]
    root.overrides = next
    rebuild()
  }

  // Drop settled overrides so the live value is believed again. Anything with
  // a write still in flight is kept regardless of its timestamp.
  function pruneOverrides() {
    var now = Date.now()
    var next = Object.create(null)
    var changed = false
    for (var key in root.overrides) {
      var entry = root.overrides[key]
      if (root.isDeviceBusy(key) || now < Number(entry.until || 0)) next[key] = entry
      else changed = true
    }
    if (changed) root.overrides = next
  }

  // An override used to be inspected only by a successful list refresh — and
  // the sole follow-up read fires long before the window is up, so nothing
  // normally expired it: a write the bridge acknowledged but did not apply
  // could show the requested value until the next poll, or forever behind a
  // closed panel. This fires once the last write's window has actually passed
  // and puts the last value the Mac reported back on screen.
  Timer {
    id: overrideExpiry
    interval: root.settleMs + 100
    onTriggered: {
      root.pruneOverrides()
      root.rebuild()
      // Rebuilding alone puts the *cached* value back, and that cache is the
      // settling read taken at 900 ms — before a bridge that reports back at
      // 1.5 s. Expiry therefore reconciles against the Mac rather than against
      // that stale read. This is write-triggered, not polling: it fires at most
      // once per settling window after a write someone actually made, so the
      // one extra SSH round trip behind a closed panel is acceptable.
      // refreshPending covers the case where the settling read is still in
      // flight when this lands.
      root.refresh()
    }
  }

  function markWrite(id, delta) {
    var next = cloneMap(root.writesInFlight)
    var count = (next[id] || 0) + delta
    if (count > 0) next[id] = count
    else delete next[id]
    root.writesInFlight = next
  }

  function markScene(id, active) {
    var next = cloneMap(root.scenesInFlight)
    if (active) next[id] = true
    else delete next[id]
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
    if (root.loading) { root.refreshPending = true; return }
    root.loading = true
    root.refreshPending = false

    // Captured, not read back when a result lands: the message a failure ends
    // up wearing must name the Mac the call was actually made to.
    var generation = root.endpointGeneration
    var endpointHost = root.sshHost
    var endpointCli = root.cliPath
    var seq = nextSeq()
    var remaining = 2
    var failure = null

    function settle() {
      remaining -= 1
      if (remaining > 0) return
      if (generation !== root.endpointGeneration) return
      root.loading = false
      if (failure) reportFailure(seq, failure)
      else reportSuccess(seq)
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
      }
    }

    // Both callbacks settle from a `finally`: a parse that throws used to
    // leave `loading` set and every later refresh a no-op until the plugin
    // reloaded.
    runJob(["list", "--json"], guarded(generation, function(exitCode, out, err) {
      try {
        if (exitCode === 0) {
          var parsed = Model.parseJson(out)
          // Not `.length !== undefined`: a bare JSON string has a length too.
          if (parsed.ok && Array.isArray(parsed.value)) {
            root.rawAccessories = parsed.value
            root.pruneOverrides()
            root.rebuild()
            root.everLoaded = true
          } else if (!failure) {
            failure = {
              kind: "cli",
              message: Model.displayText(parsed.ok ? "Unexpected output from list" : parsed.message),
              remedy: ""
            }
          }
        } else if (!failure) {
          failure = Model.classifyFailure(exitCode, err, endpointHost, endpointCli)
        }
      } catch (e) {
        console.warn("andrew.homekit: reading the accessory list threw:", e)
        if (!failure) failure = { kind: "cli", message: "Could not read the accessory list", remedy: "" }
      } finally {
        settle()
      }
    }))

    runJob(["scenes", "--json"], guarded(generation, function(exitCode, out, err) {
      try {
        if (exitCode === 0) {
          var parsed = Model.parseJson(out)
          if (parsed.ok && Array.isArray(parsed.value)) {
            var built = Model.buildScenes(parsed.value)
            // Assigned unconditionally: a home with no scenes cannot report a
            // name, and keeping the last one leaves the hero naming a home
            // this Mac is no longer signed in to. Empty falls back to
            // "HomeKit" in the panel.
            root.homeName = built.homeName
            root.scenes = built.scenes
            root.syncScenes()
          } else if (!failure) {
            failure = {
              kind: "cli",
              message: Model.displayText(parsed.ok ? "Unexpected output from scenes" : parsed.message),
              remedy: ""
            }
          }
        } else if (!failure) {
          failure = Model.classifyFailure(exitCode, err, endpointHost, endpointCli)
        }
      } catch (e) {
        console.warn("andrew.homekit: reading scenes threw:", e)
        if (!failure) failure = { kind: "cli", message: "Could not read the scene list", remedy: "" }
      } finally {
        settle()
      }
    }))
  }

  // A write is confirmed by the CLI before HomeKit has necessarily propagated
  // it, so the follow-up read is deferred rather than fired immediately.
  Timer {
    id: settleRefresh
    interval: 900
    onTriggered: root.refresh()
  }

  // --------------------------------------------------------------- writes
  //
  // `id` is a HomeKit UUID (homeclaw-cli takes a name or a UUID for both `set`
  // and `trigger`); the name only ever appears in the status line.
  function setCharacteristic(id, property, value, optimistic, label) {
    if (!root.configured) { root.flashStatus("Set a host first"); return }
    if (root.isDeviceBusy(id)) return

    var generation = root.endpointGeneration
    var endpointHost = root.sshHost
    var endpointCli = root.cliPath
    var seq = nextSeq()
    markWrite(id, 1)
    applyOverride(id, optimistic)

    runJob(["set", id, property, String(value), "--json"], guarded(generation, function(exitCode, out, err) {
      markWrite(id, -1)
      if (exitCode === 0) {
        root.extendOverride(id)
        reportSuccess(seq)
        if (label) root.flashStatus(label)
        settleRefresh.restart()
      } else {
        root.dropOverride(id)
        reportFailure(seq, Model.classifyFailure(exitCode, err, endpointHost, endpointCli))
      }
    }))
  }

  function deviceLabel(id) {
    var device = Model.findDevice(root.rooms, id)
    return Model.displayText(device ? device.name : id)
  }

  function setPower(id, on) {
    setCharacteristic(id, "power", on ? "true" : "false", { power: on },
                      deviceLabel(id) + (on ? " on" : " off"))
  }

  function setBrightness(id, level) {
    var clamped = Math.max(0, Math.min(100, Math.round(level)))
    // Dimming a light that HomeKit believes is off turns it on; reflect that
    // in the same optimistic pass so the row does not read "off at 60%".
    setCharacteristic(id, "brightness", clamped,
                      { brightness: clamped, power: clamped > 0 ? true : undefined },
                      deviceLabel(id) + " " + clamped + "%")
  }

  function triggerScene(id) {
    if (!root.configured) { root.flashStatus("Set a host first"); return }
    if (root.isSceneBusy(id)) return

    var generation = root.endpointGeneration
    var endpointHost = root.sshHost
    var endpointCli = root.cliPath
    var seq = nextSeq()
    var scene = Model.findScene(root.scenes, id)
    var label = Model.displayText(scene ? scene.name : id)

    markScene(id, true)
    runJob(["trigger", id], guarded(generation, function(exitCode, out, err) {
      markScene(id, false)
      if (exitCode === 0) {
        reportSuccess(seq)
        root.flashStatus("Ran " + label)
        settleRefresh.restart()
      } else {
        reportFailure(seq, Model.classifyFailure(exitCode, err, endpointHost, endpointCli))
      }
    }))
  }
}
