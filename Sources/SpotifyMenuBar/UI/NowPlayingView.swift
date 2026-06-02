import SwiftUI

/// The popover contents: now-playing, scrubber, transport, and the curation buttons.
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.hasClientID {
                clientIDMissing
            } else if !model.isAuthorized {
                loggedOut
            } else if let np = model.nowPlaying {
                player(np)
            } else {
                idleState
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: States

    private var clientIDMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Set up required", systemImage: "exclamationmark.triangle")
                .font(.headline)
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
            }
            .buttonStyle(.borderedProminent)
            if let err = model.auth.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isSpotifyRunning {
                Label("Nothing playing", systemImage: "pause.circle")
                    .font(.headline).foregroundStyle(.secondary)
                Text("Start a song in Spotify.").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("Spotify isn't running", systemImage: "bolt.horizontal.circle")
                    .font(.headline).foregroundStyle(.secondary)
                Button { model.openSpotify() } label: {
                    Label("Open Spotify", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    // MARK: Player

    private func player(_ np: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                artwork(np.artworkURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(np.name.isEmpty ? "—" : np.name)
                        .font(.headline).lineLimit(2)
                    Text(np.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(fromToLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Scrubber(np: np) { model.seek(to: $0) }

            transport(np)
            curation
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
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

    private var fromToLine: String {
        let from = model.source.playlistName ?? "—"
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
            // Spacer counterweight so play/pause stays centered.
            Image(systemName: "shuffle").opacity(0)
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private var curation: some View {
        HStack(spacing: 10) {
            Button { model.removeCurrentFromSource() } label: {
                Label("Remove", systemImage: "minus.circle.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(!model.canRemoveFromSource)
            .help(model.removeDisabledReason ?? "Remove from \(model.source.playlistName ?? "source")")

            Button { model.addCurrentToTarget() } label: {
                Label("Add", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(!model.canAdd)
            .help(model.addDisabledReason ?? "Add to \(model.settings.targetPlaylistName ?? "target")")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var footer: some View {
        HStack {
            if model.isAuthorized { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption) }
            Spacer()
            Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
                Image(systemName: "gearshape")
            }.help("Settings")
            .buttonStyle(.borderless)
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
