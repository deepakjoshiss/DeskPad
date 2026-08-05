# Kodi on DeskPad — launcher

One click brings up the DeskPad virtual display and starts Kodi on it.

    open "Kodi on DeskPad.app"      # or double-click it in Finder

DeskPad is deliberately **left running when Kodi quits**. The reverse is linked:
**quitting DeskPad quits Kodi first**, then puts Kodi's display settings back —
see "Teardown" below.

## Files

| Path | Role |
|---|---|
| `Kodi on DeskPad.app` | Double-clickable wrapper (`LSUIElement`, so no Dock icon) |
| `launch-kodi-on-deskpad.sh` | All the logic; safe to run directly in a terminal |
| `tools/kodi_rpc.py` | Kodi JSON-RPC client over its raw TCP socket (port 9090) |
| `tools/patch_guisettings.py` | Surgical editor for Kodi's `guisettings.xml` |
| `tools/display_id.py` | Looks up the virtual display's current `CGDirectDisplayID` (ctypes, no compiled helper) |
| `~/Library/Logs/kodi-on-deskpad.log` | Per-run log (the wrapper's stdout, and the teardown watcher's) |
| `~/Library/Application Support/kodi-on-deskpad/pre-session-settings` | Kodi's display settings as they were before this session, awaiting restore |

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

## Teardown

Quitting DeskPad ends the whole session: Kodi is quit and its display settings
are put back the way they were. It is split across the two halves, and the split
is not arbitrary — each step has to happen at a moment only one of them can see.

    Cmd-Q DeskPad
      → DeskPad asks Kodi to quit and holds its own termination open
      → Kodi exits (~2s) while the virtual display is still there
      → DeskPad finishes quitting; the display goes
      → the watcher sees the display go and restores guisettings.xml, then exits

**Kodi must be gone before the display is.** The virtual display exists only as
long as DeskPad's process does, so a Kodi still running when DeskPad exits is
instantly homeless: macOS moves it to the built-in display, where it reappears
*fullscreen across the user's actual screen* until it finishes quitting. Only
DeskPad can prevent that, because only DeskPad knows it is about to quit. It uses
`.terminateLater` rather than blocking in `applicationWillTerminate`, so the run
loop keeps turning and the mirror carries on rendering while Kodi shuts down.
Measured: Kodi exits 1.9s after Cmd-Q and 0.4s before the display, and never
appears on the built-in display at all (0 of ~300 samples at 100ms).

**The settings restore must happen after Kodi is gone**, because Kodi writes its
settings out on the way down and would clobber an earlier one. That is the
watcher's job, and it stays in the launcher: DeskPad has no business knowing
about `guisettings.xml`, and the restore has to outlive DeskPad anyway.

The watcher is also the fallback for everything DeskPad cannot cover — being
killed rather than quit, or Kodi ignoring the request — since it keys on the
display disappearing rather than on a clean quit. In the normal case it finds
Kodi already gone and only restores the settings.

Termination can never hang on this. Every path ends at a single reply, including
a backstop timer for the case where the connection is stuck in setup, so there is
neither a completion to wait for nor a process exit to observe.

Only `videoscreen.monitor` and `videoscreen.screenmode` are restored — the two
the launcher changes. Restoring a whole backup of `guisettings.xml` would throw
away every other setting touched during the session.

**Never capture the pre-session values while a session is live.** They are read
once, before anything is patched, and kept in a file so a watcher that dies
without restoring does not cost the real values. If the record is absent *and*
the file already names our own display, the capture falls back to `Default`:
restoring the DeskPad display would strand Kodi on a display that no longer
exists.

**A missed restore is not fatal.** Log out with a session live and the settings
stay patched; Kodi then finds a display that isn't there and falls back to
`Default` on its own, and the next launcher run re-converges.

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

**`pgrep -f` matches command lines that merely mention what you searched for.**
The teardown watcher originally polled for DeskPad's process this way, and any
other process whose arguments contained the app's path — a `grep`, an editor, a
script polling for the same thing — read as "DeskPad is still running", so the
teardown silently never fired. Measured: a test loop running `pgrep -f "DeskPad
Dev.app/Contents/MacOS/"` held the watcher off for a full 40s, and it fired the
instant that loop exited. Process checks here are anchored with `^` so they match
a real command line rather than a mention of one; the watcher avoids the question
altogether by asking CoreGraphics whether the display is attached.

**The virtual display needs a moment, and Kodi enumerates displays only at
startup.** Launch Kodi too early and it lands on the built-in screen with no
error. The launcher waits for the display first.

## Input on the mirror

The mirror forwards both pointer and keyboard input, on deliberately different
gestures:

| Gesture | Effect |
|---|---|
| **Single click** | Focuses DeskPad and starts forwarding keystrokes. Touches the virtual display not at all. |
| **Double click** | Hands the **pointer** over: the cursor jumps to that spot on the virtual display and stays there. Clicks nothing. |
| Right click | Forwards a right click immediately |
| Scroll | Forwarded immediately |

So the mirror is a keyboard remote by default, and the pointer is only handed
over when you ask for it.

A double click deliberately **does not click anything**. It moves the cursor and
stops, because from that moment the physical mouse *is* on the virtual display —
so clicks, drags and hovers are the real thing rather than synthesised
approximations of one, and there is nothing left to forward. (A synthetic click
was forwarded here at one point; it was strictly more machinery for a worse
result.)

It does **activate the mirrored app**, though. Clicking the mirror makes DeskPad
active and leaves the mirrored app inactive, so without this the first real click
after the pointer arrives is spent activating it — the exact cost the gesture
exists to avoid. The trade is that **keyboard forwarding stops** at that moment,
because DeskPad is no longer frontmost. Nothing is lost: keystrokes now reach the
mirrored app natively, and a single click on the mirror takes the keyboard back.

While keystrokes are being forwarded the mirror draws a **border** in the
titlebar-active colour. Forwarding keys is otherwise invisible, and so is *not*
forwarding them.

Keyboard forwarding is live whenever DeskPad's window is focused and the mirror
holds first responder — which it takes at launch, so tabbing back to DeskPad
works as well as clicking it. `Cmd`-anything is left to DeskPad (menu key
equivalents never reach the view), so `Cmd-Q` still quits.

### Two different mechanisms, because keyboards are not mice

Mouse events are routed **by location** — post one at a point and it lands on
whatever window is there, focus irrelevant. Key events are routed **by focus**,
and the whole point here is to type while DeskPad rather than Kodi holds focus,
so there is nowhere for an ordinary posted key event to land. It would come
straight back to DeskPad.

**Kodi therefore gets keys over JSON-RPC**, not as synthetic events:
`Input.ButtonEvent` with keymap `KB`. This sidesteps focus entirely (verified
driving a Kodi that was in the background while iTerm2 was frontmost) and routes
through *Kodi's own* keyboard keymap, so the mirror inherits whatever each key
already does in Kodi — including keymap edits. Mapping keys to semantic actions
(`Input.Select`, `Input.Back`) instead would hard-code one interpretation and
get the context-dependent keys wrong.

Anything else on the virtual display gets `CGEvent.postToPid`, which addresses a
process rather than the focused app. That path is **best-effort by design**:
whether it lands depends on how the target reads the keyboard. Apps watching an
NSEvent monitor or an event tap see it while inactive; apps relying on the
responder chain need a key window and will ignore it.

**Kodi is in the second group — do not "simplify" it onto `postToPid`.** Traced
in the shipped binary (22.0 beta1): `-[OSXGLView keyDown:]` tail-calls
`SendInputEvent:` → `CWinSystemOSX` → `CWinEventsOSXImpl`. There is no NSEvent
monitor anywhere in it (`enableInputEvents` only sets a bool), so key delivery
needs a key window, which an inactive app does not have.

Two known limits of the Kodi path, both from `Input.ButtonEvent` itself:
modifiers cannot be expressed (it takes a button name and nothing else, so
`Shift`/`Ctrl`/`Alt` combos arrive as the bare key), and typing into a text
field needs `Input.SendText` gated on the virtual-keyboard dialog being up —
not implemented, so letters currently act as Kodi shortcuts only.

### Mouse specifics

Only the right click still synthesises a click — the pointer path just warps the
cursor, as upstream did. The notes below therefore apply to right click, and to
the `.mouseMoved` event that accompanies every warp.

This needs **two** permissions, and DeskPad must be **unsandboxed**:

| Requirement | Why |
|---|---|
| Screen Recording | capture the virtual display into the window |
| Accessibility | `System Settings > Privacy & Security > Accessibility` |
| No App Sandbox | the sandbox blocks event injection outright, even with Accessibility granted |

If clicks move the cursor but never click, permission is missing — DeskPad writes
the reason to `~/Library/Logs/deskpad-dev.log` (and only then; the file staying
absent means it's healthy).

### Four traps, all of which look like "clicks silently do nothing"

**Event injection has its own TCC service.** It is gated by
`kTCCServicePostEvent`, *not* Accessibility, so `AXIsProcessTrustedWithOptions`
asks for the wrong thing and `CGEvent.post` keeps failing silently.
`CGPreflightPostEventAccess` / `CGRequestPostEventAccess` are the correct APIs.

**`CGWarpMouseCursorPosition` generates no events.** Documented behaviour. Warp
alone and the target app never learns the pointer moved, so it handles the click
at its own stale pointer position — the click *is* delivered, just somewhere
else. An explicit `.mouseMoved` event has to accompany the warp.

**A tight move/down/up burst gets dropped.** Apps that sample input on a frame
boundary (Kodi and SDL apps generally) miss it, which shows up as clicks needing
two or three attempts. The events are paced ~15ms apart on a dedicated queue.

**The mirror must not drag the window.** The window is movable by its background,
so AppKit starts a window-drag on mouse-down; warping the cursor then drags the
window onto the display it is mirroring, where it appears to vanish into a
recursive mirror. `ScreenView.mouseDownCanMoveWindow` returns false to prevent
it. The titlebar still moves the window.

Also note `acceptsFirstMouse` is true, so the click that re-activates DeskPad is
delivered rather than swallowed — which is what lets a double click hand the
pointer over while DeskPad is inactive.

Both the pointer handover and a forwarded right click **activate the mirrored
app**, which takes focus away from DeskPad and stops keyboard forwarding — after
which keystrokes reach that app natively anyway. A single click on the mirror
brings the keyboard back.

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
