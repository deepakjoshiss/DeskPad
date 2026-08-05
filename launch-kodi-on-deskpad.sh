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
# DeskPad is deliberately left running when Kodi quits.

set -uo pipefail

DESKPAD_APP="${DESKPAD_APP:-/Users/deepak/work/apps/deskpad/DeskPad Dev.app}"
DISPLAY_NAME="${DISPLAY_NAME:-DeskPad Dev Display}"
KODI_APP="${KODI_APP:-/Applications/Kodi.app}"
GUISETTINGS="${GUISETTINGS:-$HOME/Library/Application Support/Kodi/userdata/guisettings.xml}"

# Fullscreen at native 1x 1080p on the virtual display. Set to WINDOW for a
# plain window instead.
SCREENMODE="${SCREENMODE:-1920x1080p(1920x1080)}"

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools"
RPC="$TOOLS/kodi_rpc.py"
PATCHER="$TOOLS/patch_guisettings.py"

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

deskpad_running() {
    pgrep -f "$(basename "$DESKPAD_APP")/Contents/MacOS/" >/dev/null 2>&1
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

kodi_running() {
    pgrep -f "Kodi.app/Contents/MacOS/Kodi" >/dev/null 2>&1
}

stop_kodi() {
    kodi_running || return 0
    log "stopping Kodi (settings can only be changed while it is closed)..."
    osascript -e 'tell application "Kodi" to quit' >/dev/null 2>&1 &

    local waited=0
    while kodi_running; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$KODI_STOP_WAIT" ]; then
            log "Kodi did not quit gracefully; forcing"
            pkill -9 -f "Kodi.app/Contents/MacOS/Kodi" >/dev/null 2>&1
            sleep 2
            break
        fi
    done
}

start_kodi() {
    [ -d "$KODI_APP" ] || fail "Kodi not found at: $KODI_APP"
    log "starting Kodi..."
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

# --- main ------------------------------------------------------------------

[ -x "$RPC" ] || chmod +x "$RPC" 2>/dev/null
[ -x "$PATCHER" ] || chmod +x "$PATCHER" 2>/dev/null
[ -f "$GUISETTINGS" ] || fail "Kodi settings file not found: $GUISETTINGS"

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

log "done - DeskPad left running (it stays up when Kodi quits)"
