#!/usr/bin/env bash
# Hardware-free tests: fake sysfs tree + mock hid-feature / framework_tool.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/../framehaptix
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0

mkdir -p "$T/bin" "$T/dev"
cat >"$T/bin/hid-feature" <<'MOCK'
#!/usr/bin/env bash
echo "hid-feature $*" >>"$MOCK_LOG"
case $1 in
list-devices) echo "Available devices:"; echo "/dev/hidraw0: Some Keyboard"; echo "/dev/hidraw3: PIXA3854:00 093A:0274"; exit 0 ;;
set)
	[[ -n ${MOCK_PERM:-} ]] && { echo "Error: Invalid value for '<Path to the hidraw device node>': '$2': Permission denied"; exit 2; }
	[[ -n ${MOCK_FAIL:-} ]] && { echo "Failed to get feature report ID 8: [Errno 32] Broken pipe"; exit 1; }
	case $2 in *hidraw3) echo "Invalid feature index: 524288" >&2; exit 1 ;; esac
	exit 0 ;;
esac
exit 1
MOCK
cat >"$T/bin/framework_tool" <<'MOCK'
#!/usr/bin/env bash
echo "framework_tool $*" >>"$MOCK_LOG"
MOCK
chmod +x "$T/bin/"*

mksys() { # name for each hidraw index: idx:name ...
	rm -rf "$T/sys"; mkdir -p "$T/sys/class/hidraw"
	local e
	for e in "$@"; do
		mkdir -p "$T/sys/class/hidraw/hidraw${e%%:*}/device"
		printf 'DRIVER=hid-multitouch\nHID_NAME=%s\n' "${e#*:}" >"$T/sys/class/hidraw/hidraw${e%%:*}/device/uevent"
	done
}

run() { # runs app with mocks; captures OUT and RC
	: >"$T/log"
	OUT=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" \
		FRAMEHAPTIX_SYSFS="$T/sys" FRAMEHAPTIX_DEVDIR=/dev MOCK_LOG="$T/log" FRAMEHAPTIX_NO_ELEVATE=1 \
		${EXTRA:+"$EXTRA"} bash "$APP" "$@" 2>&1); RC=$?
	LOG=$(cat "$T/log")
}
check() { # description condition...
	local d=$1; shift
	if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; echo "  rc=$RC out=$OUT"; echo "  log=$LOG"; fi
}
has() { [[ $1 == *"$2"* ]]; }

# 1. no device -> exit 0, friendly message, no writes
mksys "0:Some Keyboard"
run apply
check "no device exits 0" test "$RC" -eq 0
check "no device message" has "$OUT" "No PIXA3854"
check "no device no writes" test -z "$LOG"

# 2. two PIXA nodes, first lacks the reports -> picks the second
mksys "0:Some Keyboard" "3:PIXA3854:00 093A:0274" "4:PIXA3854:00 093A:0274"
run sensitivity high
check "sensitivity rc" test "$RC" -eq 0
check "skips wrong node" has "$LOG" "set /dev/hidraw4 -f 80000 3"
check "writes haptic too" has "$LOG" "set /dev/hidraw4 -f 90000 50"
check "persisted" grep -qx 'sensitivity=high' "$T/cfg/framehaptix/config"
check "reports node" has "$OUT" "/dev/hidraw4"

# 3. haptic presets, clamping, validation
run haptic off;   check "haptic off -> 0" has "$LOG" "-f 90000 0"
run haptic 250;   check "haptic clamp high" grep -qx 'haptic=100' "$T/cfg/framehaptix/config"
run haptic -5;    check "haptic clamp low" grep -qx 'haptic=0' "$T/cfg/framehaptix/config"
run haptic 007;   check "haptic leading zeros" grep -qx 'haptic=7' "$T/cfg/framehaptix/config"
run haptic loud;  check "haptic bad arg rc 2" test "$RC" -eq 2
check "bad arg shows usage" has "$OUT" "Usage:"
run sensitivity extreme; check "bad sensitivity rc 2" test "$RC" -eq 2
run frobnicate;   check "unknown cmd rc 2" test "$RC" -eq 2
run sensitivity;  check "missing arg rc 2" test "$RC" -eq 2

# 4. apply is idempotent and uses saved prefs
run apply; first=$LOG; run apply
check "apply idempotent" test "$first" == "$LOG"
check "apply uses saved sensitivity" has "$LOG" "-f 80000 3"

# 5. permission denied, no elevation -> clear error, rc 1
EXTRA="MOCK_PERM=1" run apply
check "perm rc 1" test "$RC" -eq 1
check "perm mentions udev" has "$OUT" "udev rule"

# 6. other failures surface the tool's message
EXTRA="MOCK_FAIL=1" run apply
check "fail rc 1" test "$RC" -eq 1
check "fail shows error" has "$OUT" "Failed to get feature report"

# 7. missing hid-feature -> install hint (device present)
mv "$T/bin/hid-feature" "$T/hf.off"; mv "$T/bin/framework_tool" "$T/ft.off"
run apply
check "missing tool rc 1" test "$RC" -eq 1
check "install hint" has "$OUT" "pacman -S hid-tools"
mv "$T/hf.off" "$T/bin/hid-feature"; mv "$T/ft.off" "$T/bin/framework_tool"

# 8. framework_tool backend, haptic rounded to firmware steps
run haptic 60
EXTRA="FRAMEHAPTIX_BACKEND=framework_tool" run apply
check "ft click force" has "$LOG" "framework_tool --click-force high"
check "ft haptic rounded" has "$LOG" "framework_tool --haptic-intensity 50"

# 9. corrupt config is tolerated
# shellcheck disable=SC2016 # literal $(...) on purpose: config must never be executed
printf 'sensitivity=ludicrous\nhaptic=abc\n$(touch %s/pwned)\n' "$T" >"$T/cfg/framehaptix/config"
run apply
check "bad config falls back" has "$LOG" "-f 80000 2"
check "config not executed" test ! -e "$T/pwned"

# 10. status works without a device and with one
run status; check "status rc" test "$RC" -eq 0
check "status shows device" has "$OUT" "/dev/hidraw3"
mksys; run status; check "status no device" has "$OUT" "no PIXA3854"

# 11. list-devices fallback when sysfs has no hidraw class
rm -rf "$T/sys"; mkdir -p "$T/sys"
run apply
check "list-devices fallback" has "$LOG" "set /dev/hidraw3 -f 80000"

# 12. privileged helper rejects bad input / non-root
run __write hid-feature /usr/bin/hid-feature 9 50
check "__write refuses non-root" test "$RC" -ne 0

# 13. watch: applies at start and again on PrepareForSleep(false)
mksys "4:PIXA3854:00 093A:0274"
cat >"$T/bin/gdbus" <<'MOCK'
#!/usr/bin/env bash
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"
MOCK
chmod +x "$T/bin/gdbus"
run watch
check "watch applies twice" test "$(grep -c -- '-f 80000' <<<"$LOG")" -eq 2
check "watch exits nonzero when bus closes" test "$RC" -eq 1

echo "passed: $pass  failed: $fail"
((fail == 0))
