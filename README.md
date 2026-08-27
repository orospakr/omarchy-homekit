# andrew.homekit

An Omarchy (QuickShell) bar widget that controls Apple HomeKit accessories and
scenes by invoking [HomeClaw](https://github.com/omarshahine/HomeClaw)'s CLI on
a Mac over SSH.

HomeKit has no public Linux API. HomeClaw is a Mac app that holds the HomeKit
permission and ships `homeclaw-cli`; this widget is a thin, well-behaved client
for it. Nothing is installed on the Mac by this plugin — HomeClaw.app just has
to be running there, and SSH from this machine has to work key-based. In
exchange you get a Linux bar pill that turns the lights off.

## For AI agents

The whole setup is one chain, and every failure is one broken link in it:

```
HomeClaw.app running on a Mac  →  Remote Login on that Mac  →  a name that
resolves from here  →  key-based ssh  →  the `host` setting  →  the widget
```

Checklist:

1. HomeClaw installed from the Mac App Store, opened once, HomeKit access
   granted, launch-at-login on. **The app must be running** — the CLI is only a
   client to it over a local Unix socket.
2. Remote Login on in System Settings → General → Sharing.
3. This machine's public key in `~/.ssh/authorized_keys` on the Mac.
4. The Mac reachable by name (Tailscale MagicDNS, or a `~/.ssh/config` alias).
5. `omarchy bar set andrew.homekit host <name>`.

Then **run `bin/homekit-doctor` and act on the first failing step.** It walks
that chain in order, stops at the first break, and prints the exact command or
setting that fixes *that* link. Do not guess from the panel's error text when
the doctor will name the link.

```bash
~/.config/omarchy/plugins/andrew.homekit/bin/homekit-doctor            # uses the widget's own settings
~/.config/omarchy/plugins/andrew.homekit/bin/homekit-doctor my-mac    # or check a host directly
```

It only ever runs read-only HomeClaw subcommands (`status`, `list`, `scenes`),
so it is safe to run at any time; it changes nothing in the home.

## What it does

- **Bar pill** — left-click toggles the panel, middle-click forces a refresh.
  The icon takes the theme's urgent color when the last CLI call failed, and
  its tooltip carries the reason. An unconfigured widget is not a failing one,
  so before a host is set the pill stays neutral and the panel shows a setup
  card instead of an error.
- **Panel** — the home name and connection status, every scene as a one-click
  row, then every accessory grouped by room: an optimistic on/off toggle per
  controllable accessory and a 0–100 dimmer under every light that reports
  brightness. Sensors render read-only. Unreachable accessories are dimmed and
  inert, as are HomeKit's stock Arrive/Leave/Wake scenes while they still have
  no actions in them (the CLI refuses to trigger those).
- **Keyboard** — `↑`/`↓` move the cursor, `⏎` toggles, `←`/`→` nudge brightness
  by 10, `R` refreshes, `Esc` closes, `Tab` switches panels.

## Setup

### 1. The Mac

This is the half that actually talks to HomeKit, and it has to be a Mac that
stays awake.

- **Install HomeClaw** from the Mac App Store.
- **Open it once.** macOS will ask for HomeKit access; grant it. Without that
  permission the app runs but sees no homes, and every read comes back empty.
- **Enable launch-at-login** from HomeClaw's menu-bar item. `homeclaw-cli` is
  just a client that talks to the running app over a local Unix socket — if the
  app is not running, nothing works, and a Mac that reboots overnight will
  otherwise come back mute.
- **Enable Remote Login** — System Settings → General → Sharing → Remote Login.
  Check that your user is in its allowed-users list.
- **Add this machine's public key** to `~/.ssh/authorized_keys` on the Mac.
  Easiest from here:

  ```bash
  ssh-keygen -t ed25519          # if you have no key yet
  ssh-copy-id your-mac
  ```

  If sshd ignores the file, the permissions are usually why:
  `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`.
- **Stop it sleeping.** System Settings → Energy (desktop) or Battery → Options
  (laptop): prevent automatic sleeping, or at minimum enable wake for network
  access. A sleeping Mac is indistinguishable from an absent one.

### 2. The network

The widget hands `host` straight to `ssh`, so anything `ssh` can reach works.

**Tailscale is the recommendation.** Install it on both machines and the Mac's
MagicDNS name (`mac-mini`, or the full `mac-mini.tail1234.ts.net`) works as
`host` with no further setup — including from outside the house, which no
`.local` name will do.

**An `~/.ssh/config` alias is the tidier pattern** and composes with the above:
put the connection details in ssh's config and let the widget know only a name.

```
Host homekit-mac
  HostName mac-mini.tail1234.ts.net
  User you
  IdentityFile ~/.ssh/id_ed25519
  Port 22
```

```bash
omarchy bar set andrew.homekit host homekit-mac
```

Now the user, port, key, and address can all change without touching the
widget's settings, and `ssh homekit-mac true` is the exact thing to debug when
it stops working. Plain LAN names (`mac-mini.local`, `192.168.1.20`) work too;
they just stop working the moment you leave the house.

Whichever you choose, `ssh <name> true` must succeed from a terminal with no
password prompt before the widget has any chance.

### 3. This machine

**Install the plugin.**

```bash
omarchy plugin add https://github.com/orospakr/omarchy-homekit.git --enable
```

`omarchy plugin add` clones the repo, validates its `manifest.json` against the
schema the shell enforces, moves it to `~/.config/omarchy/plugins/<id>` (here
`andrew.homekit`, taken from the manifest — not from the repo name), and offers
to enable it and pick a bar section. It clones non-interactively, so a private
repo needs a URL your ssh agent can authenticate:
`omarchy plugin add git@github.com:orospakr/omarchy-homekit.git`.

By hand instead:

```bash
git clone https://github.com/orospakr/omarchy-homekit.git \
  ~/.config/omarchy/plugins/andrew.homekit
omarchy plugin enable andrew.homekit --section right
omarchy-restart-shell
```

**Make sure the shell can see your ssh-agent.** The widget runs inside the
long-lived `omarchy-shell` process and inherits its environment; `BatchMode=yes`
means an agent-less session fails fast with "Permission denied" rather than
hanging on a prompt.

```bash
systemctl --user show-environment | grep SSH_AUTH_SOCK
```

If that prints nothing, whatever starts your agent is not exporting it where
the shell can see it. Two shapes both work — the agent this machine uses is
started from Hyprland's autostart at a fixed socket path, with the matching
`env = SSH_AUTH_SOCK,$XDG_RUNTIME_DIR/ssh-agent.socket` (in
`~/.config/hypr/envs.conf`, or `hl.env(...)` in `autostart.lua`) so everything
Hyprland launches inherits it:

```
env = SSH_AUTH_SOCK,$XDG_RUNTIME_DIR/ssh-agent.socket
exec-once = ssh-agent -D -a $XDG_RUNTIME_DIR/ssh-agent.socket
```

If your agent instead comes from a login shell or a systemd user unit, push it
into the user environment before the shell starts:

```bash
systemctl --user import-environment SSH_AUTH_SOCK
```

**Point it at the Mac.**

```bash
omarchy bar set andrew.homekit host homekit-mac
omarchy bar set andrew.homekit cliPath /Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli   # only if HomeClaw lives elsewhere
```

### 4. Verify

```bash
~/.config/omarchy/plugins/andrew.homekit/bin/homekit-doctor
```

A healthy run ends like this:

```
✔ Host is set: mac-mini
✔ ssh-agent has 1 key(s) loaded
✔ SSH to mac-mini works
✔ homeclaw-cli is executable at /Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli
✔ HomeClaw is ready on mac-mini — "My Home"
  14 accessories in 1 home(s), 8 scenes (list returns 14 entries)
```

Anything else stops at the broken link with the fix for it. The doctor uses the
same ssh options the widget does, so a passing run also leaves a warm
multiplexed connection behind for the panel's first open.

## Troubleshooting

The panel prints the remedy, not just the symptom; `Model.classifyFailure`
picks which one. Every kind below maps to a doctor step.

| Panel says | Kind | Cause | Fix |
| --- | --- | --- | --- |
| *Point this at a Mac running HomeClaw* (setup card) | — | `host` is unset; nothing has been attempted | `omarchy bar set andrew.homekit host <your-mac>` (doctor step 1) |
| `Cannot resolve <host>` | `ssh` | The name means nothing here — typo, MagicDNS off, missing `.local`, or no `~/.ssh/config` entry | Fix the name or add the alias; `tailscale status` to confirm the peer (doctor step 3) |
| `<host> is not answering` | `ssh` | Resolves but no reply: Mac asleep, off the network, off-LAN without Tailscale, or Remote Login off (connection refused) | Wake it, check Energy settings, turn on Remote Login (doctor step 3) |
| `SSH key rejected by <host>` | `ssh` | The Mac does not trust the offered key, or the shell has no agent, or the username is wrong | `ssh-copy-id <host>`; check `SSH_AUTH_SOCK` in the shell's environment; set `User` in `~/.ssh/config` (doctor steps 2–3) |
| `SSH to <host> failed: …` | `ssh` | Anything else from ssh — commonly a changed host key after a reinstall | Read the quoted line; `ssh-keygen -R <host>` then `ssh <host> true` once by hand (doctor step 3) |
| `homeclaw-cli not found on <host>` | `cli-missing` | Wrong `cliPath`, or HomeClaw is not installed. A bare name never works: non-interactive sshd on macOS has a PATH without `/opt/homebrew/bin` | The doctor asks Spotlight where the bundle is and prints the `omarchy bar set … cliPath` line to run (doctor step 4) |
| `HomeClaw is not responding on <host>` | `app` | The binary ran but the app is not up, or is up with no home: not launched, still loading, or HomeKit access never granted | Open HomeClaw.app, enable launch-at-login, check System Settings → Privacy & Security → HomeKit (doctor step 5) |
| Any other one-line message | `cli` | `homeclaw-cli` itself refused — exit 64: unknown accessory name, bad value, a scene with no actions | Take it literally; names must match `list`/`scenes` exactly, spaces and all |
| Panel connects but is empty | — | HomeClaw reports zero homes, or every room is in `hiddenRooms` | Check the Mac is signed in to the iCloud account that owns the home; check `hiddenRooms` |

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
| `host` | *(unset)* | SSH host — a hostname, IP, Tailscale MagicDNS name, or `~/.ssh/config` alias. **Required.** While it is empty the panel shows a first-run setup card (the four steps above, plus a pointer at `bin/homekit-doctor`) in place of the accessory list, and the bar pill stays neutral rather than reading as an error |
| `cliPath` | `/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli` | Absolute path to the CLI on that host |
| `icon` | `󰋜` | Bar glyph |
| `pollSeconds` | `10` | Refresh interval **while the panel is open** (3–120) |
| `scrollSpeed` | `4.0` | Trackpad scroll speed factor for the accessory list |
| `hiddenRooms` | `[]` | Rooms to leave out of the panel |

## Design notes

**No host, no guess.** A fresh install ships `host` empty rather than pointing
somewhere plausible, and the service refuses to launch `ssh` at all until one is
set — an empty host would have ssh try to connect to the literal string `""`, and
the widget would report an unreachable Mac the user never named. An unconfigured
widget is not a broken one, so it wears no error color and shows the setup card
instead.

**Absolute CLI path.** A non-interactive `sshd` session on macOS gets a PATH
without `/opt/homebrew/bin`, so `homeclaw-cli` is never on it. The full path is
a setting rather than a lookup.

**Remote quoting.** `ssh` does not forward a remote argv vector: it joins the
arguments after the hostname with spaces and hands the string to the login
shell on the far side. Every accessory name here has a space in it, so
`Model.quote()` pre-quotes each remote word for *that* shell (with proper
`'\''` escaping, which is also what makes `Lea's Standing Lamp` safe). Nothing
is ever passed through a shell on this side — `Process.command` is always an
argv array. `bin/homekit-doctor` repeats the same trick in bash, for the same
reason.

**Connection multiplexing.** A cold handshake to the Mac costs about a second,
and a refresh is two calls with a third following every write. `ControlMaster`
with a 5-minute `ControlPersist` collapses them onto one connection, so only
the first call after a lull pays for a handshake. The doctor deliberately uses
the identical option list (kept in sync by hand, with a comment on both sides)
so that what it proves is exactly what the widget will do — control socket
included.

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
local socket. Each remedy names the next concrete thing to do — the exact
command, the exact file — because the person reading it is usually setting this
up for the first time and has no idea which half of the chain just failed.
