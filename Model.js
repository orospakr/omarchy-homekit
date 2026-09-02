.pragma library

// Pure data layer for the HomeKit bar widget: command construction, JSON
// parsing, state coercion, room grouping, and failure classification. No QML
// types are touched here so every function is trivially testable in isolation.

// ---------------------------------------------------------------- commands

// ssh does NOT forward its remote argv as a vector: it joins the arguments
// after the hostname with single spaces and hands the resulting string to the
// login shell on the far side. Nearly every HomeKit accessory name has a
// space in it ("Desk Lamp", "Kid's Standing Lamp"), so each remote-side
// word must arrive already quoted FOR THAT SHELL or it would arrive as two
// arguments. POSIX single-quote escaping: close, backslash-escaped quote,
// reopen — which is also why an apostrophe in a HomeKit name is safe.
function quote(value) {
  return "'" + String(value).split("'").join("'\\''") + "'"
}

// ssh parses a leading "-" in the destination as an option no matter that it
// arrived as its own argv element, and -oProxyCommand=... runs a command on
// THIS machine. A host is a settings string, so a tampered shell.json must not
// be able to turn opening the panel into local execution: anything option-like
// or carrying whitespace/control characters is refused outright rather than
// escaped, since no real destination looks like that.
function hostIsValid(host) {
  var value = String(host === undefined || host === null ? "" : host)
  if (value === "") return false
  if (value.charAt(0) === "-") return false
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code <= 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) return false
  }
  return true
}

// Multiplexing matters here: a cold SSH handshake to the Mac costs ~1s, and a
// panel refresh is two calls with a third following every write. ControlMaster
// collapses them onto one connection that lingers for five minutes.
//
// Returns null for a host this must not be handed to ssh at all; the caller
// treats that as "cannot start" rather than launching something.
function sshArgs(host, cliPath, args, controlPath) {
  if (!hostIsValid(host)) return null
  var command = [
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" + String(controlPath),
    "-o", "ControlPersist=300",
    // Ends option parsing: belt and braces beside hostIsValid above.
    "--",
    String(host),
    quote(cliPath)
  ]
  for (var i = 0; i < args.length; i++) command.push(quote(args[i]))
  return command
}

// -------------------------------------------------------------- display
//
// QML Text defaults to AutoText, which sniffs its content and renders anything
// that looks like markup as rich text — and rich text can pull an <img> over
// the network. Accessory, room, scene and home names come off someone else's
// HomeKit, and error text embeds the CLI's stderr, so none of it may reach a
// Text as markup. Local Text elements set textFormat: Text.PlainText; the
// upstream qs.Ui controls (Button, Toggle, PanelHero, PanelSectionHeader) do
// not expose that property, so every string handed to one goes through here
// first: angle brackets become their fullwidth lookalikes (visually honest,
// syntactically inert) and C0/C1 control characters are dropped.
//
// This is display-only. Names are no longer what gets sent to the CLI — writes
// address accessories and scenes by UUID.
function displayText(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
      // Tabs and newlines have no meaning in a one-line label either.
      if (code === 0x09 || code === 0x0a || code === 0x0d) out += " "
      continue
    }
    if (code === 0x3c) out += "＜"       // < -> fullwidth
    else if (code === 0x3e) out += "＞"  // > -> fullwidth
    else out += text.charAt(i)
  }
  return out
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
// Both tables below are indexed by strings that come off the remote HomeKit,
// so both are prototype-less: `READING_LABELS["constructor"]` in a plain
// object is a function, and it would be rendered as one.
function protolessMap(source) {
  var out = Object.create(null)
  for (var key in source) out[key] = source[key]
  return out
}

var CONTROLLABLE_CATEGORIES = protolessMap({
  "lightbulb": true,
  "outlet": true,
  "switch": true,
  "fan": true
})

var READING_LABELS = protolessMap({
  "current_temperature": "Temp",
  "current_humidity": "Humidity",
  "current_relative_humidity": "Humidity",
  "air_quality": "Air",
  "battery_level": "Battery",
  "contact_state": "Contact",
  "motion_detected": "Motion",
  "current_position": "Position"
})

function readingLabel(key) {
  if (READING_LABELS[key]) return READING_LABELS[key]
  return String(key).split("_").join(" ")
}

function readingsOf(state) {
  var out = []
  if (!state || typeof state !== "object") return out
  for (var key in state) {
    if (!Object.prototype.hasOwnProperty.call(state, key)) continue
    if (key === "power" || key === "brightness" || key === "color_temperature") continue
    var raw = state[key]
    // A schema change could nest an object or an array here; there is no
    // sensible one-line rendering of that, so it is simply not a reading.
    if (raw === null || raw === undefined || typeof raw === "object") continue
    var value = displayText(raw)
    if (value === "" || value === "--") continue
    if (key === "current_humidity" || key === "current_relative_humidity") value = value + "%"
    out.push(displayText(readingLabel(key)) + " " + value)
  }
  return out
}

// `id` is the accessory's HomeKit UUID and is what everything downstream keys
// on — ListModel rows, the keyboard cursor, overrides, in-flight maps — and
// what `set` is addressed to. Two rooms may each hold a "Lamp"; only the UUID
// tells them apart.
//
// A row that arrives without one gets "" and nothing else: falling back to the
// name would put two id-less "Lamp"s on the same override/in-flight key AND
// address the write to homeclaw-cli by an ambiguous name, which picks the
// first match — the wrong lamp in the wrong room. Such a row is rendered
// read-only (see `actionable` below) under a synthetic key, and is invisible
// to IPC resolution. A non-string id (a bridge reporting a number, an object)
// is no id at all.
function deviceIdOf(item) {
  if (!item || typeof item.id !== "string") return ""
  return item.id.trim()
}

// The identity a row is *displayed* under. Real rows use the UUID; an id-less
// row gets a per-position synthetic key so several of them stay distinct rows
// in the ListModel diff without ever being mistaken for something writable.
function displayKeyOf(id, index, name) {
  return id !== "" ? id : "noid:" + index + ":" + String(name === undefined || name === null ? "" : name)
}

function makeDevice(item, override, index) {
  var state = item.state && typeof item.state === "object" ? item.state : {}
  var category = String(item.category || "other")
  var hasPower = Object.prototype.hasOwnProperty.call(state, "power")
  var hasBrightness = Object.prototype.hasOwnProperty.call(state, "brightness")
  var power = coerceBool(state.power)
  var brightness = coerceInt(state.brightness)

  // Optimistic overlay from an in-flight (or just-completed) write. HomeKit
  // takes a beat to report a new value back through the bridge, so the panel
  // shows the value we asked for until the override expires or a write fails.
  if (override) {
    if (override.power !== undefined && override.power !== null) power = override.power
    if (override.brightness !== undefined && override.brightness !== null) brightness = override.brightness
  }

  var id = deviceIdOf(item)
  var name = String(item.name || "")

  return {
    id: id,
    // What the ListModel row and the keyboard cursor are keyed by. Identical
    // to `id` for everything HomeKit identified properly.
    key: displayKeyOf(id, index, name),
    // Whether this row may be written to at all. No UUID means no safe way to
    // address the accessory, so the panel renders it without a toggle or a
    // dimmer rather than guessing at a name.
    actionable: id !== "",
    name: name,
    room: String(item.room || "Unassigned"),
    zone: String(item.zone || ""),
    category: category,
    semanticType: String(item.semantic_type || ""),
    manufacturer: String(item.manufacturer || ""),
    reachable: item.reachable !== false,
    controllable: id !== "" && hasPower && CONTROLLABLE_CATEGORIES[category] === true,
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
// Rooms are still keyed by name (HomeClaw reports no room UUID in `list`), and
// a room named `constructor` or `__proto__` would be "already present" in a
// plain {} — hiding every accessory in it, or corrupting the grouping. Both
// maps are prototype-less so a name is only ever a name.
function buildRooms(items, hiddenRooms, overrides) {
  var hidden = Object.create(null)
  if (hiddenRooms && hiddenRooms.length !== undefined) {
    for (var h = 0; h < hiddenRooms.length; h++) hidden[String(hiddenRooms[h])] = true
  }

  var byRoom = Object.create(null)
  var list = items && items.length !== undefined ? items : []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    // A row that is not an object at all (a bare string from a schema change)
    // has nothing to render; skip it rather than throwing the whole refresh.
    if (!item || typeof item !== "object" || item.is_bridge === true) continue
    var room = String(item.room || "Unassigned")
    if (hidden[room]) continue
    var override = null
    var id = deviceIdOf(item)
    // Overrides are keyed by UUID, so an id-less row has no override to find
    // and must not be handed the one belonging to key "".
    if (overrides && id !== "" && Object.prototype.hasOwnProperty.call(overrides, id))
      override = overrides[id]
    var device = makeDevice(item, override, i)
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
  var list = items && items.length !== undefined ? items : []
  var out = []
  var homeName = ""
  for (var i = 0; i < list.length; i++) {
    var scene = list[i]
    if (!scene || typeof scene !== "object") continue
    if (homeName === "" && scene.home_name) homeName = String(scene.home_name)
    // Same rule as accessories: a scene is triggered by UUID or not at all.
    // `trigger <name>` resolves to the first match on the Mac, so a scene that
    // arrives without an id is shown for context and cannot be run.
    var id = typeof scene.id === "string" ? scene.id.trim() : ""
    var name = String(scene.name || "")
    var count = Number(scene.action_count)
    // `rooms` is joined for the subtitle further down. Only a real array is
    // iterated: `{"rooms":{"length":1000000000}}` would otherwise spin a
    // billion times on the UI thread, and a smaller one yields "undefined"
    // room labels. A scalar string is the one non-array shape with an obvious
    // meaning; anything else is no rooms at all.
    var rooms = []
    if (Array.isArray(scene.rooms)) {
      for (var r = 0; r < scene.rooms.length; r++) rooms.push(String(scene.rooms[r]))
    } else if (typeof scene.rooms === "string" && scene.rooms !== "") {
      rooms.push(scene.rooms)
    }
    out.push({
      id: id,
      key: displayKeyOf(id, i, name),
      actionable: id !== "",
      name: name,
      type: String(scene.type || "user_defined"),
      actionCount: isFinite(count) ? count : 0,
      rooms: rooms
    })
  }
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return { scenes: out, homeName: homeName }
}

function sceneSubtitle(scene) {
  if (!scene || scene.actionCount === 0) return "No actions"
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

// `uid` rather than `id`: `id` is not a name a QML delegate can declare as a
// required property. `key` is the diff identity syncModel walks, so it has to
// stay one flat string — kind plus uid keeps a room header and a device that
// happen to share a name apart.
function renderRow(kind, uid, name, device) {
  return {
    key: kind + "\u0000" + String(uid),
    uid: String(uid),
    kind: kind,
    name: displayText(name),
    category: device ? displayText(device.category) : "",
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
    // Rooms have no UUID of their own, so a header is identified by its name.
    out.push(renderRow("roomHeader", room.room, room.room, null))
    var devices = room.devices || []
    // Keyed by `key`, not `id`: identical for every properly identified
    // accessory, and a per-position synthetic string for an id-less one so two
    // of them do not collapse onto the same row in the diff.
    for (var d = 0; d < devices.length; d++)
      out.push(renderRow("device", devices[d].key, devices[d].name, devices[d]))
  }
  return out
}

function projectScenes(scenes) {
  var out = []
  var list = scenes || []
  for (var i = 0; i < list.length; i++) {
    var scene = list[i]
    out.push({
      key: String(scene.key),
      uid: String(scene.key),
      name: displayText(scene.name),
      subtitle: displayText(sceneSubtitle(scene)),
      // HomeKit's stock empty scenes stay on screen for context but cannot be
      // run, so the delegate needs this as a flat flag. A scene with no UUID
      // is inert for the same reason: there is nothing safe to trigger.
      runnable: scene.actionable === true && Number(scene.actionCount || 0) > 0
    })
  }
  return out
}

// ------------------------------------------------------------- identity
//
// Everything the panel and the IPC routes act on is addressed by UUID. These
// resolve one back to the parsed row, so a caller can name the thing it just
// did without carrying a second identifier around.

function findDevice(rooms, id) {
  var list = rooms || []
  var wanted = String(id)
  // "" is the id of every row HomeKit failed to identify; it resolves to none
  // of them rather than to whichever one comes first.
  if (wanted === "") return null
  for (var r = 0; r < list.length; r++) {
    var devices = list[r].devices || []
    for (var d = 0; d < devices.length; d++) if (devices[d].id === wanted) return devices[d]
  }
  return null
}

function findScene(scenes, id) {
  var list = scenes || []
  var wanted = String(id)
  if (wanted === "") return null
  for (var i = 0; i < list.length; i++) if (list[i].id === wanted) return list[i]
  return null
}

// Only rows carrying a real UUID are offered to IPC: `power "Lamp" off` must
// resolve to something that can be addressed, and an id-less row cannot be.
// Leaving it out means the caller is told "Unknown accessory" instead of
// having the write silently sent by ambiguous name.
function deviceIdentities(rooms) {
  var out = []
  var list = rooms || []
  for (var r = 0; r < list.length; r++) {
    var devices = list[r].devices || []
    for (var d = 0; d < devices.length; d++) {
      if (devices[d].id === "") continue
      out.push({ id: devices[d].id, name: devices[d].name })
    }
  }
  return out
}

function sceneIdentities(scenes) {
  var out = []
  var list = scenes || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === "") continue
    out.push({ id: list[i].id, name: list[i].name })
  }
  return out
}

// HomeKit UUIDs as HomeClaw reports them. A token shaped like one is accepted
// without a model to check it against — it can only ever mean one accessory,
// and the CLI says so if it means none — where a bare name that is not in the
// current model is refused rather than guessed at.
function looksLikeUuid(token) {
  return /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(String(token))
}

// Resolves a UUID or a display name against [{id, name}].
//
//   { status: "ok", id, name }  exactly one match
//   { status: "ambiguous" }     a name two things answer to — refused, because
//                               picking one silently is how the wrong lamp in
//                               the wrong room gets switched
//   { status: "none" }          nothing here answers to it
function resolveIdentity(entries, token) {
  var wanted = String(token === undefined || token === null ? "" : token).trim()
  if (wanted === "") return { status: "none" }
  var lower = wanted.toLowerCase()
  var list = entries || []

  var tiers = [[], [], []]  // uuid, exact name, case-insensitive name
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (String(entry.id).toLowerCase() === lower) tiers[0].push(entry)
    else if (entry.name === wanted) tiers[1].push(entry)
    else if (String(entry.name).toLowerCase() === lower) tiers[2].push(entry)
  }

  for (var t = 0; t < tiers.length; t++) {
    if (tiers[t].length === 1) return { status: "ok", id: tiers[t][0].id, name: tiers[t][0].name }
    if (tiers[t].length > 1) return { status: "ambiguous" }
  }

  if (looksLikeUuid(wanted)) return { status: "ok", id: wanted, name: wanted }
  return { status: "none" }
}

// ------------------------------------------------------------- ipc values
//
// IPC arguments arrive as strings from whatever ran `omarchy-shell`, so a typo
// has to be refused rather than coerced: `power X tru` used to read as false
// and switch the thing off.
//
// Returns true, false, "toggle", or null for "not a power value at all".
function parsePowerValue(value) {
  var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  if (s === "true" || s === "on" || s === "1") return true
  if (s === "false" || s === "off" || s === "0") return false
  if (s === "toggle") return "toggle"
  return null
}

// A brightness must be a finite number in 0-100. Number("") is 0 and
// Number("1e999") is Infinity, so the string is validated before it is parsed;
// a trailing % is allowed because that is how the panel prints it.
function parseBrightnessValue(value) {
  var s = String(value === undefined || value === null ? "" : value).trim()
  if (s.charAt(s.length - 1) === "%") s = s.substring(0, s.length - 1).trim()
  if (!/^[+]?(\d+(\.\d*)?|\.\d+)$/.test(s)) return null
  var n = Number(s)
  if (!isFinite(n) || n < 0 || n > 100) return null
  return n
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

// Every remedy names the next concrete thing to do — the exact command, the
// exact file — because the person hitting one of these is usually setting the
// widget up for the first time and has no idea which half of the chain
// (network, ssh, CLI, app) just failed.
function sshRemedy(host) {
  return "Check the host name (Tailscale MagicDNS name or ~/.ssh/config alias) "
       + "and that the Mac is awake: run bin/homekit-doctor " + host
}

function authRemedy() {
  return "Key auth failed. Add this machine's public key to ~/.ssh/authorized_keys "
       + "on the Mac, and make sure the shell can see your ssh-agent "
       + "(SSH_AUTH_SOCK in the Hyprland env or systemctl --user import-environment; see README)."
}

function cliRemedy(cliPath) {
  return "homeclaw-cli not found at " + cliPath
       + ". Set cliPath: omarchy bar set ca.orospakr.homekit cliPath <path>"
}

function appRemedy(host) {
  return "HomeClaw.app isn't running on " + host
       + ". Open it (and enable launch-at-login in its menu)."
}

// Three failures look identical from the shell (non-zero exit, some stderr)
// but need three different remedies, so they are told apart here rather than
// smeared into one "something went wrong".
//
//   ssh transport  — exit 255, ssh's own diagnostics on stderr.
//   missing CLI    — exit 127, or the shell's "No such file" complaint.
//   HomeClaw down  — the CLI itself cannot reach the app's local socket.
//   CLI refusal    — exit 64: bad accessory name, bad value, usage error.
// The message ends up in a Text and in the bar tooltip, so the CLI's own
// stderr is neutralized here rather than at each of the four places that
// render it.
function classifyFailure(exitCode, stderr, host, cliPath) {
  var text = String(stderr || "")
  var lower = text.toLowerCase()
  var detail = displayText(firstLine(text))

  if (exitCode === 255 || lower.indexOf("ssh:") === 0 || lower.indexOf("ssh_exchange") >= 0) {
    if (lower.indexOf("could not resolve hostname") >= 0)
      return { kind: "ssh", message: "Cannot resolve " + host, remedy: sshRemedy(host) }
    if (lower.indexOf("permission denied") >= 0 || lower.indexOf("publickey") >= 0)
      return { kind: "ssh", message: "SSH key rejected by " + host, remedy: authRemedy() }
    if (lower.indexOf("timed out") >= 0 || lower.indexOf("no route to host") >= 0 || lower.indexOf("connection refused") >= 0)
      return { kind: "ssh", message: host + " is not answering", remedy: sshRemedy(host) }
    return {
      kind: "ssh",
      message: detail !== "" ? "SSH to " + host + " failed: " + detail : "SSH to " + host + " failed",
      remedy: sshRemedy(host)
    }
  }

  if (exitCode === 127 || lower.indexOf("no such file") >= 0 || lower.indexOf("command not found") >= 0)
    return { kind: "cli-missing", message: "homeclaw-cli not found on " + host, remedy: cliRemedy(cliPath) }

  if (lower.indexOf("socket") >= 0 || lower.indexOf("not running") >= 0
      || lower.indexOf("could not connect") >= 0 || lower.indexOf("couldn't connect") >= 0
      || lower.indexOf("connection failed") >= 0 || lower.indexOf("xpc") >= 0
      || lower.indexOf("no homes") >= 0 || lower.indexOf("not ready") >= 0)
    return { kind: "app", message: "HomeClaw is not responding on " + host, remedy: appRemedy(host) }

  return {
    kind: "cli",
    message: detail !== "" ? detail.replace(/^Error:\s*/i, "") : "homeclaw-cli exited " + exitCode,
    remedy: ""
  }
}
