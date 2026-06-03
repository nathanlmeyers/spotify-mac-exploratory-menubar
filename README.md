# Spotify Menu Bar Curator

A macOS menu-bar app for curating Spotify *as you listen*. Click the icon to see the
current song with **Add** (to a target playlist) and **Remove** (from the playlist
you're listening to) controls, transport, and a seek scrubber. A **Discovery mode**
(Phase 2) will hold playback at the end of each song so you can triage new releases
(e.g. a "Crab Hands" new-releases playlist) into keepers.

- **Playback** is read/controlled **locally** via ScriptingBridge against the Spotify
  desktop app — no Premium required.
- **Playlist edits** go through the **Spotify Web API** (OAuth 2.0 + PKCE; tokens in the
  Keychain).
- Built behind a `MusicProvider` abstraction so other services (Apple Music, …) can be
  added later — see `ROADMAP.md`.

## Requirements

- macOS 13+
- Xcode 15+ (developed with Xcode 26)
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`) — the project
  is generated from `project.yml`
- The **Spotify desktop app** installed and signed in

## One-time setup: your Spotify Client ID

The app talks to the Web API as a Spotify "app" that **you** register (free):

1. Go to <https://developer.spotify.com/dashboard> → **Create app**.
2. Set the **Redirect URI** to exactly:
   ```
   spotifymenubar://callback
   ```
3. Copy the **Client ID**.
4. Copy `Secrets.example.xcconfig` → `Secrets.xcconfig` and paste your Client ID:
   ```
   SPOTIFY_CLIENT_ID = xxxxxxxxxxxxxxxxxxxxxxxx
   ```
   `Secrets.xcconfig` is gitignored. (PKCE is used, so there's **no client secret**.)
5. Under your app's **User Management**, add your own Spotify account's email
   (Development Mode allows up to 25 allowlisted users).

## Build & run

```sh
xcodegen generate
xcodebuild -project SpotifyMenuBar.xcodeproj -scheme SpotifyMenuBar -configuration Debug build
# Launch the built app (path is printed in the build output under Build/Products):
open ~/Library/Developer/Xcode/DerivedData/SpotifyMenuBar-*/Build/Products/Debug/SpotifyMenuBar.app
```

On first run:
- macOS will ask permission to **control Spotify** (Automation/TCC) — allow it.
- Click the menu-bar icon → **Log in with Spotify** (opens your browser once).

> The custom URL scheme is registered with macOS when the app is first launched. If the
> login redirect doesn't come back to the app, run:
> `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /path/to/SpotifyMenuBar.app`

## Status

- **Phase 1 (this build):** login, now-playing popover (art, scrubber, transport +
  shuffle), settings target picker (editable playlists only), Add/Remove with gray-out
  states, "move on add", duplicate-prevention, edge-content handling.
- **Phase 2 (implemented):** Discovery mode — computed precise-pause hold (~300ms before a
  track's natural end, with a crossfade/slip fallback), combinable alerts (auto-open
  non-activating panel / icon pulse / sound), and auto-skip rules (already-in-target,
  already-reviewed) with loop protection. Toggle it on in Settings. *Pending live
  verification against the Web API (needs your Client ID).*
- **Phase 3:** notarized GitHub distribution; see `ROADMAP.md`.
