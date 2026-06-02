# Roadmap

## Phase 2 — Discovery mode
Computed precise-pause hold (`duration − position`, fire ~300ms early to beat the
Apple-event latency + auto-advance race; recompute on seek/pause; 0:00 fallback for
crossfade). Combinable alerts (auto-open panel / badge / sound). Auto-skip rules
(already-in-target [+ remove from source], already-reviewed) with skip-loop protection
("nothing new to review"). Settings already exist; engine to be implemented in
`Discovery/DiscoveryEngine.swift`.

## Apple Music + multi-provider support
The app is built behind the `MusicProvider` protocol (`Provider/MusicProvider.swift`)
with `SpotifyProvider` as the first implementation. Add an `AppleMusicProvider`:
- Playback read/control + **playlist edits** via the `Music.app` scripting interface
  (unlike Spotify, Apple Music *can* edit playlists locally) or MusicKit.
- No OAuth/PKCE needed if using local scripting; MusicKit would use a different auth.
Other providers (Tidal, YouTube Music) are harder — no local automation surface.

## Public distribution
Currently personal/dev (ad-hoc signed, Spotify app in Development Mode, ≤25 users).
To distribute via GitHub releases:
- Enable Hardened Runtime, sign with a Developer ID, and **notarize** (requires a paid
  Apple Developer account).
- Request a **Spotify quota extension** to allow more than 25 users to log in.
