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
            if !model.isSpotifyResponsive { notRespondingNotice }
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

    /// Spotify is running but has stopped answering Apple events, so everything below is the
    /// last known reading rather than live. Say so, instead of showing a frozen track as if it
    /// were current. No restart prompt: the connection rebuilds itself, and this clears on the
    /// first successful read. Discovery is disarmed meanwhile (see GuardedTransport).
    private var notRespondingNotice: some View {
        Label("Spotify isn't responding — showing the last known track",
              systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Settings gear, right-aligned on its own row — used in states with no track header.
    private var topBar: some View {
        HStack {
            Spacer()
            suggestedArtistsButton
            settingsGear
        }
    }

    /// The settings gear button (opens the Settings window via notification).
    private var settingsGear: some View {
        Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
            Image(systemName: "gearshape")
        }.help("Settings").buttonStyle(.borderless)
    }

    /// Opens the Artists to Follow list. Hidden until the login can actually reach it, so the
    /// panel doesn't offer a button whose only outcome is a "log in first" screen.
    @ViewBuilder
    private var suggestedArtistsButton: some View {
        if model.isAuthorized {
            Button { NotificationCenter.default.post(name: .openSuggestedArtists, object: nil) } label: {
                Image(systemName: "person.badge.plus")
            }
            .help("Artists to Follow — artists you listen to but don't follow")
            .buttonStyle(.borderless)
        }
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
            trackHeader(np, fromName: model.heldSourceName(held))
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
                    suggestedArtistsButton
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

    /// The curation row — or, while a multi-row removal is waiting on an answer, the
    /// confirmation that replaces it. Swapping rather than stacking is deliberate: the decision
    /// is modal, and leaving Add/Remove live underneath invites answering it by accident.
    @ViewBuilder private var curationNormal: some View {
        if let pending = model.pendingDuplicateRemoval {
            duplicateConfirm(pending)
        } else {
            curationNormalButtons
        }
    }

    private var curationNormalButtons: some View {
        HStack(spacing: 10) {
            curationButton("Remove", icon: "minus.circle.fill", tint: .red,
                           disabled: !model.canRemoveFromSource,
                           help: model.removeDisabledReason ?? "Remove from \(model.source.playlistName ?? "source")") {
                model.removeCurrentFromSource()
            }
            curationButton("Add", icon: "plus.circle.fill", tint: .green,
                           done: model.currentIsInTarget,
                           disabled: !model.canAdd,
                           help: addHelp(isInTarget: model.currentIsInTarget)) {
                model.addCurrentToTarget()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder private func curationHeld(_ held: HeldTrack) -> some View {
        if let pending = model.pendingDuplicateRemoval {
            duplicateConfirm(pending)
        } else {
            curationHeldButtons(held)
        }
    }

    /// "This song is in the playlist four times — remove all four?"
    ///
    /// The count is the whole point. Spotify's delete-by-URI takes every copy and there is no
    /// undo, so this is the last place the number can be seen before the rows are gone.
    private func duplicateConfirm(_ pending: PendingDuplicateRemoval) -> some View {
        let subject = pending.trackName.map { "“\($0)”" } ?? "This track"
        return VStack(alignment: .leading, spacing: 8) {
            Label("\(subject) is in \(pending.playlistName) \(pending.count) times",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Spotify can only remove every copy at once. This can't be undone.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelDuplicateRemoval() }
                Button("Remove all \(pending.count)", role: .destructive) {
                    model.confirmDuplicateRemoval()
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func curationHeldButtons(_ held: HeldTrack) -> some View {
        let canRemove = model.canRemoveHeld(held)
        return HStack(spacing: 8) {
            curationButton("Remove", icon: "minus.circle.fill", tint: .red,
                           disabled: !canRemove,
                           help: canRemove ? "Remove from source" : (model.heldRemoveDisabledReason(held) ?? "Can't remove")) {
                model.heldRemove()
            }
            curationButton("Add", icon: "plus.circle.fill", tint: .green,
                           done: model.isInTarget(held.snapshot),
                           disabled: !held.canAdd,
                           help: addHelp(isInTarget: model.isInTarget(held.snapshot),
                                         canAdd: held.canAdd, targetName: held.targetName)) {
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

    /// Tooltip for the Add button. macOS suppresses `.help` on a disabled control, so the
    /// "already there" string is a fallback for accessibility readers rather than the main
    /// signal — that is the "Added" label itself.
    private func addHelp(isInTarget: Bool, canAdd: Bool = true, targetName: String? = nil) -> String {
        let target = targetName ?? model.settings.targetPlaylistName ?? "target"
        if isInTarget { return "Already in \(target)" }
        if !canAdd { return model.addDisabledReason ?? "Can't add" }
        return model.addDisabledReason ?? "Add to \(target)"
    }

    /// `done` is the Add button's "already in the target" face: a green checkmark, disabled.
    ///
    /// Still a `Button` rather than a plain `Label` (the way SuggestedArtistsView swaps out
    /// Follow) because this row is equal-width buttons and a Label would collapse it. But it
    /// drops to `.bordered`: a *disabled* `.borderedProminent` fades its fill and keeps the
    /// label white, which in light mode is white-on-pale-green and barely legible. Letting the
    /// fill go and colouring the label green instead reads clearly in both appearances, and the
    /// missing fill is itself the "this is no longer the action here" signal.
    @ViewBuilder
    private func curationButton(_ title: String, icon: String, tint: Color,
                                done: Bool = false,
                                disabled: Bool = false, help: String,
                                action: @escaping () -> Void) -> some View {
        Group {
            if done {
                Button(action: action) {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button(action: action) {
                    Label(title, systemImage: icon).frame(maxWidth: .infinity)
                }
                .tint(tint)
            }
        }
        .disabled(done || disabled)
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
