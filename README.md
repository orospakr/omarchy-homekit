# andrew.homekit

An Omarchy (QuickShell) bar widget that controls Apple HomeKit accessories and
scenes by invoking [HomeClaw](https://github.com/omarshahine/HomeClaw)'s CLI on
a Mac over SSH.

HomeKit has no public Linux API. HomeClaw is a Mac app that holds the HomeKit
permission and ships `homeclaw-cli`; this widget is a thin, well-behaved client
for it. Nothing is installed on the Mac by this plugin — HomeClaw.app just has
to be running there, and SSH from this machine has to work key-based.

## What it does

- **Bar pill** — left-click toggles the panel, middle-click forces a refresh.
  The icon takes the theme's urgent color when the last CLI call failed, and
  its tooltip carries the reason.
- **Panel** — the home name and connection status, every scene as a one-click
  row, then every accessory grouped by room: an optimistic on/off toggle per
  controllable accessory and a 0–100 dimmer under every light that reports
  brightness. Sensors render read-only. Unreachable accessories are dimmed and
  inert, as are HomeKit's stock Arrive/Leave/Wake scenes while they still have
  no actions in them (the CLI refuses to trigger those).
- **Keyboard** — `↑`/`↓` move the cursor, `⏎` toggles, `←`/`→` nudge brightness
  by 10, `R` refreshes, `Esc` closes, `Tab` switches panels.

## IPC

Beyond the usual `open`/`close`/`toggle`/`refresh`, the panel exposes write
routes so a Hyprland bind can act without opening anything. Names are exactly
what `list`/`scenes` report, spaces and all.

```
omarchy-shell andrew.homekit scene "Good Night"
omarchy-shell andrew.homekit power "Desk Lamp" false
omarchy-shell andrew.homekit brightness "Desk Lamp" 40
```

## Settings

Set with `omarchy bar set andrew.homekit <key> <value>`.

| Key | Default | Meaning |
| --- | --- | --- |
| `host` | `snively` | SSH host running HomeClaw |
| `cliPath` | `/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli` | Absolute path to the CLI on that host |
| `icon` | `󰋜` | Bar glyph |
| `pollSeconds` | `10` | Refresh interval **while the panel is open** (3–120) |
| `hiddenRooms` | `[]` | Rooms to leave out of the panel |

## Design notes

**Absolute CLI path.** A non-interactive `sshd` session on macOS gets a PATH
without `/opt/homebrew/bin`, so `homeclaw-cli` is never on it. The full path is
a setting rather than a lookup.

**Remote quoting.** `ssh` does not forward a remote argv vector: it joins the
arguments after the hostname with spaces and hands the string to the login
shell on the far side. Every accessory name here has a space in it, so
`Model.quote()` pre-quotes each remote word for *that* shell (with proper
`'\''` escaping, which is also what makes `Lea's Standing Lamp` safe). Nothing
is ever passed through a shell on this side — `Process.command` is always an
argv array.

**Connection multiplexing.** A cold handshake to the Mac costs about a second,
and a refresh is two calls with a third following every write. `ControlMaster`
with a 5-minute `ControlPersist` collapses them onto one connection, so only
the first call after a lull pays for a handshake.

**Open-only polling.** Reads run when the panel opens and on a timer while it
stays open. An SSH round trip per tick behind a closed panel would be absurd,
and the bar icon needs no live accessory state. The last parsed model is kept,
so reopening renders instantly while a fresh read lands underneath.

**Optimistic writes.** HomeClaw confirms a `set` before HomeKit has propagated
it through the bridge, so the requested value is overlaid on the model at click
time, held through the round trip plus a short settling window, and dropped on
failure so the row snaps back to the truth next to the error.

**Failure triage.** Three failures look identical from the shell (non-zero
exit, some stderr) but need three different remedies, so `Model.classifyFailure`
tells them apart: SSH transport trouble (exit 255 — unknown host, rejected key,
Mac asleep), a missing CLI (exit 127), and HomeClaw itself not answering its
local socket. The panel prints the remedy, not just the symptom.

## Requirements

- HomeClaw.app running on the target Mac with HomeKit access granted.
- Key-based SSH from this machine to that Mac. QuickShell inherits
  `SSH_AUTH_SOCK` from the systemd user environment, so the agent must be the
  systemd-managed one; `BatchMode=yes` means an agent-less session fails fast
  and visibly rather than hanging on a password prompt.
