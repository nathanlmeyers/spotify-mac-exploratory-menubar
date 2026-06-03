//
//  SpotifyBridge.m
//

#import "SpotifyBridge.h"
#import <AppKit/AppKit.h>
#import "SpotifyScripting.h"

static NSString *const kSpotifyBundleID = @"com.spotify.client";

@interface SpotifyBridge ()
@property (nonatomic, strong, nullable) SpotifyScriptingApplication *app;
@end

@implementation SpotifyBridge

// Lazily create the SBApplication. Creating it does NOT launch Spotify; only
// sending it messages would, so every accessor below guards on `isRunning`.
- (nullable SpotifyScriptingApplication *)app {
    if (_app == nil) {
        _app = (SpotifyScriptingApplication *)[SBApplication applicationWithBundleIdentifier:kSpotifyBundleID];
    }
    return _app;
}

- (BOOL)isRunning {
    NSArray<NSRunningApplication *> *running =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:kSpotifyBundleID];
    return running.count > 0;
}

- (nullable SpotifyScriptingTrack *)currentTrackSafe {
    if (!self.isRunning) { return nil; }
    @try {
        return self.app.currentTrack;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

- (nullable NSString *)currentTrackURI {
    SpotifyScriptingTrack *t = [self currentTrackSafe];
    if (t == nil) { return nil; }
    @try {
        NSString *uri = [t id];
        return (uri.length > 0) ? uri : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

- (nullable NSString *)currentTrackName {
    return [self currentTrackSafe].name;
}

- (nullable NSString *)currentTrackArtist {
    return [self currentTrackSafe].artist;
}

- (nullable NSString *)currentTrackAlbum {
    return [self currentTrackSafe].album;
}

- (nullable NSString *)currentArtworkURL {
    return [self currentTrackSafe].artworkUrl;
}

- (double)durationSeconds {
    SpotifyScriptingTrack *t = [self currentTrackSafe];
    if (t == nil) { return 0; }
    NSInteger raw = t.duration;
    // Normalize: Spotify's dictionary says "seconds" but has historically
    // returned milliseconds. Anything implausibly large is treated as ms.
    return (raw > 10000) ? (raw / 1000.0) : (double)raw;
}

- (double)playerPosition {
    if (!self.isRunning) { return 0; }
    @try {
        return self.app.playerPosition;
    } @catch (__unused NSException *e) {
        return 0;
    }
}

- (void)setPlayerPosition:(double)playerPosition {
    if (!self.isRunning) { return; }
    @try {
        self.app.playerPosition = playerPosition;
    } @catch (__unused NSException *e) {}
}

- (SpotifyPlayerState)playerState {
    if (!self.isRunning) { return SpotifyPlayerStateStopped; }
    @try {
        switch (self.app.playerState) {
            case SpotifyScriptingEPlSPlaying: return SpotifyPlayerStatePlaying;
            case SpotifyScriptingEPlSPaused:  return SpotifyPlayerStatePaused;
            case SpotifyScriptingEPlSStopped:
            default:                          return SpotifyPlayerStateStopped;
        }
    } @catch (__unused NSException *e) {
        return SpotifyPlayerStateStopped;
    }
}

- (BOOL)shuffling {
    if (!self.isRunning) { return NO; }
    @try { return self.app.shuffling; }
    @catch (__unused NSException *e) { return NO; }
}

- (void)setShuffling:(BOOL)shuffling {
    if (!self.isRunning) { return; }
    @try { self.app.shuffling = shuffling; }
    @catch (__unused NSException *e) {}
}

- (void)playpause      { if (self.isRunning) { @try { [self.app playpause]; }      @catch (__unused NSException *e) {} } }
- (void)play           { if (self.isRunning) { @try { [self.app play]; }           @catch (__unused NSException *e) {} } }
- (void)pause          { if (self.isRunning) { @try { [self.app pause]; }          @catch (__unused NSException *e) {} } }
- (void)nextTrack      { if (self.isRunning) { @try { [self.app nextTrack]; }      @catch (__unused NSException *e) {} } }
- (void)previousTrack  { if (self.isRunning) { @try { [self.app previousTrack]; }  @catch (__unused NSException *e) {} } }

- (void)seekTo:(double)seconds {
    [self setPlayerPosition:seconds];
}

- (void)activateSpotify {
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kSpotifyBundleID];
    if (url != nil) {
        NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:cfg completionHandler:nil];
    }
}

@end
