//
//  SpotifyBridge.h
//  Thin Objective-C wrapper around the Spotify ScriptingBridge interface.
//  The ObjC cast to the generated SBApplication subclass works reliably here,
//  whereas the equivalent Swift downcast does not. Swift talks to this shim.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SpotifyPlayerState) {
    SpotifyPlayerStateStopped = 0,
    SpotifyPlayerStatePlaying = 1,
    SpotifyPlayerStatePaused  = 2,
};

@interface SpotifyBridge : NSObject

/// Whether Spotify.app is currently running. We never send events when it is not,
/// to avoid auto-launching Spotify.
@property (nonatomic, readonly) BOOL isRunning;

/// A single, internally-consistent snapshot of the current track, or nil when Spotify
/// isn't running / nothing is playing. All track-identity fields come from ONE atomic read
/// so they can never straddle a track change (the cause of the "wrong song" menu-bar bug).
///
/// Keys (see SpotifyTrackKey in LocalSpotifyMapping.swift):
///   "id"          NSString  — the track URI (gate; absent/empty ⇒ method returns nil)
///   "name"        NSString  — present only when non-empty
///   "artist"      NSString  — present only when non-empty
///   "album"       NSString  — present only when non-empty
///   "artworkUrl"  NSString  — present only when non-empty
///   "durationRaw" NSNumber  — RAW track duration; normalized (ms↔s) on the Swift side
- (nullable NSDictionary<NSString *, id> *)currentTrackSnapshot;

/// Everything one poll needs, in a SINGLE call: player state, the atomic track snapshot,
/// position, and shuffle. Returns nil when Spotify isn't running / playback is stopped /
/// there's no usable track.
///
/// Exists so the caller makes one hop onto the Apple-event queue per tick instead of four.
/// Every one of those hops is a blocking AESendMessage, so fewer hops means a smaller window
/// in which a dropped reply can wedge the connection — and it keeps the reads tightly grouped
/// in time. Ordered state → snapshot → position so position is sampled closest to the identity
/// it is paired with.
///
/// Keys: all of `currentTrackSnapshot`'s, plus (see SpotifyPlaybackKey in LocalSpotifyMapping):
///   "playerState" NSNumber — SpotifyPlayerState
///   "position"    NSNumber — playback position, seconds
///   "shuffling"   NSNumber — BOOL
- (nullable NSDictionary<NSString *, id> *)playbackSnapshot;

/// Playback position in seconds. Settable (this is our seek control).
@property (nonatomic) double playerPosition;
@property (nonatomic, readonly) SpotifyPlayerState playerState;
@property (nonatomic) BOOL shuffling;

- (void)playpause;
- (void)play;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
- (void)seekTo:(double)seconds;

/// Start playback of a Spotify URI.
///
/// Wraps the sdef's `playTrack:inContext:`, which despite the name accepts an **artist** URI
/// as well as a track one — verified against the running app: sending `spotify:artist:<id>`
/// starts that artist beginning with their most-played song. That is the whole reason the
/// "Artists to Follow" play button can exist: February 2026 removed
/// `GET /artists/{id}/top-tracks` and the `popularity` field, so the Web API can no longer say
/// which song is an artist's biggest — but Spotify's own client still knows.
///
/// Local Apple event, so it needs no Premium subscription and costs no API quota.
- (void)playURI:(NSString *)uri;

@end

NS_ASSUME_NONNULL_END
