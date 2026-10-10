# Kodi on VinDesk — launching Kodi

VinDesk starts Kodi on its own virtual display. Any of these does it:

| From | How |
|---|---|
| The menu | **Kodi › Launch Kodi on VinDesk**, in the main menu or under the menu bar icon |
| VinDesk starting | **Kodi › Launch Kodi When VinDesk Starts** — opening VinDesk is then the one click |
| A script or app, VinDesk not running | `open -a "VinDesk" --args --launch-kodi` |
| A script or app, VinDesk running | `{"op":"kodi_launch"}` on the API socket — see [API.md](API.md) |

All of them run the same code, `DeskPad/Backend/Kodi/KodiLauncher.swift`, one
launch at a time. Launching again while Kodi is already on the display is
harmless and returns straight away.

VinDesk is deliberately **left running when Kodi quits**. The reverse is linked:
**quitting VinDesk quits Kodi first**, then puts Kodi's display settings back —
see "Teardown" below.

This replaced a bash launcher (`launch-kodi-on-deskpad.sh`, a double-clickable
`Kodi on DeskPad.app`, and three Python helpers), removed on 2026-09-25. VinDesk
knows things the script had to guess or poll for — when the display exists,
whether it is quitting or the screens merely slept — and can refuse a second
launch that would otherwise race the first.

## Files

| Path | Role |
|---|---|
| `DeskPad/Backend/Kodi/KodiLauncher.swift` | The launch and the settings restore |
| `DeskPad/Backend/Kodi/KodiProtocol.swift` | `guisettings.xml` editing, and request/reply JSON-RPC over Kodi's raw TCP socket (port 9090) |
| `tools/kodi_protocol_check.swift` | Self-check for the above; no Kodi needed |
| `tools/kodi_rpc.py` | JSON-RPC from a terminal, for poking at Kodi by hand |
| `~/Library/Logs/vindesk.log` | Where a launch reports what went wrong (and where Kodi ended up) |
| `~/Library/Application Support/VinDesk/pre-session-settings` | Kodi's display settings as they were before this session, awaiting restore |

## What it does

1. Records Kodi's display settings, before anything is patched.
2. Waits for the virtual display to be registered with macOS — normally already
   the case, since it is VinDesk's own.
3. If Kodi isn't running, *predicts* the monitor string and writes it to
   `guisettings.xml` before launching, so Kodi initialises on the right display
   in one go (see "The prediction" below).
4. Starts Kodi if it isn't running, waiting until JSON-RPC answers.
5. Asks Kodi which monitor option corresponds to our display — the
   **authoritative** answer.
6. If Kodi isn't already on it: stops Kodi, patches `guisettings.xml`, restarts Kodi.
7. Verifies Kodi ended up on the right display, and reports failure if not.

A cold start is a single Kodi launch (~3s) when the prediction holds; if it
doesn't, step 6 corrects it at the cost of one extra Kodi launch (~20s).

Kodi is given the Netskope CA bundle at launch (`SSL_CERT_FILE`,
`REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, pointing at
`~/.certs/kodi-cacert-netskope.pem`), through `NSWorkspace`'s launch
configuration — so only Kodi gets it. The old script used `launchctl setenv`,
which handed it to every app launched afterwards. `SSL_CERT_FILE` covers Kodi's
libcurl and the Python stdlib; `requests` ignores it (`script.module.requests`
pins certifi's bundle) and reads the other two.

### The prediction

Kodi's session number is empirically `CGDirectDisplayID - 1`, consistent across
seven measured sessions (`47/48/49/50/51` → `46/47/48/49/50`; `24/25` → `23/24`).

**This is a heuristic, not a contract.** The mechanism is undocumented, and it
may well not hold with a third display attached or on a different Kodi build.
It is therefore only ever used to *guess* — step 5 still asks Kodi for the real
value and step 6 corrects a wrong guess. Never make this offset load-bearing;
if you remove the authoritative check, a bad guess silently strands Kodi on the
built-in display.

Why the guess is needed at all: the double launch happens exactly when the
stored value is stale, so reading `guisettings.xml` cannot avoid it — the file
holds a value but says nothing about whether it is still valid. Only a
prediction lets us patch *before* Kodi's first launch.

## Teardown

Quitting VinDesk ends the whole session: Kodi is quit and its display settings
are put back the way they were.

    Cmd-Q VinDesk
      → VinDesk asks Kodi to quit and holds its own termination open
      → Kodi exits (~2s) while the virtual display is still there
      → VinDesk restores guisettings.xml
      → VinDesk finishes quitting; the display goes

**Kodi must be gone before the display is.** The virtual display exists only as
long as VinDesk's process does, so a Kodi still running when VinDesk exits is
instantly homeless: macOS moves it to the built-in display, where it reappears
*fullscreen across the user's actual screen* until it finishes quitting. VinDesk
uses `.terminateLater` rather than blocking in `applicationWillTerminate`, so the
run loop keeps turning and the mirror carries on rendering while Kodi shuts down.
Measured: Kodi exits 1.9s after Cmd-Q and 0.4s before the display, and never
appears on the built-in display at all (0 of ~300 samples at 100ms).

**The settings restore must happen after Kodi is gone**, because Kodi writes its
settings out on the way down and would clobber an earlier one. It checks for a
running Kodi itself, so a Kodi that outlives the quit timeout is left alone.

This used to be a watcher script that outlived VinDesk and restored the settings
when the display disappeared. It had to guess whether a vanished display meant
VinDesk had quit or the screens had merely slept — and guessed wrong once
(2026-09-06), tearing down a live session. VinDesk knows which it is.

While a session is recorded, a Kodi that has strayed off our display is quit too,
since its settings cannot be restored while it runs.

Termination can never hang on this. Every path ends at a single reply, including
a backstop timer for the case where the connection is stuck in setup, so there is
neither a completion to wait for nor a process exit to observe. Quitting while a
recording runs finishes the movie first, and re-issues the quit from a run loop
block: re-entering `terminate` from main-queue work deadlocked against the Kodi
shutdown, whose reply is itself main-queue work.

Only `videoscreen.monitor` and `videoscreen.screenmode` are restored — the two
the launch changes. Restoring a whole backup of `guisettings.xml` would throw
away every other setting touched during the session.

**Never capture the pre-session values while a session is live.** They are read
once, before anything is patched, and kept in a file so a session that ends
without restoring does not cost the real values. If the record is absent *and*
the file already names our own display, the capture falls back to `Default`:
restoring the VinDesk display would strand Kodi on a display that no longer
exists.

**A missed restore is not fatal.** Kill VinDesk, or log out with a session live,
and the settings stay patched; Kodi then finds a display that isn't there and
falls back to `Default` on its own, and the next launch re-converges.

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
written as `<setting id="videoscreen.monitor" default="true">VinDesk Display
(46)</setting>` is treated as "use the built-in default" — Kodi loads `Default`
and quietly ignores the text. `GuiSettings` strips the attribute; that single
detail is the difference between working and silently doing nothing.

**Kodi persists settings on change, not just on clean exit.** So a `kill -9`
doesn't necessarily discard a settings change — but Kodi *will* overwrite edits
made underneath a running instance. Hence: stop, patch, start.

**Kodi can throw a correct monitor setting away at startup.** Measured
2026-09-06, repeatedly: Kodi discarded a correct stored `videoscreen.monitor`
about 3 seconds after launch — before its JSON-RPC even answered — and rewrote
it as `default="true">Default` (and `videoscreen.screenmode` as `WINDOW`). Yet
~20s later its option list contained the exact string it had rejected: the list
comes from a later, fuller enumeration than the one the setting was validated
against. So "Kodi lists the option" is not evidence the setting will stick. The
launch reports this as a failure rather than looping; launching again sometimes
helps and sometimes cannot.

**Process checks are by bundle id.** `NSRunningApplication` asked for
`org.xbmc.kodi`, never `pgrep -f`, which matches any command line that merely
*mentions* the path — a `grep`, an editor, a polling script. That held the old
watcher off for 40s once, and fired the instant the unrelated loop exited.

**The virtual display needs a moment, and Kodi enumerates displays only at
startup.** Launch Kodi too early and it lands on the built-in screen with no
error. The launcher waits for the display first — and a Kodi started before
VinDesk can never see the display at all, however often the launch is retried,
until Kodi itself is restarted.

## Input on the mirror

The mirror forwards both pointer and keyboard input, on deliberately different
gestures:

| Gesture | Effect |
|---|---|
| **Single click** | Focuses VinDesk and starts forwarding keystrokes. Touches the virtual display not at all. |
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

It does **activate the mirrored app**, though. Clicking the mirror makes VinDesk
active and leaves the mirrored app inactive, so without this the first real click
after the pointer arrives is spent activating it — the exact cost the gesture
exists to avoid. The trade is that **keyboard forwarding stops** at that moment,
because VinDesk is no longer frontmost. Nothing is lost: keystrokes now reach the
mirrored app natively, and a single click on the mirror takes the keyboard back.

While keystrokes are being forwarded the mirror draws a **border** in the
titlebar-active colour. Forwarding keys is otherwise invisible, and so is *not*
forwarding them.

Keyboard forwarding is live whenever VinDesk's window is focused and the mirror
holds first responder — which it takes at launch, so tabbing back to VinDesk
works as well as clicking it. `Cmd`-anything is left to VinDesk (menu key
equivalents never reach the view), so `Cmd-Q` still quits.

### Two different mechanisms, because keyboards are not mice

Mouse events are routed **by location** — post one at a point and it lands on
whatever window is there, focus irrelevant. Key events are routed **by focus**,
and the whole point here is to type while VinDesk rather than Kodi holds focus,
so there is nowhere for an ordinary posted key event to land. It would come
straight back to VinDesk.

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

This needs **two** permissions, and VinDesk must be **unsandboxed**:

| Requirement | Why |
|---|---|
| Screen Recording | capture the virtual display into the window |
| Accessibility | `System Settings > Privacy & Security > Accessibility` |
| No App Sandbox | the sandbox blocks event injection outright, even with Accessibility granted |

If clicks move the cursor but never click, permission is missing — VinDesk writes
the reason to `~/Library/Logs/vindesk.log` (and only then; the file staying
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

Also note `acceptsFirstMouse` is true, so the click that re-activates VinDesk is
delivered rather than swallowed — which is what lets a double click hand the
pointer over while VinDesk is inactive.

Both the pointer handover and a forwarded right click **activate the mirrored
app**, which takes focus away from VinDesk and stops keyboard forwarding — after
which keystrokes reach that app natively anyway. A single click on the mirror
brings the keyboard back.

## Display identity

VinDesk's virtual display is identified by a **stable UUID**
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

    defaults write com.jellyvin.deskpad kodiScreenMode WINDOW    # windowed instead of fullscreen

| Setting | Default |
|---|---|
| `kodiScreenMode` | `1920x1080p(1920x1080)` (native 1x 1080p; `WINDOW` for windowed) |
| `launchKodiAtStart` | off — toggled from the Kodi menu |

Kodi is found by bundle id (`org.xbmc.kodi`), so it can live anywhere.

## Troubleshooting

**VinDesk's window is blank.** VinDesk needs Screen Recording permission: System
Settings → Privacy & Security → Screen Recording. Note this grant is tied to the
app's code signature — see the signing note below.

**Kodi opens on the built-in display.** Its stored monitor string went stale
(the `(n)` changes with every VinDesk restart) and Kodi fell back to `Default`.
Launch again; it detects the mismatch and re-converges. If Kodi was started
before VinDesk, quit Kodi first — it only enumerates displays at startup.

**A launch fails.** **Kodi › Last launch failed** carries the reason as its
tooltip, and `~/Library/Logs/vindesk.log` has it too. "Kodi did not answer
JSON-RPC" means Kodi › Settings › Services › Control › *Allow remote control
from applications on this system* is off.

## Signing note

The dev build is signed with a **self-signed local certificate**
(`DeskPad Dev Signing`, in the login keychain) rather than ad-hoc. This is not
cosmetic: TCC pins an ad-hoc app's grant to its *binary hash*, so every rebuild
silently revoked Screen Recording. A certificate-based signature gives a stable
designated requirement:

    identifier "com.jellyvin.deskpad" and certificate root = H"8a612c…"

so the grant now survives rebuilds. Verified: two builds with different cdhashes
produced identical designated requirements.
