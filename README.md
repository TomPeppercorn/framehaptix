# framehaptix

A small, desktop-agnostic Linux tool for the **Framework Laptop 13 haptic
touchpad** (the PixArt `PIXA3854` piezo touchpad on the Laptop 13 Pro). It
sets the two knobs the firmware exposes, saves them, and re-applies them on
login and after resume:

- **Click sensitivity**: how hard you have to press for a click (low / medium / high)
- **Haptic intensity**: how strong the click feedback is (0–100, 0 = off)

It was written for Wayland compositors that have no vendor settings GUI
(Hyprland, sway, river, niri…), but works anywhere: a terminal, a
dmenu-style launcher (fuzzel, wofi, tofi, bemenu, rofi, dmenu), or a systemd
user service. It is one bash script. It uses no network and sends no telemetry.

## Reality check: read this first

Don't expect much from this tool.

- Several people on the Framework community forum report that **changing these
  settings makes little or no noticeable difference**. That includes the
  sensitivity levels, which some users can't tell apart at all.
- **Haptic intensity acts roughly like on/off.** Users report that 0 turns
  feedback off and any value ≥ ~50 turns it back on, and that 1–100 then all
  feel the same. Framework's own `framework_tool` source says the firmware
  implements only five steps (0, 25, 50, 75, 100) even though the HID
  descriptor advertises 0–100.
- Behaviour may depend on mainboard revision and touchpad firmware. Firmware
  updates may change it, for better or worse.

The useful part is that the settings can reset on a power cycle. This tool
makes whatever you pick stick. If you want feedback off (`haptic off`), that
much does reliably work.

## How it works

Framework's KB article ["How to adjust Haptic Touchpad Settings"][kb] documents
the Linux method, which uses `hid-feature` from [hid-tools][hidtools]:

```
hid-feature list-devices                    # find the PIXA3854 line -> /dev/hidrawN
hid-feature set /dev/hidrawN -f 80000 2     # sensitivity: 1 low, 2 medium, 3 high
hid-feature set /dev/hidrawN -f 90000 70    # haptic intensity: 0 (off) .. 100
```

`80000` and `90000` are hid-tools *feature indices* in hex, `(report_id << 16) | field`.
So they mean HID feature report `0x08` (button press threshold) and
report `0x09` (haptic intensity), field 0 each.

framehaptix does exactly this and adds the following:

- **Dynamic device discovery.** It never assumes `hidraw2`. It reads
  `HID_NAME` from `/sys/class/hidraw/*/device/uevent`, which needs no
  privileges, and falls back to parsing `hid-feature list-devices`. If several
  hidraw nodes match, it uses the first one that accepts the feature reports.
- **Persistence.** Settings are saved in `$XDG_CONFIG_HOME/framehaptix/config`
  and re-applied by `framehaptix apply` / `framehaptix watch`.
- **Permissions.** A udev rule grants the logged-in seat user access, so no
  sudo is needed. Without the rule, interactive commands fall back to `pkexec`.
- **Graceful failure.** If no PIXA3854 touchpad is present, it says so and
  exits 0, since this just isn't the right machine. If `hid-feature` is
  missing, it prints an install hint.

## Requirements

- `bash` 4+, coreutils, `sed`
- **`hid-feature`** from hid-tools (primary backend):
  - Arch: `sudo pacman -S hid-tools` (official `extra` repo)
  - Anywhere: `pipx install hid-tools` (or `pip install --user hid-tools`)
- Optional: `gdbus` (glib2) for re-applying after resume. It is usually installed already.
- Optional: `pkexec` (polkit), for writing without the udev rule.
- Optional: a dmenu-style launcher for the menu, and `notify-send` for feedback.
- Optional: `framework_tool` from [framework-system][fws] (an alternative backend, see below).

## Install

```bash
git clone https://github.com/tompeppercorn/framehaptix
cd framehaptix
```

Per-user (`~/.local/bin` and `~/.config/systemd/user`):

```bash
make install-user
```

Or system-wide (`/usr/local/bin`, `/usr/local/lib/systemd/user`):

```bash
sudo make install
```

### udev rule (recommended)

The hidraw node is root-only by default. This rule adds `TAG+="uaccess"` so
the user at the seat gets an ACL on the touchpad's hidraw node, and only that node:

```bash
sudo make install-udev
```

That is the same as running:

```bash
sudo install -Dm644 udev/70-framehaptix.rules /etc/udev/rules.d/70-framehaptix.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=hidraw
```

The rule:

```
SUBSYSTEM=="hidraw", ATTRS{name}=="*PIXA3854*", TAG+="uaccess"
```

`ATTRS{name}` matches the touchpad's I2C client device (e.g. `PIXA3854:00`),
which is a parent of the hidraw node. **This rule has not been verified on real
hardware yet.** Please check it on yours and report back:

```bash
framehaptix status                                   # shows the node, e.g. /dev/hidraw2
udevadm info -a -n /dev/hidraw2 | grep -i 'ATTRS{name}'
getfacl /dev/hidraw2                                 # should list user:<you>:rw-
```

If `status` says `needs root` after the rule is installed, log out and back in
or re-run the `udevadm trigger` line.

Security note: with the rule in place, any process running as you can send
arbitrary HID feature reports to the touchpad, not just these two. Normal
users get the same kind of access to many input devices, but you should know about it.

### Re-apply on login and resume

The systemd user service runs `framehaptix watch --no-elevate`. That applies
your settings once at login. It then listens on the system bus for logind's
`PrepareForSleep(false)` signal and applies them again after every resume:

```bash
systemctl --user daemon-reload
systemctl --user enable --now framehaptix.service
journalctl --user -u framehaptix   # to see what it did
```

Without systemd, or if you prefer your compositor's autostart, use one of these:

```
# Hyprland (hyprland.conf)
exec-once = framehaptix watch --no-elevate

# sway / i3 (config)
exec framehaptix watch --no-elevate

# niri (config.kdl)
spawn-at-startup "framehaptix" "watch" "--no-elevate"
```

If you only want a one-shot at login, use `framehaptix apply --wait 10` instead
of `watch`. It waits up to 10 s for the device to appear.

## Usage

```
framehaptix                         interactive menu (launcher or terminal)
framehaptix menu [--tty]            same; --tty forces the terminal menu
framehaptix sensitivity low|medium|high
framehaptix haptic off|low|medium|high|0-100
framehaptix apply [--wait SECONDS]  re-apply saved preferences
framehaptix watch                   apply now, then after every resume
framehaptix status                  device, access, backend, saved prefs
framehaptix help | version
  --no-elevate                      (any position) never fall back to pkexec
```

Haptic presets: `off`=0, `low`=25, `medium`=50, `high`=100. Numbers are
clamped to 0–100. Invalid arguments print the usage and exit 2.

Examples:

```bash
framehaptix sensitivity low   # needs a firmer press (if your firmware honours it)
framehaptix haptic off        # no click feedback
framehaptix status
```

`status` shows your **saved** preferences, not values read back from the
touchpad. framework-system notes that this firmware doesn't reliably answer
GET_FEATURE for these reports.

### Menu

Running `framehaptix` with no arguments opens a menu with the current
sensitivity and haptic intensity, plus *Re-apply* and *Status*. In a graphical
session it uses the first launcher it finds: on Wayland that's fuzzel, wofi,
tofi, bemenu, rofi or wmenu; on X11 it's rofi or dmenu. It performs one action
and exits. Otherwise it falls back to a numbered menu in the terminal.

To choose the launcher yourself, set `FRAMEHAPTIX_MENU`. The value is used
verbatim, with no prompt flag added:

```bash
FRAMEHAPTIX_MENU="fuzzel --dmenu -p 'touchpad: '" framehaptix
```

Example keybinding (Hyprland): `bind = SUPER, F9, exec, framehaptix`

### Config file

`$XDG_CONFIG_HOME/framehaptix/config` (default `~/.config/framehaptix/config`)
is plain `key=value`. It is parsed, never sourced:

```
sensitivity=medium      # low | medium | high
haptic=50               # 0-100, 0 = off
backend=auto            # auto | hid-feature | framework_tool
```

## Alternative backend: `framework_tool`

Framework's [framework-system][fws] (`framework_tool`, packaged in the AUR as
`framework-system`) has equivalent switches for the Laptop 13 Pro:

```
framework_tool --click-force low|medium|high
framework_tool --haptic-intensity 0|25|50|75|100
```

It does **not** go through the EC. It finds the touchpad's HID
precision-touchpad interface with hidapi and sends the same feature reports
(`0x08` and `0x09`), so the udev rule covers it too. Set `backend=framework_tool`
in the config (or `FRAMEHAPTIX_BACKEND=framework_tool`) to use it. In `auto`
mode it is used only when `hid-feature` isn't installed. Haptic values are
rounded to the nearest step framework_tool accepts.

It's worth trying if `hid-feature set` fails with `Failed to get feature
report ID 8`. hid-tools reads the report before writing it, and the firmware
may not answer that read.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No PIXA3854 haptic touchpad found` | This machine doesn't have the haptic touchpad. `ls /sys/class/hidraw/*/device/uevent \| xargs grep HID_NAME` to see what's there. |
| `permission denied` / pkexec prompt every time | Install the udev rule, then re-login or re-trigger udev. |
| `hid-feature … not found` | Install hid-tools (see Requirements). `~/.local/bin` (pipx / `pip --user`) is searched automatically, even from the systemd service. |
| Settings lost after suspend | Enable `framehaptix.service` (or `watch` in autostart). Needs `gdbus`. |
| Nothing feels different | That's expected for many users, see the reality check above. |

## Tested on

Behaviour differs between board revisions and firmware, so reports are very
welcome. Please open a PR adding a row, including "no noticeable effect".

| Laptop / mainboard | BIOS | Kernel | Distro / DE | hidraw `HID_NAME` | Sensitivity effect | Haptic effect | Reporter |
|---|---|---|---|---|---|---|---|
| *no hardware reports yet* | | | | | | | |

framehaptix was developed against Framework's documentation and the
hid-tools / framework-system sources. So far it has only been run against the
mock test suite (`make check`), not on real hardware. Please be the first row.

## Development

```bash
make check     # bash -n, shellcheck (if installed), hardware-free mock tests
```

`tests/run.sh` fakes sysfs, `hid-feature`, `framework_tool` and `gdbus`. It
covers: multiple hidraw nodes, permission errors, the missing-tool hint,
clamping, malformed config, and the resume watcher.

## Sources

- Framework KB: [How to adjust Haptic Touchpad Settings][kb]
- Framework forum: [FW 13 Pro trackpad clicking sensitivity][forum]
- [hid-tools][hidtools] ([Arch `extra` package][archpkg])
- [framework-system][fws]: `framework_lib/src/touchpad.rs`, `EXAMPLES.md`

## License

MIT, see [LICENSE](LICENSE).

[kb]: https://knowledgebase.frame.work/how-to-adjust-haptic-touchpad-settings-BJjHJdU6bl
[forum]: https://community.frame.work/t/fw-13-pro-trackpad-clicking-sensitivity/84475
[hidtools]: https://gitlab.freedesktop.org/libevdev/hid-tools
[archpkg]: https://archlinux.org/packages/extra/any/hid-tools/
[fws]: https://github.com/FrameworkComputer/framework-system
