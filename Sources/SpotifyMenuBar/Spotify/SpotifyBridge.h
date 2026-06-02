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

/// Spotify URI of the current item, e.g. "spotify:track:...", ":episode:", ":local:", ":ad:".
@property (nonatomic, readonly, nullable) NSString *currentTrackURI;
@property (nonatomic, readonly, nullable) NSString *currentTrackName;
@property (nonatomic, readonly, nullable) NSString *currentTrackArtist;
@property (nonatomic, readonly, nullable) NSString *currentTrackAlbum;
@property (nonatomic, readonly, nullable) NSString *currentArtworkURL;

/// Track length in seconds (normalized; Spotify has historically reported ms).
@property (nonatomic, readonly) double durationSeconds;
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

/// Launches Spotify.app if it is not running (used by the "Open Spotify" affordance).
- (void)activateSpotify;

@end

NS_ASSUME_NONNULL_END
