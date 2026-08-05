# Working agreements for this repo

## Code signing — never use the organisation's Apple certificate

**Never sign this app with an employer's or organisation's Apple Developer or
Apple Distribution certificate.** This is a personal tool; it must not be
associated with an org signing identity, even for a local build.

Use the **self-signed local certificate** instead:

    CODE_SIGN_IDENTITY = 8A612C6B6386EA4B406CC97DF401D401CAF948AA   # "DeskPad Dev Signing"

It lives in the login keychain and is already configured in
`DeskPad.xcodeproj/project.pbxproj` for both Debug and Release. A plain
`xcodebuild ... build` picks it up — do not add `CODE_SIGNING_ALLOWED=NO`
overrides, and do not "fix" signing errors by reaching for an org identity or a
`DEVELOPMENT_TEAM`.

Why it must be a real certificate and not ad-hoc: TCC pins an ad-hoc app's
Screen Recording grant to its *binary hash*, so every rebuild silently revoked
permission and DeskPad's window went blank. A certificate-based signature gives
a stable designated requirement, so the grant survives rebuilds. See the signing
section of `LAUNCHER.md`.

## Git — never commit or push unless asked

* **Never commit until explicitly asked to.** Leave changes in the working tree.
* **Never push until separately asked.** Being asked to commit is *not*
  permission to push — these are two distinct approvals, every time.
* `origin` points at the upstream project (`Stengo/DeskPad`), which we do not
  control. Nothing here should ever be pushed there.

## Build and deploy

    xcodebuild -project DeskPad.xcodeproj -scheme DeskPad -configuration Release build

The product is `DeskPad Dev.app`, which is deployed by copying it to the repo
root. It is a build artifact and is gitignored — do not commit it.

The dev build intentionally differs from the upstream release build:

* bundle id `com.jellyvin.deskpad` (not `com.stengo.DeskPad`) so both can run
* display name `DeskPad Dev Display`
* `serialNum = 0x0002` so its virtual display can coexist with a release
  DeskPad's (`0x0001`) — macOS refuses two virtual displays sharing a
  vendor/product/serial identity

## Before changing display or Kodi behaviour

Read `LAUNCHER.md` first. It documents several non-obvious traps that were
established experimentally, and that look like working code when broken:

* Kodi's monitor string number is **not derivable** from any CoreGraphics
  identifier — always ask Kodi for its option list.
* Changing `videoscreen.monitor` while Kodi runs **wedges Kodi**.
* A setting carrying `default="true"` makes Kodi **ignore its stored value**.
* `CGDirectDisplayID` is a volatile per-boot counter — never persist it. The
  display's UUID is stable; use that.
* Reordering `CGVirtualDisplaySettings.modes` does **not** set the default
  resolution; macOS picks. The mode must be applied explicitly.
