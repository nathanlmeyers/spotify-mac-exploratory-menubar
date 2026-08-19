# Spotify Menu Bar

An open-source macOS menu-bar toolkit for Spotify power users — a home for the features
Spotify doesn't ship. It lives in your menu bar, so it can do work continuously in the
background instead of only when you have a window open.

**What it does today:**

| | |
|---|---|
| **Curate as you listen** | Click the icon for the current song with **Add** (to a target playlist) and **Remove** (from the playlist you're listening to), plus transport and a seek scrubber. |
| **Discovery mode** | Holds playback just before each song ends so you can triage a new-releases playlist into keepers without it auto-advancing. |
| **New From Followed** | Checks your followed artists once a day and collects anything they released — or were featured on — into a playlist. A free, local replacement for a paid release-radar service. |
| **Clear Your Episodes** | Empties Spotify's saved-podcast-episodes library, which no Spotify client offers a way to bulk-clear. |

Design notes:

- **Playback** is read/controlled **locally** via ScriptingBridge against the Spotify
  desktop app — no Premium required for transport.
- **Playlist edits** go through the **Spotify Web API** (OAuth 2.0 + PKCE; tokens in the
  Keychain).
- **Nothing is ever deleted without a button press.** Playlist and library removals require
  a `UserRemovalIntent`, which only a button handler in `AppModel` can construct — so an
  automated deletion is a compile error, not a comment someone can read past.

## Requirements

- macOS 13+
- Xcode 15+ (developed with Xcode 26)
- [XcodeGen](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`) — the project
  is generated from `project.yml`
- The **Spotify desktop app** installed and signed in
- A **Spotify Premium** subscription on the account that registers the app (required for
  Web API development mode since February 2026)

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
5. Under your app's **User Management**, add your own Spotify account's email.

## Build & run

**Quick start** — one command scaffolds `Secrets.xcconfig` if needed, generates the
project, builds Debug, and launches the app:

```sh
./scripts/run.sh
```

(On a fresh checkout it copies `Secrets.example.xcconfig` → `Secrets.xcconfig`; fill in
your Client ID per the step above, then re-run.)

Or do it manually:

```sh
xcodegen generate
xcodebuild -project SpotifyMenuBar.xcodeproj -scheme SpotifyMenuBar -configuration Debug build
# Launch the built app (path is printed in the build output under Build/Products):
open ~/Library/Developer/Xcode/DerivedData/SpotifyMenuBar-*/Build/Products/Debug/SpotifyMenuBar.app
```

Run the tests with:

```sh
xcodebuild -project SpotifyMenuBar.xcodeproj -scheme SpotifyMenuBar -configuration Debug test
```

The test target has no app host and compiles only the pure-logic sources listed in
`project.yml`. That's why decision logic is deliberately split out of its stateful owner —
`DiscoveryLogic` out of `DiscoveryEngine`, `NewReleaseLogic` out of `NewReleaseScanner`,
`RateLimit` out of `SpotifyWebAPI`. **New logic you want tested must be a pure type and must
be added to that source list.**

On first run:
- macOS will ask permission to **control Spotify** (Automation/TCC) — allow it.
- Click the menu-bar icon → **Log in with Spotify** (opens your browser once).

> The custom URL scheme is registered with macOS when the app is first launched. If the
> login redirect doesn't come back to the app, run:
> `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /path/to/SpotifyMenuBar.app`

## New From Followed

Turn it on in **Settings ▸ New releases**, pick a destination (or press **Create "New From
Followed"**), and it sweeps once a day while the app is running. It only ever adds.

Filters: include/exclude features, main-artist-only, skip remixes, skip compilations, and
how far back a release still counts as new.

Two things worth knowing about how it works:

- **The first run is cheap on purpose.** A watermark is stamped when you enable it and
  nothing released earlier is ever added, so switching it on doesn't sweep in years of back
  catalogue. Changing a filter has no visible effect until you press **Rescan from scratch**,
  because already-considered albums are cached and never reconsidered. Rescanning empties that
  cache and sweeps your whole look-back window again; it doesn't move the watermark, so a
  filter you loosen today still picks up last week's releases. Pointing it at a different
  playlist does the same, so the new destination fills up instead of starting empty.
- **It catches up after the Mac is off.** The last completed scan is recorded on disk, so a
  scan that was due while the machine was asleep simply runs when the app next starts. If the
  gap is longer than your look-back window, the next scan is a **catch-up**: it widens the
  window back to the last scan and sweeps every artist in one run, so a holiday doesn't
  silently cost you a week of releases. It never reaches back past the day you switched the
  feature on.
- **Features take a few days to sweep.** `GET /artists/{id}/albums` caps `limit` at 10 and
  doesn't return `appears_on` newest-first, so finding a new guest appearance means crawling
  an artist's whole guest catalogue. Each artist gets a fixed slot in a 7-day rotation to
  keep the daily request cost flat — which is why the look-back window is never shorter than
  a week when features are on. A very prolific guest artist takes several turns to cover:
  each turn crawls a capped number of pages and the next one resumes where it stopped. Because
  that can take weeks, guest releases are judged against a wider, per-artist window — reaching
  back to the last time that artist's catalogue was fully swept — so a feature found late is
  still added rather than arriving too old to count. It never reaches past the day you
  switched the feature on.
- **Switching it off stops the sweep.** If a scan is running when you turn the toggle off, it
  stops at the artist it's on rather than finishing; turning it back on picks up there.

There's a read-only probe for the API assumptions behind all of this:

```sh
./scripts/probe-new-releases.py
```

## Status

- **Phase 1:** login, now-playing popover (art, scrubber, transport + shuffle), settings
  target picker (editable playlists only), Add/Remove with gray-out states, "move on add",
  duplicate-prevention, edge-content handling.
- **Phase 2:** Discovery mode — computed precise-pause hold (~300ms before a track's natural
  end, with a crossfade/slip fallback), combinable alerts (auto-open non-activating panel /
  icon pulse / sound), and auto-skip rules (already-in-target, already-reviewed) with loop
  protection.
- **Clear Your Episodes** (Settings ▸ Library): **irreversible** — the only record of what
  was removed is the episode URIs in the debug log.
- **New From Followed** (Settings ▸ New releases).
- **Phase 3:** notarized GitHub distribution; see `ROADMAP.md`.

> **Upgrading?** Scopes can't be widened by a token refresh, so a build that adds one needs a
> single **log out and log back in**. Settings will say so when it applies — currently for
> Clear Your Episodes (`user-library-*`) and New From Followed (`user-follow-read`).
> Everything else keeps working meanwhile.
