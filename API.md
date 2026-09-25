# DeskPad capture API

Screenshots and recordings of the DeskPad virtual display, for other apps and
agents. DeskPad holds the Screen Recording permission, so callers do not need
their own.

The cursor is never in the image, and no audio is recorded.

## Connecting

A Unix socket, readable only by your user:

    ~/Library/Application Support/DeskPad Dev/api.sock

Each connection carries **one request**:

1. The client sends one JSON object followed by `\n`.
2. DeskPad replies with one JSON header line followed by `\n`, then exactly
   `len` bytes (`len` is 0 unless PNG bytes follow).
3. DeskPad closes the connection.

```sh
SOCK="$HOME/Library/Application Support/DeskPad Dev/api.sock"

# Write to a file: the reply is the header line only.
printf '{"op":"screenshot","path":"/tmp/shot.png"}\n' | nc -U "$SOCK"

# PNG bytes in the reply: split the header off the image.
printf '{"op":"screenshot","max_width":960}\n' | nc -U "$SOCK" |
  { IFS= read -r header; echo "$header"; cat > shot.png; }
```

Python: see `request()` in `tools/capture_api_check.py`. That script also
exercises the whole API against the running app.

## Who may call

The first request from an app shows a prompt in DeskPad: **Deny**, **Allow
Once** or **Always Allow**. A prompt left unanswered for 60 seconds counts as
Deny. Remove apps under **Capture > Allowed Apps**.

The "app" is the first process up the caller's parent chain whose signature is
not Apple's. For `nc` run by Claude Code, that is Claude Code. For a script
typed into Terminal, where everything is Apple-signed, it is Terminal.
Approving an app therefore approves everything that runs under it.

"Always Allow" stores the app's code-signing identity, not its bundle id. A
properly signed app stays allowed across updates. An ad-hoc-signed binary is
identified by its hash, so every rebuild is asked again.

## Operations

| `op` | Request fields | Reply header when `ok` |
|---|---|---|
| `screenshot` | `max_width`, `path`, `after_t`, `timeout_ms` | `t`, `w`, `h`, `colorspace`, plus `path` if given |
| `record_start` | `path`, `max_width`, `max_seconds` | `t`, `path` |
| `record_stop` | none | `t`, `path`, `duration` (seconds) |
| `status` | none | `t`, `w`, `h`, `scale`, `colorspace`, `recording`, `recording_path` |

All request fields are optional. Every header has `ok`, `len` and `t`.

- **`t`**: epoch milliseconds at which the latest frame was displayed. Frames
  exist only when the screen's content changes, so `t` means "the screen last
  changed at". A stale frame shows up as an old `t`. It is `null` before the
  first frame.
- **`after_t`**: wait for a frame with `t` greater than this, up to
  `timeout_ms` (default 2000, max 60000). Pass a previous reply's `t`, or your
  own clock time, e.g. the moment you clicked. Without `after_t`, the latest
  frame is returned, waiting up to `timeout_ms` only if none has arrived yet.
- **`max_width`**: scales down to at most this many pixels wide, keeping the
  aspect ratio. Without it the image is the display's exact pixel size and
  never resampled. It never scales up. Scaling blends neighbouring pixels, so
  do not read colours from a scaled image.
- **`w`, `h`**: the real pixel size of the returned image. `status` also
  reports `scale` (2 on a HiDPI mode).
- **`colorspace`**: the colour space the PNG is tagged with (embedded as its
  ICC profile). Pixels are never converted to sRGB.
- **`path`**: where DeskPad writes the file. It must be absolute, end in `.png`
  (screenshots) or `.mov` (recordings), have an existing parent folder, and not
  exist yet. DeskPad never overwrites and never follows a symlink. Without
  `path`, a screenshot's PNG comes back in the reply, and a recording goes to
  `~/Pictures/DeskPad/`.
- **`max_seconds`**: recordings stop by themselves after this long (default
  600, max 3600).
- **Movie format**: HEVC in `.mov`, tagged BT.709, at variable frame rate. A
  frame is written only when the screen changes; a still screen holds its last
  frame, and the movie still runs until the moment it was stopped.
- **One recording at a time.** Only the app that started a recording can stop
  it. The user can stop any recording from the menu. The menu bar icon is red
  while anything is recording.

## Errors

    {"ok":false,"error":"<code>","message":"<human-readable detail>","t":…,"len":0}

A failure is never an empty or stale image.

| `error` | Meaning |
|---|---|
| `bad_request` | Not a JSON line, unknown `op`, or an out-of-range field |
| `denied` | Not allowed, prompt denied or timed out, or someone else's recording |
| `bad_path` | `path` breaks one of the rules above |
| `no_frame_yet` | No frame has arrived yet, e.g. just after launch or a resolution change |
| `timeout` | No frame newer than `after_t` arrived in time; `t` is the latest one |
| `display_off` | The screens are asleep |
| `capture_failed` | Screen capture is not running (see `message`); DeskPad retries it |
| `encode_failed` | The frame could not be encoded as PNG |
| `write_failed` | The file could not be written |
| `busy` | A recording is already running |
| `not_recording` | Nothing to stop. If a recording ended by itself, e.g. because the screens slept, `message` says why and whether what was recorded until then was saved |
