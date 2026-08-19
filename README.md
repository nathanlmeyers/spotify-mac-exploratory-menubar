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
| **Artists to Follow** | Lists the artists you demonstrably listen to but never followed, ranked from your own top artists and top tracks, with Play / Follow / Not interested on each row. |
| **Clear Your Episodes** | Empties Spotify's saved-podcast-episodes library, which no Spotify client offers a way to bulk-clear. |

Design notes:

- **Playback** is read/controlled **locally** via ScriptingBridge against the Spotify
  desktop app — no Premium required for transport.
- **Playlist edits** go through the **Spotify Web API** (OAuth 2.0 + PKCE; tokens in the
  Keychain).
- **Nothing is ever deleted without a button press.** Playlist and library removals require
  a `UserRemovalIntent`, which only a button handler in `AppModel` can construct — so an
  automated deletion is a compile error, not a comment someone can read past.

There is also an **Android build** in [`android/`](android/README.md), which puts the same
Add/Remove on the Pixel lock screen. It shares this repo's Spotify app registration and Client ID.

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

## Artists to Follow

Right-click the menu-bar icon → **Artists to Follow…** (or the person-plus button in the
panel, or **Settings ▸ Artists to follow ▸ Open…**). It lists artists you listen to but
haven't followed, best first, with the evidence for each — *"#3 in your top artists (all
time) · 5 songs in your top tracks"*.

Each row has **Play**, a link to their Spotify page, **Follow**, and **Not interested**.

Three things worth knowing:

- **The suggestions come from your own history, not from Spotify's recommender.** February
  2026 removed `/recommendations` and `/artists/{id}/related-artists`, so "artists similar to
  ones you like" is no longer buildable by anyone outside Spotify. What's left is better for
  this purpose anyway: every suggestion is an artist you already played, so you can check it.
  Ranking blends your top artists and the artists credited on your top tracks across all three
  time ranges, weighting a lead credit above a guest verse and enduring taste above a recent
  binge. There's no popularity anywhere in it — that field was removed too.
- **Play hands the choice to Spotify.** `GET /artists/{id}/top-tracks` was removed, so nothing
  can ask the API for an artist's biggest song. The button sends the bare `spotify:artist:` URI
  to the desktop app through AppleScript, and Spotify starts them with their most-played track.
  No Premium, no API quota.
- **"Not interested" changes nothing on your Spotify account.** It writes an id to this app's
  own `suggestions.json` and that's all — nobody is unfollowed and nothing is deleted. It's
  reversible: Undo in the window, or **Settings ▸ Artists to follow ▸ Hidden artists**.

A refresh costs about 40 requests (six top-list reads, your followed artists, then one artist
lookup each for artwork — the batch endpoint for that was removed too, so there's a cap of 30
per refresh and the footer says when it applied). Results are cached for six hours, so
reopening the window is free.

Its assumptions have a probe too — including the one that decides whether the play button can
exist at all:

```sh
./scripts/probe-artist-suggestions.py            # read-only
./scripts/probe-artist-suggestions.py --play-test  # briefly takes over playback, then restores it
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
- **Artists to Follow** (right-click ▸ Artists to Follow…): its own window; reads and additive
  follows only, and "Not interested" is local.
- **Phase 3:** notarized GitHub distribution; see `ROADMAP.md`.

> **Upgrading?** Scopes can't be widened by a token refresh, so a build that adds one needs a
> single **log out and log back in**. Settings will say so when it applies — currently for
> Clear Your Episodes (`user-library-*`), New From Followed (`user-follow-read`), and Artists
> to Follow (`user-top-read`, `user-follow-modify`). Everything else keeps working meanwhile.
