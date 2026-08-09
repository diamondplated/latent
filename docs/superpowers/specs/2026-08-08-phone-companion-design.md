# Phone companion — design

**Date:** 2026-08-08
**Status:** approved, not yet implemented

## Summary

Latent gains an opt-in local web server. Pair a phone by scanning a QR code on the Mac, and
the phone becomes a browsing and culling surface for folders you have explicitly shared.
Swipe up to pick, down to reject, sideways to move. Everything stays on the LAN.

The phone is **a second input device, not a second client**. It sends `VimAction` values to
the running Latent process, which applies them through the same code path the keyboard uses.

## Why this shape

Three constraints drive nearly every decision below.

**No Apple Developer ID.** The Mac build is ad-hoc signed and unnotarized for this reason.
iOS has no ad-hoc escape hatch: no App Store, no TestFlight, and free provisioning expires
every seven days and needs a Mac plus Xcode per reinstall. A native iOS app is undistributable
for this project. A web app served off the Mac needs no certificates, no store, and no account,
and it works on Android and iPad for free.

**The README promises zero runtime network calls.** That promise is the product. It becomes
"zero runtime network calls by default" — with the feature off unless you turn it on, bound to
the LAN, and dead the moment Latent quits. See "README changes" below; getting this wording
right is part of the work, not an afterthought.

**`Package.swift` has zero external dependencies.** That is an asset for an app whose pitch is
"nothing in between," and this feature will not spend it. `NWListener` (Network.framework, in
the OS since macOS 10.14) plus a small HTTP/1.1 subset keeps the count at zero. swift-nio and
Vapor are both rejected: they pull a dependency tree to serve seven routes.

## Non-goals

Explicitly out of scope for v1, listed so they don't creep in:

- **Access from outside the LAN.** The moment photos leave the house, Latent is Google Photos
  with extra steps. Not a limitation to be fixed later — a deliberate boundary.
- **Enhancement from the phone.** No pipeline triggering, no enhanced previews. You cannot
  judge a denoise pass on a 6-inch screen, and running the five-stage pipeline on demand per
  request is a performance trap.
- **Video.** `MediaPlayer` exists on the Mac, but streaming video needs HTTP range request
  support. Images are small enough to serve whole, so skipping video keeps range handling out
  of the server entirely.
- **Map view, folder tree browsing, multi-Mac, TLS.** See "Security" for why TLS is excluded
  rather than deferred.

## Architecture

### Module layout

A new `PhotoServe` library plus a thin controller in the app, following the existing grain —
`PhotoViewerCore` exists precisely so `VimKeymap` can be tested outside the app target.

```
Sources/PhotoServe/               (new library, no AppState knowledge)
├── LocalServer.swift             NWListener lifecycle, connection handling
├── HTTPMessage.swift             request parse / response serialize, HTTP/1.1 subset
├── Router.swift                  route table, auth gate
├── PairingManager.swift          one-time codes, device tokens, revocation
├── SharedFolders.swift           opaque photo IDs ↔ real paths
└── Resources/client.html         the phone app, one file, inlined CSS + JS

Sources/PhotoViewerApp/
├── PhoneAccess/
│   ├── PhoneAccessController.swift   bridges PhotoServe ↔ AppState
│   ├── PairingSheet.swift            QR display, device approval, revoke list
│   └── QRRenderer.swift             CoreImage CIQRCodeGenerator
```

`PhotoServe` knows nothing about `AppState`; it exposes a delegate protocol the controller
implements. That keeps the HTTP and pairing logic reachable from `pv-pipeline`, which can
import a library but not an executable target.

### The refactor this needs

Today the `VimAction` dispatch lives inside `BrowserView.handleKey`, and the keymap is
`@State private var vimKeymap = VimKeymap()` on that view. Neither is reachable from a server.

1. Move `VimKeymap` ownership from `BrowserView` to `AppState`, alongside `selection`,
   `trash`, `recents`, and `prefetcher`, which already live there.
2. Extract the `switch action` block from `handleKey` into `AppState.dispatch(_: VimAction)`,
   including the existing sidecar persistence.
3. `BrowserView.handleKey` becomes: keystroke → `VimAction` → `state.dispatch(action)`.
4. `PhoneAccessController` calls the same `state.dispatch(action)`.

This is the seam the feature needs, not opportunistic refactoring. Without it the phone would
need its own copy of what pick, reject, and label mean — two implementations of the app's
core verb set, guaranteed to diverge.

### Single-writer property

Because the server runs **inside** the Latent process and mutates through `AppState.dispatch`,
there is exactly one writer to any sidecar. This deletes an entire category of work: no file
locking, no sidecar merge, no last-write-wins, no conflict UI. Trash routes through the
existing `TrashManager`, so `⌘Z` on the Mac still undoes something done on the phone.

This is worth stating plainly because the obvious alternative — a separate helper process
reading and writing the same `.enhance.json` files — would have needed all of it.

### Routes

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | the phone client, one HTML file |
| `POST` | `/api/pair` | redeem one-time code → device token. **Only unauthenticated route** |
| `GET` | `/api/folders` | shared folders |
| `GET` | `/api/folder/{id}` | photo list: opaque IDs, dimensions, pick/reject/label state |
| `GET` | `/api/thumb/{id}` | grid thumbnail, reuses the existing `ThumbnailLoader` cache |
| `GET` | `/api/preview/{id}` | ~2048px JPEG, generated on demand |
| `POST` | `/api/action` | `{photoID, action}` → `VimAction` → `AppState.dispatch` |
| `GET` | `/api/search?q=` | CLIP text search, only when the folder has an index |
| `GET` | `/api/events` | SSE stream of state changes, so both screens stay live |

Live sync uses **server-sent events**, not WebSockets. SSE is one-way, which is all this needs,
and it is plain HTTP with no handshake to hand-roll — the difference between roughly 15 lines
and roughly 150.

Search delegates entirely to the existing `SearchEngine`. When `Resources/Models/` has no
OpenCLIP assets, or the folder has no index, the route 404s and the phone hides the search box.

Previews are downscaled JPEGs. Sending a 50 MP RAW to a phone over wifi is not a feature.

## Security

The threat model is not strangers on the internet — it is everything else already on the LAN.
On a typical home network that includes sensors, vacuums, printers, and cameras. Compromised
IoT is the realistic attacker, and it is well placed to scan ports and sniff traffic.

**Off by default.** A settings toggle plus the pairing sheet. The listener does not exist until
you turn it on, and stops on toggle-off or app quit.

**Pairing is a one-time code, not a session token.** The QR carries a 128-bit random code with
a 60-second TTL, single use. The phone trades it for a device-bound token. A photograph of your
screen taken after redemption is worthless. A long-lived token in the QR would have none of
this property.

**Redemption requires approval on the Mac.** The pairing sheet shows the requesting IP and
user-agent and waits for you. Someone who snaps the QR from across the room cannot pair
silently — you watch it happen and decline.

**Device tokens** are 256-bit, Keychain on the Mac, `localStorage` on the phone, sent as
`Authorization: Bearer`. Compared in constant time. Revocable individually from the Mac.

**Private-address gate.** Connections whose remote address is not RFC1918 or link-local are
refused, independent of the listener binding. Belt and braces against a misconfigured network.

**Opaque photo IDs.** The client never sends a path. IDs are random per session and resolve
through `SharedFolders` to paths inside shared folders only. Path traversal is the classic bug
for a file-serving app and it is designed out rather than filtered.

**Folder scoping.** The phone sees only folders you explicitly share, defaulting to the one
currently open. Exposing the whole recent-folders list was considered and rejected: if a paired
phone is lost, the blast radius should be the folder you were culling, not your photo archive.

**Rate limit** of 5 attempts per minute on `/api/pair`.

### Why no TLS

A self-signed certificate on a LAN makes Safari show "This Connection Is Not Private" on every
launch, and the only way to use the app is to tap through it. That trains the habit of
dismissing the exact warning that protects you everywhere else. A permanent click-through
reflex is a worse security outcome than plaintext on your own wifi.

The mitigation is honesty, not theatre: the README states that LAN traffic is unencrypted.
Revisit only if Latent ever ships a real signing identity, which would make a trusted local
certificate possible.

## Phone client

One HTML file, inlined CSS and JS, no framework, no build step. Add-to-home-screen makes it
look like an app.

**Grid.** Thumbnails with colour-label dots and pick/reject state.

**Full screen.** Tap a thumbnail. Pinch to zoom.

**Gestures.** Each maps directly to an existing `VimAction`:

| Gesture | `VimAction` | Keyboard equivalent |
|---|---|---|
| Swipe up | `.togglePick` | `⇧P` |
| Swipe down | `.toggleReject` | `X` |
| Swipe left | `.next` | `j` |
| Swipe right | `.prev` | `k` |
| Long press | `.setColorLabel(n)` | digits |

Swipe was chosen over a button bar because the photo is the point — a bar costs a third of a
phone screen permanently — and because swipe is the closest thing to the muscle memory the vim
keymap already builds. Colour labels are the one action swipe cannot express in four
directions, hence long press.

**Swipe thresholds need a calibration knob.** Distance and velocity cutoffs that feel right in
a simulator feel wrong in a hand, and they differ between a phone and an iPad. These are tuning
constants at the top of the client, not values to bury.

## Testing

Following the repo's `pv-pipeline` pattern — assert-based, no Xcode, no models — a new
`Sources/PipelineCLI/ServeVerifications.swift` covers:

- HTTP request parsing: malformed request lines, missing headers, oversized bodies, pipelining
- Pairing codes: single use, 60-second expiry, rate limit
- Token comparison is constant time
- Opaque ID resolution rejects traversal and paths outside shared folders
- The private-address gate rejects public remote addresses
- SSE framing

`VimAction` semantics are already covered by `Tests/PhotoViewerCoreTests/VimKeymapTests.swift`
and stay covered, since the phone produces the same values. The `AppState.dispatch` extraction
should not change any existing test.

## README changes

The headline claim must be updated in the same commit as the feature, not later:

- "Zero runtime network calls" → "Zero runtime network calls by default"
- A short section stating: off unless enabled, LAN only, one-time QR pairing with approval on
  the Mac, unencrypted on your local network, stops when Latent quits
- The feature list gains one line

## Risks

**SDK sensitivity.** The project has been bitten twice by APIs that compile locally on a macOS
26 SDK and fail on CI's macos-15. Network.framework is old and stable, which lowers the risk,
but CI remains the only oracle — this cannot be verified on the dev machine.

**Scope creep toward a sync product.** Every non-goal above is a thing someone will ask for.
The LAN boundary in particular is load-bearing for the product's identity, not a milestone.

## Build order

1. `AppState.dispatch` extraction and `VimKeymap` move — pure refactor, existing tests must pass
2. `PhotoServe`: HTTP subset, router, `ServeVerifications` — no app wiring yet
3. `PairingManager` plus verifications
4. `PhoneAccessController`, pairing sheet, QR
5. Phone client: grid, full screen, swipe
6. SSE live sync
7. Search route, conditional on an index existing
8. README
