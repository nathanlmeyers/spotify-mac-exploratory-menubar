import SwiftUI

/// The popover / hold-panel contents: now-playing, scrubber, transport, and curation.
/// When `model.reviewState == .held`, it renders the discovery "judge" layout
/// (Remove / Add / Skip) regardless of `mode`. `mode` only controls chrome:
/// `.hold` adds a material card background for the borderless floating panel.
struct NowPlayingView: View {
    enum Mode { case standard, hold }
    var mode: Mode = .standard
    @EnvironmentObject var model: AppModel

    private var heldTrack: HeldTrack? {
        if case .held(let h) = model.reviewState { return h }
        return nil
    }

    var body: some View {
        content
            .padding(14)
            .frame(width: 340)
            .background {
                if mode == .hold {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.35)))
                }
            }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // When a track is shown, the gear lives inline on the title row (see
            // `trackHeader`); the standalone top bar is only for the states without one.
            if let held = heldTrack {
                heldPlayer(held)
            } else if !model.hasClientID {
                topBar
                clientIDMissing
            } else if !model.isAuthorized {
                topBar
                loggedOut
            } else if let np = model.nowPlaying {
                player(np)
            } else {
                topBar
                idleState
            }
        }
    }

    /// Settings gear, right-aligned on its own row — used in states with no track header.
    private var topBar: some View {
        HStack {
            Spacer()
            settingsGear
        }
    }

    /// The settings gear button (opens the Settings window via notification).
    private var settingsGear: some View {
        Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
            Image(systemName: "gearshape")
        }.help("Settings").buttonStyle(.borderless)
    }

    // MARK: Non-player states

    private var clientIDMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Set up required", systemImage: "exclamationmark.triangle").font(.headline)
            Text("Add your Spotify **Client ID** to `Secrets.xcconfig` and rebuild. See the README.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var loggedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify Menu Bar").font(.headline)
            Text("Log in to read your playback and curate playlists.")
                .font(.callout).foregroundStyle(.secondary)
            Button { model.login() } label: {
                Label("Log in with Spotify", systemImage: "person.crop.circle")
            }.buttonStyle(.borderedProminent)
            if let err = model.auth.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isSpotifyRunning {
                Label("Nothing playing", systemImage: "pause.circle").font(.headline).foregroundStyle(.secondary)
                Text("Start a song in Spotify.").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("Spotify isn't running", systemImage: "bolt.horizontal.circle").font(.headline).foregroundStyle(.secondary)
                Button { model.openSpotify() } label: {
                    Label("Open Spotify", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    // MARK: Standard player

    private func player(_ np: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            trackHeader(np, fromName: model.source.playlistName)
            Scrubber(np: np) { model.seek(to: $0) }
            transport(np)
            curationNormal
            statusLine
        }
    }

    // MARK: Held (discovery judge) player

    private func heldPlayer(_ held: HeldTrack) -> some View {
        // displayTrack already resolves to the held snapshot (merged with live playback when
        // it's still the same track); the ?? only discharges the optional type.
        let np = model.displayTrack ?? held.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            Label("Held for review", systemImage: "pause.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
            trackHeader(np, fromName: held.sourceName)
            Scrubber(np: np) { model.seek(to: $0) }
            HStack {
                Spacer()
                Button { model.togglePlayPause() } label: {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                }.help("Play / pause to re-listen").buttonStyle(.borderless)
                Spacer()
            }
            curationHeld(held)
            statusLine
        }
    }

    // MARK: Shared pieces

    private func trackHeader(_ np: NowPlaying, fromName: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            artwork(np.artworkURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(np.name.isEmpty ? "—" : np.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    settingsGear
                }
                Text(model.artistText(for: np)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(fromToLine(from: fromName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func artwork(_ url: URL?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Image(systemName: "music.note").foregroundStyle(.secondary) }
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fromToLine(from: String?) -> String {
        let from = from ?? "—"
        let to = model.settings.targetPlaylistName ?? "Set target"
        return "From \(from)  →  \(to)"
    }

    private func transport(_ np: NowPlaying) -> some View {
        HStack(spacing: 18) {
            Button { model.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(np.isShuffling ? Color.accentColor : .primary)
            }.help("Shuffle")
            Spacer()
            Button { model.previous() } label: { Image(systemName: "backward.fill") }.help("Previous")
            Button { model.togglePlayPause() } label: {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }.help(np.isPlaying ? "Pause" : "Play")
            Button { model.next() } label: { Image(systemName: "forward.fill") }.help("Next")
            Spacer()
            Image(systemName: "shuffle").opacity(0)   // counterweight to keep play/pause centered
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private var curationNormal: some View {
        HStack(spacing: 10) {
            curationButton("Remove", icon: "minus.circle.fill", tint: .red,
                           disabled: !model.canRemoveFromSource,
                           help: model.removeDisabledReason ?? "Remove from \(model.source.playlistName ?? "source")") {
                model.removeCurrentFromSource()
            }
            curationButton("Add", icon: "plus.circle.fill", tint: .green,
                           disabled: !model.canAdd,
                           help: model.addDisabledReason ?? "Add to \(model.settings.targetPlaylistName ?? "target")") {
                model.addCurrentToTarget()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func curationHeld(_ held: HeldTrack) -> some View {
        let canRemove = model.canRemoveFromSource
        return HStack(spacing: 8) {
            curationButton("Remove", icon: "minus.circle.fill", tint: .red,
                           disabled: !canRemove,
                           help: canRemove ? "Remove from source" : (model.removeDisabledReason ?? "Can't remove")) {
                model.heldRemove()
            }
            curationButton("Add", icon: "plus.circle.fill", tint: .green,
                           disabled: !held.canAdd,
                           help: held.canAdd ? "Add to \(held.targetName ?? "target")" : (model.addDisabledReason ?? "Can't add")) {
                model.heldAdd()
            }
            curationButton("Next", icon: "forward.fill", tint: .secondary,
                           help: "Skip to the next track without adding or removing") {
                model.heldSkip()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func curationButton(_ title: String, icon: String, tint: Color,
                                disabled: Bool = false, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .tint(tint)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder private var statusLine: some View {
        if let status = model.statusMessage {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

}

/// A seek slider that follows playback unless the user is actively dragging it.
private struct Scrubber: View {
    let np: NowPlaying
    let onSeek: (Double) -> Void
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let duration = max(np.durationSeconds, 1)
        let position = isScrubbing ? scrubValue : min(np.positionSeconds, duration)
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { position }, set: { scrubValue = $0 }),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing { isScrubbing = true }
                    else { onSeek(scrubValue); isScrubbing = false }
                }
            )
            HStack {
                Text(Self.time(position)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(Self.time(duration)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
