# Kodi on DeskPad — launcher

One click brings up the DeskPad virtual display and starts Kodi on it.

    open "Kodi on DeskPad.app"      # or double-click it in Finder

DeskPad is deliberately **left running when Kodi quits**.

## Files

| Path | Role |
|---|---|
| `Kodi on DeskPad.app` | Double-clickable wrapper (`LSUIElement`, so no Dock icon) |
| `launch-kodi-on-deskpad.sh` | All the logic; safe to run directly in a terminal |
| `tools/kodi_rpc.py` | Kodi JSON-RPC client over its raw TCP socket (port 9090) |
| `tools/patch_guisettings.py` | Surgical editor for Kodi's `guisettings.xml` |
| `tools/display_id.py` | Looks up the virtual display's current `CGDirectDisplayID` (ctypes, no compiled helper) |
| `~/Library/Logs/kodi-on-deskpad.log` | Per-run log (the wrapper's stdout) |

Run the script directly to see what it's doing; the `.app` only exists to make
it clickable and logs to the file above.

## What it does

1. Starts `DeskPad Dev.app` if the virtual display isn't already present, and
   **waits for the display to register**.
2. If Kodi isn't running, *predicts* the monitor string and writes it to
   `guisettings.xml` before launching, so Kodi initialises on the right display
   in one go (see "The prediction" below).
3. Starts Kodi if it isn't running, waiting until JSON-RPC answers.
4. Asks Kodi which monitor option corresponds to our display — the
   **authoritative** answer.
5. If Kodi isn't already on it: stops Kodi, patches `guisettings.xml`, restarts Kodi.
6. Verifies Kodi ended up on the right display.

A cold start is a single Kodi launch (~4s) when the prediction holds; if it
doesn't, step 5 corrects it at the cost of one extra Kodi launch (~20s). It's
idempotent — clicking twice is harmless.

### The prediction

Kodi's session number is empirically `CGDirectDisplayID - 1`, consistent across
five measured sessions (`47/48/49/50/51` → `46/47/48/49/50`).

**This is a heuristic, not a contract.** The mechanism is undocumented, and it
may well not hold with a third display attached or on a different Kodi build.
It is therefore only ever used to *guess* — step 4 still asks Kodi for the real
value and step 5 corrects a wrong guess. Never make this offset load-bearing;
if you remove the authoritative check, a bad guess silently strands Kodi on the
built-in display.

Why the guess is needed at all: the double launch happens exactly when the
stored value is stale, so reading `guisettings.xml` cannot avoid it — the file
holds a value but says nothing about whether it is still valid. Only a
prediction lets us patch *before* Kodi's first launch.

## Hard-won details

These are all things that silently broke a working-looking setup. Change them at
your peril.

**Kodi's monitor string is `"<display name> (<n>)"`, and `<n>` is not derivable.**
Measured against every plausible candidate while the display sat unchanged at
`displayID=47`: Kodi reported `46`, `unitNumber=3`, `serialNum=2`. So `<n>` is
none of those. The launcher therefore **never computes it** — it asks Kodi for
its own option list and matches on the display name prefix. Don't "optimise"
this into a computed string.

**Never change `videoscreen.monitor` while Kodi is running.** Doing it live (via
JSON-RPC `Settings.SetSettingValue`) reinitialises Kodi's renderer and **wedges
the app** — process alive, main loop stuck, JSON-RPC dead. Reproduced. The
launcher only ever changes it with Kodi stopped, so Kodi initialises directly on
the target display.

**`default="true"` makes Kodi ignore a setting's stored value.** A setting
written as `<setting id="videoscreen.monitor" default="true">DeskPad Dev Display
(46)</setting>` is treated as "use the built-in default" — Kodi loads `Default`
and quietly ignores the text. `patch_guisettings.py` strips the attribute; that
single detail is the difference between working and silently doing nothing.

**Kodi persists settings on change, not just on clean exit.** So a `kill -9`
doesn't necessarily discard a settings change — but Kodi *will* overwrite edits
made underneath a running instance. Hence: stop, patch, start.

**The virtual display needs a moment, and Kodi enumerates displays only at
startup.** Launch Kodi too early and it lands on the built-in screen with no
error. The launcher waits for the display first.

## Display identity

DeskPad's virtual display is identified by a **stable UUID**
`D85CA43F-3D1D-4440-84C7-79DF61769218`, derived from the
vendor/product/serial triple hardcoded in
`DeskPad/Frontend/Screen/ScreenViewController.swift`. The `CGDirectDisplayID` by
contrast is a monotonic per-boot counter (observed marching 27 → 47 across
launches) and must never be persisted anywhere.

The dev build uses `serialNum = 0x0002` specifically so it can run **alongside**
a release DeskPad (`0x0001`) — macOS refuses to create two virtual displays
sharing a vendor/product/serial identity, and the second one silently fails with
`displayID = 0`.

## Configuration

Override via environment variables:

    SCREENMODE=WINDOW ./launch-kodi-on-deskpad.sh   # windowed instead of fullscreen

| Variable | Default |
|---|---|
| `DESKPAD_APP` | `/Users/deepak/work/apps/deskpad/DeskPad Dev.app` |
| `DISPLAY_NAME` | `DeskPad Dev Display` |
| `KODI_APP` | `/Applications/Kodi.app` |
| `SCREENMODE` | `1920x1080p(1920x1080)` (native 1x 1080p; `WINDOW` for windowed) |

## Troubleshooting

**DeskPad's window is blank / launcher times out waiting for the display.**
DeskPad needs Screen Recording permission: System Settings → Privacy & Security
→ Screen Recording. Note this grant is tied to the app's code signature — see
the signing note below.

**Kodi opens on the built-in display.** Its stored monitor string went stale
(the `(n)` changed after a DeskPad restart) and Kodi fell back to `Default`.
Just run the launcher again; it detects the mismatch and re-converges.

**The launcher script moved.** `Kodi on DeskPad.app` references it by absolute
path; update `Contents/MacOS/launcher` if you relocate the repo.

## Signing note

The dev build is signed with a **self-signed local certificate**
(`DeskPad Dev Signing`, in the login keychain) rather than ad-hoc. This is not
cosmetic: TCC pins an ad-hoc app's grant to its *binary hash*, so every rebuild
silently revoked Screen Recording. A certificate-based signature gives a stable
designated requirement:

    identifier "com.jellyvin.deskpad" and certificate root = H"8a612c…"

so the grant now survives rebuilds. Verified: two builds with different cdhashes
produced identical designated requirements.
