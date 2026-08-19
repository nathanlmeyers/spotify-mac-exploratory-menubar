# Spotify Curator for Android

The phone half of the [Spotify Menu Bar Curator](../README.md): the same **Add** (to a target
playlist) and **Remove** (from the playlist you're listening to) actions, reachable from the
Pixel's **lock screen** while Spotify plays.

Same Spotify app registration, same Client ID, same redirect URI as the macOS build — so one
Spotify developer app serves both, and no dashboard change was needed.

## How it works

macOS reads and controls Spotify through ScriptingBridge. Android has a direct analogue: with
notification-listener access, `MediaSessionManager.getActiveSessions()` hands back a live
`MediaController` for `com.spotify.music`. That gives:

| | macOS | Android |
|---|---|---|
| Track / artist / duration | ScriptingBridge, polled 1 Hz | `MediaMetadata`, event-driven |
| Position | polled 1 Hz | `PlaybackState` *sample* (`position` + `lastPositionUpdateTime` + `speed`) — exact at any instant, **no polling** |
| Pause / skip | Apple event | local binder call (`transportControls`) |
| Playlist context + edits | Spotify Web API | Spotify Web API (identical) |

So the split is the same one the Mac uses: **local session for playback, Web API for playlist
edits**. `GET /me/player` supplies the `context.uri` that Remove needs in order to know *which*
playlist to remove from.

### Spotify's context extras

Spotify publishes its playback context in the media metadata under undocumented vendor keys:

```
com.spotify.music.extra.CONTEXT_URI   = spotify:playlist:2OsDQntXER7vmPoRH9RvpU
com.spotify.music.extra.CONTEXT_TITLE = crabhands
```

This is what Remove needs, and it arrives in the *same* `MediaMetadata` object as
`METADATA_KEY_MEDIA_ID` (which does carry `spotify:track:…`). Reading both from one object makes
them atomic by construction — the track and the playlist it came from cannot disagree, which is
the property the macOS app gets from its atomic `playbackSnapshot()` Apple event.

So `resolveActionTarget` reads locally and acts, and `GET /me/player` is only a fallback for when
the extras are absent. After the first track from a given playlist, a track change costs zero API
calls. The keys are undocumented, so every read is optional and falls back.

`MediaWatcher.localSnapshot()` reads `controller.metadata` **exactly once** per call: re-reading
it could straddle a track change and pair one song's URI with the next song's playlist.

### The lock screen

Android won't let a third party add buttons to Spotify's own media player, so the app posts its
own ongoing notification alongside it. Two non-obvious things make the buttons actually usable
there, both found by testing rather than by reading docs:

1. **A custom content view is required.** A standard notification hides its `addAction` buttons
   when collapsed, and the lock screen always renders collapsed. `res/layout/notification_curator.xml`
   is drawn as-is, so the buttons survive. Standard actions are attached too, for surfaces that
   ignore custom views.
2. **The channel must be `IMPORTANCE_DEFAULT`, not `IMPORTANCE_LOW`.** `LOW` is filed as
   "silent", and Android hides silent notifications from the lock screen — taking the buttons
   with them. The channel clears its sound, vibration and lights instead, so it is silent in
   practice while still being shown. (`DEFAULT` never produces a heads-up; that needs `HIGH`.)

Presses go to a `BroadcastReceiver`, which fires on a **locked** device without prompting for an
unlock. `setAuthenticationRequired` is deliberately never set.

The collapsed row uses `+ − »` glyphs rather than words so the track title gets the width. On a
lock screen the scarce resource is horizontal space and the important thing is reading *which
song* you're about to remove — a truncated title is how you delete the wrong one. Full labels
are in the expanded view and in `contentDescription`.

## Safety

The macOS rule — **no removal without a button press** — is enforced here the same way, by the
type system. Every layer that can delete requires a `UserRemovalIntent`, and its constructor is
private: the only ways to get one are the named factories in
`curation/UserRemovalIntent.kt`, each corresponding to a real button. Automated code cannot
fabricate one with an invented reason.

Kotlin has no file-private constructor (Swift's `fileprivate init`), so this restricts *what* can
be constructed rather than *who* may construct it. Adding a new removal reason means adding a
named factory in the one file whose whole job is to enumerate the gestures that may delete a song.

Beyond that, `DiscoveryLogic.mayRemoveFromSource` still gates every deletion: never move-delete
out of the target playlist, and never act on a source context that was resolved for a different
track.

## Discovery mode

Pauses ~400ms before each track's natural end so you can judge it: **+** adds to the target,
**−** removes from the playlist you're listening to, **»** skips. All three record the verdict and
advance. Turn it on in the app.

Much smaller than the macOS engine, for two reasons worth knowing before comparing them:

- **The Mac polls at 1 Hz; this is event-driven.** Most of the Swift engine's machinery (acting-tick
  counting, poll-driven pause, re-arming against drift) exists to cope with a position reading that
  can be a full second stale. `PlaybackState` gives exact position at any instant, so the hold is
  armed once and recomputed on real events.
- **Pause is a local binder call, not an Apple event.** The Mac needs a 1300ms lead to beat
  Apple-event latency; 400ms is enough here, so the song plays essentially to its end.

Every rule that decides what gets skipped or deleted is ported exactly: auto-skip **only skips and
never deletes**, loop protection stops a sweep that has cycled, a judged URI is never re-prompted,
and a hold only commits on a snapshot whose identity matches the track intended for review.

The locality guard (`MediaWatcher.isPlaybackLocal`) uses `PlaybackInfo.getPlaybackType()` rather
than an API call. Spotify keeps a MediaSession alive even when only remote-controlling a Connect
speaker, so the session's existence proves nothing — but LOCAL vs REMOTE does, and a pause must
never silence another room. When the type is unknown *and* a session is actively playing, that's
treated as local, mirroring the macOS fallback: being stricter would make discovery silently never
fire, which reads as a broken feature rather than a careful one.

## Build & run

Requires the Android SDK (platform 36, build-tools 36+) and JDK 17+.

```sh
cp local.properties.example local.properties     # then fill in sdk.dir + spotify.clientId
./gradlew :app:installDebug
adb shell am start -n com.nathanlmeyers.spotifycurator/.ui.MainActivity
adb logcat -s SpotifyCurator                     # watch gestures and API calls live
```

`local.properties` is gitignored and holds both the SDK path and `spotify.clientId` — the same
per-developer-secret pattern as the Mac's `Secrets.xcconfig`.

Not distributed through the Play Store, and won't be: since May 2025 Spotify only grants Web API
quota extensions to registered organisations running a launched service with ≥250k MAU. Without
one the app is stuck in Development Mode, where only 25 allowlisted Spotify accounts can log in.

## On the phone, once

1. **Notification access** — Settings deep link is in the app's Setup card. Needed to read
   Spotify's media session. On Android 13+ a sideloaded app may need ⋮ → *Allow restricted
   settings* on the app's info page before this toggle can be flipped.
2. **Notifications permission** — prompted on first launch.
3. **Unrestricted battery** — so Android doesn't suspend the curator during a long listen.
4. **Log in with Spotify**, then **pick a target playlist**.
5. Flip **Curator on**.

## Layout

```
api/         SpotifyApi (Web API client), RateLimit, Http     ← ports of API/*.swift
auth/        SpotifyAuth (PKCE), Pkce, TokenStore             ← ports of Auth/*.swift
curation/    CurationEngine, UserRemovalIntent                ← port of AppModel + SpotifyProvider
discovery/   DiscoveryEngine, DiscoveryLogic (pure)           ← port of Discovery/*.swift
media/       MediaWatcher, MediaMetadataMapping (pure),
             NotificationAccessStub                           ← the ScriptingBridge analogue
model/       Models                                           ← port of Models/Models.swift
notify/      CuratorNotification, ActionReceiver              ← the lock-screen surface
service/     CuratorService (foreground)
state/       Settings, ReviewHistory                          ← ports of State/*.swift
ui/          MainActivity (Compose)
```

Durations and positions are **milliseconds** throughout, where the Swift uses `Double` seconds:
Android's media APIs are millisecond-native, and the Discovery hold wants integer millis rather
than accumulated floating-point seconds.

## Tests

```sh
./gradlew :app:testDebugUnitTest
```

40 tests over the pure logic — `DiscoveryLogicTest` and `RateLimitTest` are ports of their Swift
counterparts; `MediaMetadataMappingTest` is new, covering position extrapolation across seek,
pause, speed and missing-timestamp cases, plus URI classification. The mapping layer is kept free
of `android.media.*` types for exactly this reason, the way `LocalSpotifyMapping.swift` is kept
free of ScriptingBridge.
