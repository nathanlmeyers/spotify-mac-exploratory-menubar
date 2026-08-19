# Roadmap

## Phase 2 — Discovery mode
Computed precise-pause hold (`duration − position`, fire ~300ms early to beat the
Apple-event latency + auto-advance race; recompute on seek/pause; 0:00 fallback for
crossfade). Combinable alerts (auto-open panel / badge / sound). Auto-skip rules
(already-in-target [+ remove from source], already-reviewed) with skip-loop protection
("nothing new to review"). Settings already exist; engine to be implemented in
`Discovery/DiscoveryEngine.swift`.

## More toolkit features
The app is a home for Spotify features Spotify doesn't ship. Shipped so far: Discovery
mode, New From Followed, Clear Your Episodes. Candidates:
- Notify on a new find, and a per-artist mute list for the release radar.
- Bulk playlist dedupe.
- "What playlist is this song in?" across your library.

Each feature should keep its decision logic in a pure type registered in the test target's
source list (see `NewReleaseLogic`), so it can be tested without launching the app.

## Extracting a reusable core
`Auth/`, `API/`, and the pure logic types are the reusable part. Worth extracting into a
local SwiftPM package once two or three more features exist — extracting for one is
premature, and it would break `UserRemovalIntent`'s `fileprivate` compile-time gate on
destructive calls (`App/AppModel.swift`), which is a real safety property. Only split to a
separate repo if something outside this app wants to depend on it.

## Apple Music + multi-provider support
`SpotifyProvider` is currently a concrete class. A `MusicProvider` protocol would have to be
introduced first (the README used to claim one existed; it never did). Then add an
`AppleMusicProvider`:
- Playback read/control + **playlist edits** via the `Music.app` scripting interface
  (unlike Spotify, Apple Music *can* edit playlists locally) or MusicKit.
- No OAuth/PKCE needed if using local scripting; MusicKit would use a different auth.
Other providers (Tidal, YouTube Music) are harder — no local automation surface.

## Public distribution
Currently personal/dev (ad-hoc signed, Spotify app in Development Mode).
To distribute via GitHub releases:
- Enable Hardened Runtime, sign with a Developer ID, and **notarize** (requires a paid
  Apple Developer account).
- Spotify's own limits are the harder problem: since February 2026 a development-mode app
  allows **5 users** and requires the owner to hold Premium, and extended quota mode is only
  offered to registered organizations with 250k+ MAU. So there is no path to a build others
  can just log into — each user has to register their own Client ID (which the README
  already walks through). That's a real constraint on this being "an app" rather than
  "source you build".
