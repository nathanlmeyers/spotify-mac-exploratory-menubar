import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            account
            curationSection
            newReleasesSection
            suggestedArtistsSection
            librarySection
            menuBarSection
            discoverySection
            systemSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    // MARK: Account

    @ViewBuilder private var account: some View {
        Section("Account") {
            if !model.hasClientID {
                Text("No Spotify Client ID found. Add it to `Secrets.xcconfig` and rebuild (see README).")
                    .foregroundStyle(.secondary).font(.callout)
            } else if model.isAuthorized {
                HStack {
                    Label("Logged in to Spotify", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Log out", role: .destructive) { model.logout() }
                }
            } else {
                HStack {
                    Text("Not logged in")
                    Spacer()
                    Button("Log in with Spotify") { model.login() }
                }
                if let err = model.auth.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Curation

    @ViewBuilder private var curationSection: some View {
        Section("Curation") {
            Picker("Target playlist", selection: targetBinding) {
                Text("None").tag("")
                ForEach(model.editablePlaylists) { p in Text(p.name).tag(p.id) }
            }
            .disabled(!model.isAuthorized)

            HStack {
                Text(targetCaption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload playlists") { Task { await model.loadPlaylists() } }
                    .controlSize(.small)
                    .disabled(!model.isAuthorized)
            }

            Toggle("Also remove from the source playlist when I add (move)", isOn: $settings.removeFromSourceOnAdd)
                .help("When you press Plus, also remove the song from the playlist you're listening to — if that playlist is editable.")

            Toggle("Skip to the next track after I remove", isOn: $settings.skipToNextAfterRemove)
                .help("When you press Remove, also advance to the next song instead of finishing the one you just removed.")
            Toggle("Skip to the next track after I add", isOn: $settings.skipToNextAfterAdd)
                .help("When you press Add, also advance to the next song. Off by default so you can keep enjoying a track you like.")
        }
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { settings.targetPlaylistId ?? "" },
            set: { id in
                if id.isEmpty {
                    settings.targetPlaylistId = nil
                    settings.targetPlaylistName = nil
                    return
                }
                if let p = model.editablePlaylists.first(where: { $0.id == id }) { model.setTarget(p) }
            }
        )
    }

    private var targetCaption: String {
        if let name = settings.targetPlaylistName { return "Adding to: \(name)" }
        return "Pick an editable playlist you own."
    }

    // MARK: New releases

    /// The release radar: a daily sweep of followed artists into a playlist.
    @ViewBuilder private var newReleasesSection: some View {
        Section {
            Toggle("Collect new music from artists I follow", isOn: $settings.newReleasesEnabled)
            caption("Checks your followed artists once a day and adds anything they released — or were featured on — to a playlist. Only ever adds; it never removes anything.")

            if settings.newReleasesEnabled {
                if !model.isAuthorized {
                    caption("Log in to Spotify to use this.")
                } else if !model.hasFollowScopes {
                    // A refresh can't widen scopes, so the only fix is a fresh login.
                    caption("This needs permission to read your followed artists. Log out and log back in to grant it.")
                    HStack {
                        Spacer()
                        Button("Log out") { model.logout() }.controlSize(.small)
                    }
                } else {
                    destinationControls
                    filterControls
                    scanControls
                }
            }
        } header: {
            Text("New releases")
        }
    }

    // MARK: Artists to follow

    /// The list itself lives in its own window; this section is the way in, plus the only place
    /// a dismissed artist can be brought back once the window's Undo has gone.
    @ViewBuilder private var suggestedArtistsSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artists you listen to but don't follow")
                    caption("Ranked from your top artists and top tracks. Following one also widens what New From Followed sweeps.")
                }
                Spacer()
                Button("Open…") {
                    NotificationCenter.default.post(name: .openSuggestedArtists, object: nil)
                }
                .controlSize(.small)
                .disabled(!model.isAuthorized)
            }

            if model.isAuthorized && !model.hasSuggestScopes {
                // A refresh can't widen scopes, so the only fix is a fresh login.
                caption("This needs permission to read your top artists and to follow someone. Log out and log back in to grant it.")
                HStack {
                    Spacer()
                    Button("Log out") { model.logout() }.controlSize(.small)
                }
            }

            if model.suggestions.dismissedCount > 0 {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.suggestions.dismissedCount) artist\(model.suggestions.dismissedCount == 1 ? "" : "s") hidden")
                        // Worth stating plainly: "Not interested" looks like an unfollow and
                        // isn't one. Nothing left the account, so nothing needs undoing there.
                        caption("Hidden only from this list — nothing on your Spotify account was changed.")
                    }
                    Spacer()
                    Button("Show all again") { model.suggestions.restoreAllDismissed() }
                        .controlSize(.small)
                }
                DisclosureGroup("Hidden artists") {
                    ForEach(model.suggestions.dismissedArtists(), id: \.id) { artist in
                        HStack {
                            Text(artist.name).font(.callout)
                            Spacer()
                            Button("Restore") { model.suggestions.restore(artistId: artist.id) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Artists to follow")
        }
    }

    @ViewBuilder private var destinationControls: some View {
        // Locked while a sweep is in flight: the scan captured the old destination when it
        // started, so switching mid-run would keep appending over there while the caches were
        // reset for the new one. The sweep is minutes at most; waiting it out is the whole fix.
        Picker("Add to", selection: newReleasesTargetBinding) {
            Text("None").tag("")
            ForEach(model.editablePlaylists) { p in Text(p.name).tag(p.id) }
        }
        .disabled(model.newReleases.isRunning)
        .help(model.newReleases.isRunning ? "Can't change this while a scan is running." : "")
        HStack {
            caption(settings.newReleasesPlaylistName.map { "Adding to: \($0)" }
                    ?? "Pick a playlist, or let the app make one for you.")
            Spacer()
            Button("Create “New From Followed”") { model.createNewReleasesPlaylist() }
                .controlSize(.small)
                .disabled(model.isBusy || model.newReleases.isRunning)
        }
    }

    @ViewBuilder private var filterControls: some View {
        Group {
            Toggle("Include songs they're featured on", isOn: $settings.newReleasesIncludeFeatures)
                .help("Also collect tracks where they're a guest, not just their own releases. Costs more requests and takes a few days to sweep everyone.")
            Toggle("Only when they're the main artist", isOn: $settings.newReleasesPrimaryArtistOnly)
                .help("Require the followed artist to hold the first credit on the track.")
            Toggle("Skip remixes", isOn: $settings.newReleasesExcludeRemixes)
            Toggle("Skip compilations and greatest-hits", isOn: $settings.newReleasesExcludeCompilations)

            Picker("Look back", selection: $settings.newReleasesLookbackDays) {
                Text("1 week").tag(7)
                Text("2 weeks").tag(14)
                Text("1 month").tag(30)
            }
            .help("How far back a release can be dated and still count as new.")
        }
    }

    @ViewBuilder private var scanControls: some View {
        switch model.newReleases.state {
        case .running(let message):
            HStack {
                ProgressView().controlSize(.small)
                caption(message)
            }

        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            scanButtons

        case .idle:
            if let summary = model.newReleases.lastSummary {
                caption(summary + (model.newReleases.lastScanAt.map { " — \(relative($0))" } ?? ""))
            }
            scanButtons
        }
    }

    @ViewBuilder private var scanButtons: some View {
        HStack {
            // Filters are applied while scanning, so an already-scanned album is never
            // reconsidered — changing a filter does nothing visible without a rescan.
            Button("Rescan from scratch") { model.newReleases.resetAndRescan() }
                .controlSize(.small)
                .disabled(settings.newReleasesPlaylistId == nil)
            Spacer()
            Button("Scan now") { model.newReleases.scanNow() }
                .controlSize(.small)
                .disabled(settings.newReleasesPlaylistId == nil)
        }
    }

    private var newReleasesTargetBinding: Binding<String> {
        Binding(
            get: { settings.newReleasesPlaylistId ?? "" },
            set: { id in
                if id.isEmpty {
                    settings.newReleasesPlaylistId = nil
                    settings.newReleasesPlaylistName = nil
                    return
                }
                if let p = model.editablePlaylists.first(where: { $0.id == id }) {
                    model.setNewReleasesTarget(p)
                }
            }
        )
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Library

    /// "Your Episodes" is Spotify's saved-podcast-episodes library — it looks like a playlist in
    /// the client but isn't one, and no Spotify client offers a way to empty it.
    @ViewBuilder private var librarySection: some View {
        Section("Library") {
            switch model.clearEpisodes {
            case .idle:
                if !model.isAuthorized {
                    caption("Log in to manage Your Episodes.")
                } else if !model.hasLibraryScopes {
                    caption("Clearing Your Episodes needs podcast-library permission. Log out and log back in to grant it.")
                    HStack {
                        Spacer()
                        Button("Log out") { model.logout() }.controlSize(.small)
                    }
                } else {
                    HStack {
                        caption("Spotify gives you no way to empty Your Episodes.")
                        Spacer()
                        Button("Clear Your Episodes…") { model.beginClearYourEpisodes() }
                            .controlSize(.small)
                    }
                }

            case .counting:
                HStack {
                    ProgressView().controlSize(.small)
                    caption("Counting saved episodes…")
                }

            case .confirming(let count):
                Text("Permanently unsave all \(count) episode\(count == 1 ? "" : "s")? This can't be undone.")
                    .font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelClearYourEpisodes() }.controlSize(.small)
                    Button("Remove \(count) episode\(count == 1 ? "" : "s")", role: .destructive) {
                        model.confirmClearYourEpisodes()
                    }
                    .controlSize(.small)
                }

            case .clearing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                caption(LibraryLogic.progressLabel(done: done, total: total))

            case .finished(let removed):
                HStack {
                    caption(removed == 0 ? "Your Episodes is already empty."
                                         : "Removed \(removed) episode\(removed == 1 ? "" : "s").")
                    Spacer()
                    Button("Done") { model.acknowledgeClearYourEpisodes() }.controlSize(.small)
                }

            case .failed(let message):
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Done") { model.acknowledgeClearYourEpisodes() }.controlSize(.small)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Menu bar

    @ViewBuilder private var menuBarSection: some View {
        Section("Menu bar") {
            Picker("Show track title", selection: $settings.menuBarTitleMode) {
                ForEach(MenuBarTitleMode.allCases) { Text($0.label).tag($0) }
            }
            Text("A long title can make the menu bar item too wide to fit — macOS then hides it, and the app looks like it isn't running. Showing the title only while a song is held keeps it narrow the rest of the time.")
                .font(.caption).foregroundStyle(.secondary)

            if settings.menuBarTitleMode != .never {
                Picker("Maximum width", selection: $settings.menuBarTitleMaxWidth) {
                    Text("Short").tag(MenuBarTitle.widthOptions[0])
                    Text("Medium").tag(MenuBarTitle.widthOptions[1])
                    Text("Long").tag(MenuBarTitle.widthOptions[2])
                }
                .help("Pick a narrower width if your menu bar is crowded and the icon still gets hidden.")
            }
        }
    }

    // MARK: Discovery (Phase 2)

    @ViewBuilder private var discoverySection: some View {
        Section {
            Toggle("Enable discovery mode", isOn: $settings.discoveryEnabled)
            Text("Pauses each song just before it ends so you can decide — Add, Remove, or Next — without it auto-advancing. Great for triaging new-releases playlists.")
                .font(.caption).foregroundStyle(.secondary)

            if settings.discoveryEnabled {
                Group {
                    Text("Alert me when a song is held:").font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto-open the panel", isOn: $settings.alertAutoOpenPanel)
                    Toggle("Shade the menu bar icon when a song is held", isOn: $settings.alertBadgeIcon)
                    Toggle("Play a sound", isOn: $settings.alertSound)
                    Toggle("Keep the review panel open until I choose", isOn: $settings.keepHeldPanelOpen)
                        .help("While a song is held, don't close the panel when you click elsewhere — only Add, Remove, or Next will dismiss it.")
                }

                Group {
                    Text("Auto-skip (don't hold) when:").font(.caption).foregroundStyle(.secondary)
                    Toggle("Song is already in the target playlist", isOn: $settings.skipIfInTarget)
                    Toggle("I've already reviewed the song", isOn: $settings.skipAlreadyReviewed)
                    Text("Auto-skip only skips. Songs are removed from a playlist only when you press Remove.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Discovery mode")
        }
    }

    // MARK: System

    @ViewBuilder private var systemSection: some View {
        Section {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            if BuildInfo.isTransientBuild {
                Text("Launch at login is unavailable for a debug build — move the app to /Applications first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(BuildInfo.shortSummary).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Quit Spotify Menu Bar", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
