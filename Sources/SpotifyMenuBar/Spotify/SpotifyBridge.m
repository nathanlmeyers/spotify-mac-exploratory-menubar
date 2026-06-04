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

// `properties` is a Standard-Suite scripting attribute that SBObject resolves at runtime but
// does not declare in its public header. Declare it so the single-event atomic snapshot in
// `currentTrackSnapshot` compiles; if Spotify doesn't honor it the call yields nil/empty and
// we fall back to per-field reads.
@interface SBObject (SMBPropertiesSnapshot)
- (nullable NSDictionary *)properties;
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

/// First non-empty string among `keys` in `props` (robust to e.g. "artworkUrl" vs
/// "artwork url" depending on how ScriptingBridge maps the property on this OS/Spotify).
static NSString *_Nullable SBFirstString(NSDictionary *props, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id v = props[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            return (NSString *)v;
        }
    }
    return nil;
}

- (nullable NSDictionary<NSString *, id> *)currentTrackSnapshot {
    if (!self.isRunning) { return nil; }

    // The track's `id` is the Standard-Suite item identifier (a method, not an sdef
    // property) and is NOT reliably in `-properties`, so it must be read separately. That
    // means the id read and the field read can themselves straddle a track flip — so we
    // bracket the field read with an id-before / id-after equality check and retry. A flip
    // away-and-back (A→B→A) within one ~ms snapshot is physically impossible here, so a
    // matching pair guarantees the fields belong to that one track.
    static const NSUInteger maxAttempts = 3;
    for (NSUInteger attempt = 0; attempt < maxAttempts; attempt++) {
        @try {
            SpotifyScriptingTrack *t = self.app.currentTrack;   // resolve the specifier ONCE
            if (t == nil) { return nil; }

            NSString *idBefore = nil;
            @try { idBefore = [t id]; } @catch (__unused NSException *e) {}
            if (idBefore.length == 0) { return nil; }           // stopped / nothing playing

            NSString *name = nil, *artist = nil, *album = nil, *artwork = nil;
            NSNumber *durationRaw = nil;

            // Primary: one atomic Apple event captures every track attribute at one instant.
            NSDictionary *props = nil;
            @try { props = [(SBObject *)t properties]; } @catch (__unused NSException *e) {}
            if ([props isKindOfClass:[NSDictionary class]] && props.count > 0) {
                name    = SBFirstString(props, @[@"name"]);
                artist  = SBFirstString(props, @[@"artist"]);
                album   = SBFirstString(props, @[@"album"]);
                artwork = SBFirstString(props, @[@"artworkUrl", @"artwork url", @"artworkURL"]);
                id dur = props[@"duration"];
                if ([dur isKindOfClass:[NSNumber class]]) { durationRaw = dur; }
            } else {
                // Fallback: `-properties` unsupported/empty on this Spotify build. The
                // id-bracket below still guarantees these per-field reads are coherent.
                @try { name    = t.name; }       @catch (__unused NSException *e) {}
                @try { artist  = t.artist; }     @catch (__unused NSException *e) {}
                @try { album   = t.album; }      @catch (__unused NSException *e) {}
                @try { artwork = t.artworkUrl; } @catch (__unused NSException *e) {}
                @try { durationRaw = @(t.duration); } @catch (__unused NSException *e) {}
            }

            NSString *idAfter = nil;
            @try { idAfter = [t id]; } @catch (__unused NSException *e) {}

            if (idAfter.length > 0 && [idBefore isEqualToString:idAfter]) {
                NSMutableDictionary *snap = [NSMutableDictionary dictionaryWithCapacity:6];
                snap[@"id"] = idBefore;
                if (name.length > 0)    { snap[@"name"]    = name; }
                if (artist.length > 0)  { snap[@"artist"]  = artist; }
                if (album.length > 0)   { snap[@"album"]   = album; }
                if (artwork.length > 0) { snap[@"artworkUrl"] = artwork; }
                if (durationRaw != nil) { snap[@"durationRaw"] = durationRaw; }
                return snap;
            }
            // ids differ → a flip landed inside this read; retry against fresh state.
        } @catch (__unused NSException *e) {
            return nil;
        }
    }
    return nil;   // never stabilized — skip this tick; the next one (post-flip) succeeds.
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
