.pragma library

// Pure data layer for the HomeKit bar widget: command construction, JSON
// parsing, state coercion, room grouping, and failure classification. No QML
// types are touched here so every function is trivially testable in isolation.

// ---------------------------------------------------------------- commands

// ssh does NOT forward its remote argv as a vector: it joins the arguments
// after the hostname with single spaces and hands the resulting string to the
// login shell on the far side. Every HomeKit accessory name in this house has
// a space in it ("Black Lamp", "Lea's Standing Lamp"), so each remote-side
// word must arrive already quoted FOR THAT SHELL or it would arrive as two
// arguments. POSIX single-quote escaping: close, backslash-escaped quote,
// reopen — which is also why an apostrophe in a HomeKit name is safe.
function quote(value) {
  return "'" + String(value).split("'").join("'\\''") + "'"
}

// Multiplexing matters here: a cold SSH handshake to the Mac costs ~1s, and a
// panel refresh is two calls with a third following every write. ControlMaster
// collapses them onto one connection that lingers for five minutes.
function sshArgs(host, cliPath, args, controlPath) {
  var command = [
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" + String(controlPath),
    "-o", "ControlPersist=300",
    String(host),
    quote(cliPath)
  ]
  for (var i = 0; i < args.length; i++) command.push(quote(args[i]))
  return command
}

// ----------------------------------------------------------------- parsing

function parseJson(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, message: "homeclaw-cli returned nothing" }
  try {
    return { ok: true, value: JSON.parse(raw) }
  } catch (e) {
    return { ok: false, message: "Unreadable JSON from homeclaw-cli: " + e }
  }
}

// HomeClaw reports every characteristic as a string, using "--" for "this
// accessory has the characteristic but its value is currently unknown"
// (typically an unreachable bulb behind a reachable bridge).
function coerceBool(value) {
  if (value === undefined || value === null) return null
  var s = String(value).trim().toLowerCase()
  if (s === "true" || s === "1" || s === "on" || s === "yes") return true
  if (s === "false" || s === "0" || s === "off" || s === "no") return false
  return null
}

function coerceInt(value) {
  if (value === undefined || value === null) return null
  var s = String(value).trim()
  if (s === "" || s === "--") return null
  var n = parseInt(s, 10)
  return isFinite(n) ? n : null
}

// ------------------------------------------------------------ accessories

// Categories whose `power` characteristic is a thing a person expects to flip
// from a panel. Everything else with state (sensors, and any category HomeKit
// grows later) renders read-only rather than offering a write that may not be
// meaningful.
var CONTROLLABLE_CATEGORIES = {
  "lightbulb": true,
  "outlet": true,
  "switch": true,
  "fan": true
}

var READING_LABELS = {
  "current_temperature": "Temp",
  "current_humidity": "Humidity",
  "current_relative_humidity": "Humidity",
  "air_quality": "Air",
  "battery_level": "Battery",
  "contact_state": "Contact",
  "motion_detected": "Motion",
  "current_position": "Position"
}

function readingLabel(key) {
  if (READING_LABELS[key]) return READING_LABELS[key]
  return String(key).split("_").join(" ")
}

function readingsOf(state) {
  var out = []
  for (var key in state) {
    if (key === "power" || key === "brightness" || key === "color_temperature") continue
    var value = String(state[key])
    if (value === "" || value === "--") continue
    if (key === "current_humidity" || key === "current_relative_humidity") value = value + "%"
    out.push(readingLabel(key) + " " + value)
  }
  return out
}

function makeDevice(item, override) {
  var state = item.state || {}
  var category = String(item.category || "other")
  var hasPower = state.hasOwnProperty("power")
  var hasBrightness = state.hasOwnProperty("brightness")
  var power = coerceBool(state.power)
  var brightness = coerceInt(state.brightness)

  // Optimistic overlay from an in-flight (or just-completed) write. HomeKit
  // takes a beat to report a new value back through the bridge, so the panel
  // shows the value we asked for until the override expires or a write fails.
  if (override) {
    if (override.power !== undefined && override.power !== null) power = override.power
    if (override.brightness !== undefined && override.brightness !== null) brightness = override.brightness
  }

  return {
    id: String(item.id || ""),
    name: String(item.name || ""),
    room: String(item.room || "Unassigned"),
    zone: String(item.zone || ""),
    category: category,
    semanticType: String(item.semantic_type || ""),
    manufacturer: String(item.manufacturer || ""),
    reachable: item.reachable !== false,
    controllable: hasPower && CONTROLLABLE_CATEGORIES[category] === true,
    hasPower: hasPower,
    power: power,
    hasBrightness: hasBrightness,
    brightness: brightness,
    // A controllable accessory whose power is "--" is reachable enough to
    // write to but has never reported back; say so instead of drawing "off".
    unknown: hasPower && power === null,
    readings: readingsOf(state)
  }
}

// Groups the flat `list --json` array into [{room, devices[]}], dropping
// bridges (they are their own entries and control nothing) and any room the
// user hid. Rooms and devices are sorted by name so the panel does not
// reshuffle between refreshes; controllable accessories sort above read-only
// ones inside a room so the things you came to click are at the top.
function buildRooms(items, hiddenRooms, overrides) {
  var hidden = {}
  if (hiddenRooms) {
    for (var h = 0; h < hiddenRooms.length; h++) hidden[String(hiddenRooms[h])] = true
  }

  var byRoom = {}
  var list = items || []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!item || item.is_bridge === true) continue
    var room = String(item.room || "Unassigned")
    if (hidden[room]) continue
    var device = makeDevice(item, overrides ? overrides[String(item.name || "")] : null)
    if (!byRoom[room]) byRoom[room] = []
    byRoom[room].push(device)
  }

  var rooms = []
  for (var name in byRoom) {
    var devices = byRoom[name]
    devices.sort(function(a, b) {
      if (a.controllable !== b.controllable) return a.controllable ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    rooms.push({ room: name, devices: devices })
  }
  rooms.sort(function(a, b) { return a.room.localeCompare(b.room) })
  return rooms
}

function countDevices(rooms) {
  var n = 0
  for (var i = 0; i < rooms.length; i++) n += rooms[i].devices.length
  return n
}

function countPoweredOn(rooms) {
  var n = 0
  for (var i = 0; i < rooms.length; i++) {
    var devices = rooms[i].devices
    for (var d = 0; d < devices.length; d++) if (devices[d].power === true) n++
  }
  return n
}

// ---------------------------------------------------------------- scenes

function buildScenes(items) {
  var list = items || []
  var out = []
  var homeName = ""
  for (var i = 0; i < list.length; i++) {
    var scene = list[i]
    if (!scene) continue
    if (homeName === "" && scene.home_name) homeName = String(scene.home_name)
    out.push({
      id: String(scene.id || ""),
      name: String(scene.name || ""),
      type: String(scene.type || "user_defined"),
      actionCount: Number(scene.action_count || 0),
      rooms: scene.rooms || []
    })
  }
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return { scenes: out, homeName: homeName }
}

function sceneSubtitle(scene) {
  if (scene.actionCount === 0) return "No actions"
  var rooms = scene.rooms && scene.rooms.length > 0 ? scene.rooms.join(", ") : "Whole home"
  return scene.actionCount + " action" + (scene.actionCount === 1 ? "" : "s") + " · " + rooms
}

// ------------------------------------------------------ render projections
//
// The panel renders ListModels, not these JS arrays: reassigning an array to a
// Repeater destroys and recreates every delegate, which flickers and collapses
// the content column so the Flickable clamps the scroll position away. Writes
// here are optimistic and each one is followed by a settling read, so genuine
// changes arrive constantly — the rows have to be updated in place.
//
// ListModel fixes its roles from the first row appended and stores only flat
// scalars, so every projected row carries the identical key set with identical
// primitive types whether it is a room header or a device, and anything
// without a scalar form gets one here: readings pre-join to a string, an
// unknown brightness becomes -1 (the delegate reads < 0 as "no value").

function renderRow(kind, name, device) {
  return {
    key: kind + " " + String(name),
    kind: kind,
    name: String(name),
    category: device ? String(device.category) : "",
    readingsText: device && device.readings.length > 0 ? device.readings.join(" · ") : "",
    controllable: device ? device.controllable === true : false,
    reachable: device ? device.reachable === true : true,
    unknown: device ? device.unknown === true : false,
    hasBrightness: device ? device.hasBrightness === true : false,
    power: device ? device.power === true : false,
    brightness: device && device.brightness !== null && device.brightness !== undefined
      ? Number(device.brightness) : -1
  }
}

// [{room, devices[]}] flattened to one row list in display order: a header row
// per room followed by its devices. One flat model keeps the sync trivial and
// means a device moving between rooms is an ordinary insert/remove.
function projectRooms(rooms) {
  var out = []
  var list = rooms || []
  for (var r = 0; r < list.length; r++) {
    var room = list[r]
    out.push(renderRow("roomHeader", room.room, null))
    var devices = room.devices || []
    for (var d = 0; d < devices.length; d++) out.push(renderRow("device", devices[d].name, devices[d]))
  }
  return out
}

function projectScenes(scenes) {
  var out = []
  var list = scenes || []
  for (var i = 0; i < list.length; i++) {
    var scene = list[i]
    out.push({
      key: String(scene.name),
      name: String(scene.name),
      subtitle: sceneSubtitle(scene),
      // HomeKit's stock empty scenes stay on screen for context but cannot be
      // run, so the delegate needs this as a flat flag.
      runnable: Number(scene.actionCount || 0) > 0
    })
  }
  return out
}

// Whether syncModel would insert or remove anything, asked before it runs so
// the panel can save its scroll position ahead of the one kind of change that
// disturbs it. Membership changes only when HomeKit gains or loses an
// accessory, so in the steady state this walk finds every key in place and the
// sync that follows is property updates only.
function structureDiffers(model, rows) {
  if (model.count !== rows.length) return true
  for (var i = 0; i < rows.length; i++) if (model.get(i).key !== rows[i].key) return true
  return false
}

// Walks the projected rows against the model in order, updating roles in place
// where the keys line up and patching membership where they diverge. Per-role
// setProperty rather than set(): set() rewrites every role, waking bindings on
// values that did not change (and does not reliably coerce a bool back).
function syncModel(model, rows) {
  var updated = 0
  var inserted = 0
  var removed = 0
  var i = 0

  while (i < rows.length) {
    var row = rows[i]
    if (i >= model.count) {
      model.append(row)
      inserted += 1
      i += 1
      continue
    }

    var existing = model.get(i)
    if (existing.key === row.key) {
      for (var role in row) {
        if (existing[role] !== row[role]) {
          model.setProperty(i, role, row[role])
          updated += 1
        }
      }
      i += 1
      continue
    }

    // Keys diverge. If this row's key turns up further down the model then
    // everything before it is gone; otherwise this row is new here.
    var found = -1
    for (var j = i + 1; j < model.count; j++) {
      if (model.get(j).key === row.key) { found = j; break }
    }
    if (found >= 0) {
      model.remove(i, found - i)
      removed += found - i
    } else {
      model.insert(i, row)
      inserted += 1
      i += 1
    }
  }

  if (model.count > rows.length) {
    removed += model.count - rows.length
    model.remove(rows.length, model.count - rows.length)
  }

  return { updated: updated, inserted: inserted, removed: removed }
}

// ------------------------------------------------------------- failures

function firstLine(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line !== "") return line
  }
  return ""
}

// Three failures look identical from the shell (non-zero exit, some stderr)
// but need three different remedies, so they are told apart here rather than
// smeared into one "something went wrong".
//
//   ssh transport  — exit 255, ssh's own diagnostics on stderr.
//   missing CLI    — exit 127, or the shell's "No such file" complaint.
//   HomeClaw down  — the CLI itself cannot reach the app's local socket.
//   CLI refusal    — exit 64: bad accessory name, bad value, usage error.
function classifyFailure(exitCode, stderr, host, cliPath) {
  var text = String(stderr || "")
  var lower = text.toLowerCase()
  var detail = firstLine(text)

  if (exitCode === 255 || lower.indexOf("ssh:") === 0 || lower.indexOf("ssh_exchange") >= 0) {
    if (lower.indexOf("could not resolve hostname") >= 0)
      return { kind: "ssh", message: "Cannot resolve " + host, remedy: "Check the host setting or your DNS/mDNS." }
    if (lower.indexOf("permission denied") >= 0 || lower.indexOf("publickey") >= 0)
      return { kind: "ssh", message: "SSH key rejected by " + host, remedy: "Is ssh-agent running with a key " + host + " trusts?" }
    if (lower.indexOf("timed out") >= 0 || lower.indexOf("no route to host") >= 0 || lower.indexOf("connection refused") >= 0)
      return { kind: "ssh", message: host + " is not answering", remedy: "Wake the Mac and confirm Remote Login is on." }
    return { kind: "ssh", message: "SSH to " + host + " failed", remedy: detail }
  }

  if (exitCode === 127 || lower.indexOf("no such file") >= 0 || lower.indexOf("command not found") >= 0)
    return { kind: "cli-missing", message: "homeclaw-cli not found on " + host, remedy: "Expected it at " + cliPath + "." }

  if (lower.indexOf("socket") >= 0 || lower.indexOf("not running") >= 0
      || lower.indexOf("could not connect") >= 0 || lower.indexOf("couldn't connect") >= 0
      || lower.indexOf("connection failed") >= 0 || lower.indexOf("xpc") >= 0
      || lower.indexOf("no homes") >= 0 || lower.indexOf("not ready") >= 0)
    return { kind: "app", message: "HomeClaw is not responding on " + host, remedy: "Launch HomeClaw.app on " + host + " and let it finish loading the home." }

  return {
    kind: "cli",
    message: detail !== "" ? detail.replace(/^Error:\s*/i, "") : "homeclaw-cli exited " + exitCode,
    remedy: ""
  }
}
