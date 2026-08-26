#!/bin/bash
#
# One-click launcher: bring up the DeskPad virtual display, then start Kodi on it.
#
# Design notes (each one is a bug we already hit):
#
#   * Kodi's monitor setting is the string "<display name> (<n>)", where <n> is
#     some volatile per-session number - NOT the CGDirectDisplayID, unit number
#     or serial (all three were measured and ruled out). So we never compute it:
#     we ask Kodi for its own option list and match on the display name.
#   * Changing videoscreen.monitor while Kodi is RUNNING wedges it (renderer
#     reinit leaves the main loop stuck). We only ever change it while Kodi is
#     stopped, then launch, so Kodi initialises directly on the right display.
#   * Kodi must not be running when guisettings.xml is edited, or it overwrites.
#   * The virtual display takes a moment to register after DeskPad starts; Kodi
#     enumerates displays once at startup, so we wait for the display first or
#     Kodi lands on the built-in screen.
#
# DeskPad is deliberately left running when Kodi quits. The reverse is linked,
# though: quitting DeskPad quits Kodi and puts Kodi's display settings back, via
# a watcher this script leaves running (see `--watch`). Kodi writes its settings
# out as it exits, so the restore can only happen once Kodi is actually gone -
# which is why the teardown lives here rather than in DeskPad itself.

set -uo pipefail

DESKPAD_APP="${DESKPAD_APP:-/Users/deepak/work/apps/deskpad/DeskPad Dev.app}"
DISPLAY_NAME="${DISPLAY_NAME:-DeskPad Dev Display}"
KODI_APP="${KODI_APP:-/Applications/Kodi.app}"
GUISETTINGS="${GUISETTINGS:-$HOME/Library/Application Support/Kodi/userdata/guisettings.xml}"

# Netskope TLS inspection re-signs HTTPS with a private root, and Kodi ignores the
# macOS keychain entirely - it trusts only its own bundled system/certs/cacert.pem,
# which does not carry that root. Every repository fetch then fails with curl
# error 60. SSL_CERT_FILE overrides that bundle, and it has to go through
# launchctl rather than a plain export: `open -a` hands the launch to launchd, so
# Kodi inherits launchd's environment and not this script's.
CA_BUNDLE="${CA_BUNDLE:-$HOME/.certs/kodi-cacert-netskope.pem}"

# Fullscreen at native 1x 1080p on the virtual display. Set to WINDOW for a
# plain window instead.
SCREENMODE="${SCREENMODE:-1920x1080p(1920x1080)}"

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools"
RPC="$TOOLS/kodi_rpc.py"
PATCHER="$TOOLS/patch_guisettings.py"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Kodi's display settings as they were before this session touched them, so the
# watcher can put them back. A file rather than an argument to the watcher: if a
# watcher ever dies without restoring, the next run finds the real pre-session
# values here instead of mistaking our own patched ones for them.
STATE_FILE="$HOME/Library/Application Support/kodi-on-deskpad/pre-session-settings"
WATCH_LOG="$HOME/Library/Logs/kodi-on-deskpad.log"

DISPLAY_WAIT=25   # seconds for the virtual display to register
RPC_WAIT=60       # seconds for Kodi to answer JSON-RPC after launch
KODI_STOP_WAIT=20 # seconds to allow a graceful Kodi quit
OPTION_WAIT=30    # seconds for Kodi to finish enumerating displays

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() {
    log "ERROR: $*"
    # Surface failures even when run by double-click, where stdout is invisible.
    osascript -e "display alert \"Kodi on DeskPad\" message \"$1\" as critical" \
        >/dev/null 2>&1 || true
    exit 1
}

# --- DeskPad ---------------------------------------------------------------

display_present() {
    system_profiler SPDisplaysDataType 2>/dev/null | grep -qF "$DISPLAY_NAME:"
}

# Whether our virtual display is attached - the condition the teardown actually
# cares about, since it is the display going away that strands Kodi.
#
# display_id.py asks CoreGraphics directly (~50ms), where display_present shells
# out to system_profiler (~1s), and the watcher runs this every couple of seconds
# for as long as a session lasts.
#
# Deliberately not a `pgrep -f` process check. That pattern matches any command
# line which merely *mentions* DeskPad's path - a grep, an editor, another script
# polling for the same thing - so an unrelated process reads as "DeskPad is still
# running" and the teardown never fires. Measured: it held the watcher off for
# 40s while a test loop ran, then fired the moment that loop exited.
virtual_display_attached() {
    "$TOOLS/display_id.py" >/dev/null 2>&1
}

ensure_deskpad() {
    if display_present; then
        log "virtual display '$DISPLAY_NAME' already present"
        return 0
    fi

    [ -d "$DESKPAD_APP" ] || fail "DeskPad not found at: $DESKPAD_APP"

    log "starting DeskPad..."
    open -n "$DESKPAD_APP" || fail "failed to launch DeskPad"

    local waited=0
    while ! display_present; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$DISPLAY_WAIT" ]; then
            fail "virtual display '$DISPLAY_NAME' did not appear within ${DISPLAY_WAIT}s.
Check that DeskPad has Screen Recording permission in
System Settings > Privacy & Security > Screen Recording."
        fi
    done
    log "virtual display registered after ${waited}s"
}

# --- Kodi ------------------------------------------------------------------

# Anchored so it matches Kodi's own command line and not merely a command line
# that mentions it - see virtual_display_attached for what that costs.
kodi_running() {
    pgrep -f "^$KODI_APP/Contents/MacOS/" >/dev/null 2>&1
}

wait_for_kodi_to_exit() {
    local waited=0
    while kodi_running; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$KODI_STOP_WAIT" ]; then
            log "Kodi did not quit gracefully; forcing"
            pkill -9 -f "Kodi.app/Contents/MacOS/Kodi" >/dev/null 2>&1
            sleep 2
            return 0
        fi
    done
}

stop_kodi() {
    kodi_running || return 0
    log "stopping Kodi (settings can only be changed while it is closed)..."
    osascript -e 'tell application "Kodi" to quit' >/dev/null 2>&1 &
    wait_for_kodi_to_exit
}

# The teardown's fallback way of stopping Kodi. Normally there is nothing to do:
# DeskPad quits Kodi itself, before the display goes, precisely so Kodi never gets
# moved onto the built-in screen. This covers the cases DeskPad cannot - it was
# killed rather than quit, or Kodi ignored it.
#
# JSON-RPC rather than the AppleScript that stop_kodi uses: the watcher runs
# detached from whatever started it, and sending an Apple event from there needs
# an Automation grant belonging to a responsible process that may not have one -
# a refusal would leave Kodi running for no visible reason. The socket needs no
# permission at all.
quit_kodi() {
    kodi_running || return 0
    log "quitting Kodi..."
    "$RPC" Application.Quit >/dev/null 2>&1 ||
        log "Kodi did not accept the quit over JSON-RPC; waiting for it anyway"
    wait_for_kodi_to_exit
}

start_kodi() {
    [ -d "$KODI_APP" ] || fail "Kodi not found at: $KODI_APP"
    log "starting Kodi..."

    # Before the launch, not after: Kodi reads SSL_CERT_FILE once, at startup.
    if [ -r "$CA_BUNDLE" ]; then
        launchctl setenv SSL_CERT_FILE "$CA_BUNDLE"
    else
        log "WARNING: no CA bundle at $CA_BUNDLE - repository fetches will fail with curl error 60"
    fi

    open -a "$KODI_APP" || fail "failed to launch Kodi"

    local waited=0
    until "$RPC" JSONRPC.Ping >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$RPC_WAIT" ]; then
            fail "Kodi did not become responsive within ${RPC_WAIT}s"
        fi
    done
    log "Kodi responsive after ~${waited}s"
}

# Ask Kodi which monitor option corresponds to our display, retrying because
# Kodi answers JSON-RPC within ~2s of launch - long before it has finished
# enumerating displays, so the option list starts out incomplete.
desired_monitor_option() {
    local waited=0
    local value
    while :; do
        value="$(query_monitor_option)"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -ge "$OPTION_WAIT" ] && return 1
    done
}

query_monitor_option() {
    "$RPC" Settings.GetSettings \
        '{"filter":{"section":"system","category":"display"}}' 2>/dev/null |
        DISPLAY_NAME="$DISPLAY_NAME" python3 -c '
import json, os, sys
name = os.environ["DISPLAY_NAME"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for setting in (data or {}).get("settings", []):
    if setting.get("id") != "videoscreen.monitor":
        continue
    for option in setting.get("options", []):
        value = option.get("value", "")
        if value.startswith(name):
            print(value)
            sys.exit(0)
sys.exit(1)
'
}

current_monitor() {
    "$RPC" Settings.GetSettingValue '{"setting":"videoscreen.monitor"}' 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("value",""))' 2>/dev/null
}

# --- session teardown ------------------------------------------------------

# Records what Kodi's display settings were before this session changed them.
capture_pre_session_settings() {
    # An existing record means a session is already in progress, and the settings
    # file already holds *our* values - reading it now would record the DeskPad
    # display as the thing to come back to.
    if [ -f "$STATE_FILE" ]; then
        log "keeping the pre-session settings already recorded"
        return 0
    fi

    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

    local captured
    captured="$("$PATCHER" --get "$GUISETTINGS" \
        videoscreen.monitor videoscreen.screenmode 2>/dev/null)"
    if [ -z "$captured" ]; then
        log "WARNING: could not read Kodi's display settings; they will not be restored"
        return 0
    fi

    # Belt and braces for the case above: if a previous watcher died without
    # restoring, the file still names our display. Restoring that would strand
    # Kodi on a display that no longer exists, so fall back to Kodi's own default.
    : > "$STATE_FILE"
    while IFS= read -r line; do
        case "$line" in
        "videoscreen.monitor=$DISPLAY_NAME"*)
            log "ignoring a stale record of our own display; will restore 'Default'"
            line="videoscreen.monitor=Default"
            ;;
        esac
        printf '%s\n' "$line" >>"$STATE_FILE"
    done <<EOF
$captured
EOF

    log "recorded Kodi's pre-session display settings"
}

# Puts them back. Only valid once Kodi has actually exited - Kodi writes its
# settings out on the way down and would clobber this.
restore_pre_session_settings() {
    if [ ! -f "$STATE_FILE" ]; then
        log "no pre-session settings recorded; leaving Kodi's settings alone"
        return 0
    fi

    local assignments=()
    while IFS= read -r line; do
        [ -n "$line" ] && assignments+=("$line")
    done <"$STATE_FILE"

    if [ "${#assignments[@]}" -eq 0 ]; then
        rm -f "$STATE_FILE"
        return 0
    fi

    log "restoring Kodi's pre-session display settings..."
    if "$PATCHER" "$GUISETTINGS" "${assignments[@]}"; then
        rm -f "$STATE_FILE"
    else
        log "WARNING: could not restore $GUISETTINGS - the record is kept at:"
        log "         $STATE_FILE"
    fi
}

# Waits for DeskPad's display to go, then finishes the session off: restoring
# Kodi's settings, which can only happen once Kodi has exited because Kodi writes
# them out on the way down. Quitting Kodi is DeskPad's job, not this one's - by
# the time we get here it has normally already happened.
watch_for_deskpad_exit() {
    log "teardown watcher running (pid $$)"
    while :; do
        if virtual_display_attached; then
            sleep 2
            continue
        fi
        # Re-running the launcher brings the display back within a second or two,
        # and tearing down a session that has just been rebuilt is worse than
        # doing nothing. Confirm the disappearance before acting on it.
        sleep 3
        virtual_display_attached || break
    done

    log "DeskPad's display has gone - finishing the session off"
    quit_kodi
    restore_pre_session_settings
    log "teardown done"
}

ensure_teardown_watcher() {
    if pgrep -f "$(basename "$SELF") --watch" >/dev/null 2>&1; then
        log "teardown watcher already running"
        return 0
    fi
    nohup "$SELF" --watch >>"$WATCH_LOG" 2>&1 &
    disown 2>/dev/null
    log "quitting DeskPad will now quit Kodi and restore its settings"
}

# --- main ------------------------------------------------------------------

[ -x "$RPC" ] || chmod +x "$RPC" 2>/dev/null
[ -x "$PATCHER" ] || chmod +x "$PATCHER" 2>/dev/null
[ -f "$GUISETTINGS" ] || fail "Kodi settings file not found: $GUISETTINGS"

if [ "${1:-}" = "--watch" ]; then
    watch_for_deskpad_exit
    exit 0
fi

# Before anything is patched, so there is something true to go back to.
capture_pre_session_settings

ensure_deskpad

# Fast path: patch the setting BEFORE Kodi's first launch so it initialises on
# the right display in one go.
#
# The catch is that the target string embeds the volatile session number, which
# is only authoritative from Kodi itself - and Kodi has to be running to ask.
# Empirically that number is (CGDirectDisplayID - 1), consistent across four
# measured sessions (47/48/49/50 -> 46/47/48/49). The mechanism is undocumented,
# so this is treated strictly as a *guess*: it saves a Kodi restart when right,
# and the authoritative check below still corrects it when wrong. Never rely on
# this offset alone.
if ! kodi_running; then
    display_id="$("$TOOLS/display_id.py" 2>/dev/null)"
    if [ -n "$display_id" ] && [ "$display_id" -gt 0 ] 2>/dev/null; then
        predicted="$DISPLAY_NAME ($((display_id - 1)))"
        log "pre-setting predicted monitor '$predicted' (displayID $display_id)"
        "$PATCHER" "$GUISETTINGS" \
            "videoscreen.monitor=$predicted" \
            "videoscreen.screenmode=$SCREENMODE" >/dev/null ||
            log "WARNING: could not pre-set settings; falling back to patch-and-restart"
    else
        log "could not read the display's id; falling back to patch-and-restart"
    fi
    start_kodi
fi

target="$(desired_monitor_option)"
if [ -z "$target" ]; then
    fail "Kodi does not list any monitor named '$DISPLAY_NAME'.
The virtual display is present but Kodi did not see it - it enumerates
displays only at startup, so try running this launcher again."
fi

active="$(current_monitor)"
log "Kodi's monitor: '${active:-unknown}' | target: '$target'"

if [ "$active" = "$target" ]; then
    log "already on the DeskPad display - nothing to do"
else
    # Kodi has to be stopped for the change: editing live wedges it.
    stop_kodi
    log "patching Kodi settings..."
    "$PATCHER" "$GUISETTINGS" \
        "videoscreen.monitor=$target" \
        "videoscreen.screenmode=$SCREENMODE" ||
        fail "could not update $GUISETTINGS"
    start_kodi

    active="$(current_monitor)"
    if [ "$active" = "$target" ]; then
        log "Kodi is now on '$active'"
    else
        log "WARNING: Kodi reports '${active:-unknown}' rather than '$target'."
        log "         The display's session number likely changed; re-run to converge."
    fi
fi

ensure_teardown_watcher

log "done - DeskPad left running (it stays up when Kodi quits)"
