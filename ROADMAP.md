# Roadmap

## Phase 2 — Discovery mode
Computed precise-pause hold (`duration − position`, fire ~300ms early to beat the
Apple-event latency + auto-advance race; recompute on seek/pause; 0:00 fallback for
crossfade). Combinable alerts (auto-open panel / badge / sound). Auto-skip rules
(already-in-target [+ remove from source], already-reviewed) with skip-loop protection
("nothing new to review"). Settings already exist; engine to be implemented in
`Discovery/DiscoveryEngine.swift`.

## Android (`android/`)
Add/Remove/Skip on the Pixel lock screen, via an ongoing notification with a custom collapsed
layout. Shipped: auth, Web API, rate-limit backoff, source resolution, curation actions, the
`UserRemovalIntent` safety gate, media-session watching, the notification, and Discovery mode
(end-of-track hold, held-review verdicts, auto-skip rules, `ReviewHistory`).

Two Android-specific wins over the macOS implementation:
- Spotify publishes `CONTEXT_URI` in its media metadata, so the track URI and the playlist it
  came from are read from **one atomic object with no API call** — the property the Mac gets
  from its atomic `playbackSnapshot()`. After the first track from a playlist, a track change
  costs zero Web API requests.
- `PlaybackState` gives exact position and `transportControls.pause()` is a local binder call,
  so the hold lead is 400ms rather than the Mac's 1300ms.

Still pending: a boot receiver, notification artwork, and the "Clear Your Episodes" action.
See `android/README.md`.

## More toolkit features
The app is a home for Spotify features Spotify doesn't ship. Shipped so far: Discovery
mode, New From Followed, Clear Your Episodes, Artists to Follow. Candidates:
- Notify on a new find, and a per-artist mute list for the release radar.
- Bulk playlist dedupe.
- "What playlist is this song in?" across your library.

`SuggestedArtistStore.notInterested` is already a per-artist mute list in everything but
name; the radar's version could share it or copy the shape rather than inventing a third
dismissal mechanism.

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
