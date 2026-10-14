import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    /// Everything past the two playlists and the Discover switch lives behind this. Not
    /// persisted: the window is short by default and opens that way every time.
    @State private var showAdvanced = false

    var body: some View {
        Form {
            account
            curationSection
            discoverSection
            advancedHeader
            if showAdvanced {
                curationAdvancedSection
                newReleasesSection
                topTracksSection
                suggestedArtistsSection
                librarySection
                menuBarSection
                discoverAdvancedSection
                systemSection
            }
            quitSection
        }
        .formStyle(.grouped)
        // A grouped Form is a scroll view with no height of its own, so the window height is
        // set here and `AppDelegate.openSettings` lets the window follow it.
        .frame(width: 460, height: showAdvanced ? 640 : 360)
        .animation(.default, value: showAdvanced)
        .confirmationDialog(replaceDialogTitle, isPresented: replaceDialogShown, titleVisibility: .visible) {
            Button("Use Replace") {
                if let period = pendingReplacePeriod { model.setTopTracksMode(.replace, for: period) }
                pendingReplacePeriod = nil
            }
            Button("Keep Append", role: .cancel) { pendingReplacePeriod = nil }
        } message: {
            Text("Replace rewrites the playlist every day to mirror your top songs and removes anything else in it — including songs you added by hand. Only this playlist, which the app created, is ever affected. Append never removes anything.")
        }
    }

    /// Which period is waiting on the one-time Replace confirmation.
    @State private var pendingReplacePeriod: TopTracksPeriod?

    private var replaceDialogShown: Binding<Bool> {
        Binding(get: { pendingReplacePeriod != nil },
                set: { if !$0 { pendingReplacePeriod = nil } })
    }

    private var replaceDialogTitle: String {
        let name = pendingReplacePeriod.flatMap { settings.topTracks($0).playlistName } ?? "this playlist"
        return "Switch “\(name)” to Replace?"
    }

    // MARK: Advanced

    /// A single row that reveals the rest. Sibling sections rather than `Section`s nested in a
    /// `DisclosureGroup`: a grouped Form on macOS 13 flattens those into plain rows.
    private var advancedHeader: some View {
        Section {
            Button { showAdvanced.toggle() } label: {
                HStack {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Advanced Settings")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
        }
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

            Picker("Discovery playlist", selection: discoveryPlaylistBinding) {
                Text("None").tag("")
                ForEach(model.editablePlaylists) { p in Text(p.name).tag(p.id) }
            }
            .disabled(!model.isAuthorized)
            .help("Your inbox of new music. Remove takes the song out of it too, whatever you're listening from.")
            caption(discoveryPlaylistCaption)
        }
    }

    /// The Curation toggles that moved behind Advanced — behaviour tweaks, not setup.
    @ViewBuilder private var curationAdvancedSection: some View {
        Section("Curation") {
            Toggle("Also remove from the source playlist when I add (move)", isOn: $settings.removeFromSourceOnAdd)
                .help("When you press Plus, also remove the song from the playlist you're listening to — if that playlist is editable.")

            Toggle("Skip to the next track after I remove", isOn: $settings.skipToNextAfterRemove)
                .help("When you press Remove, also advance to the next song instead of finishing the one you just removed.")
            Toggle("Skip to the next track after I add", isOn: $settings.skipToNextAfterAdd)
                .help("When you press Add, also advance to the next song. Off by default so you can keep enjoying a track you like.")

            Toggle("Ask before removing a song that's in the playlist more than once",
                   isOn: $settings.warnOnDuplicateRemoval)
                .help("Spotify can only delete every copy of a song at once, so one Remove can take several rows. This checks first and shows you the number. It costs one read of the playlist per Remove.")
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

    private var discoveryPlaylistBinding: Binding<String> {
        Binding(
            get: { settings.discoveryPlaylistId ?? "" },
            set: { id in
                if id.isEmpty { model.clearDiscoveryPlaylist(); return }
                if let p = model.editablePlaylists.first(where: { $0.id == id }) { model.setDiscoveryPlaylist(p) }
            }
        )
    }

    private var discoveryPlaylistCaption: String {
        if let name = settings.discoveryPlaylistName {
            return "Remove also takes the song out of \(name), whatever you're playing from."
        }
        return "Remove also takes the song out of this playlist, whatever you're playing from."
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
                    Toggle("Notify me when it adds tracks", isOn: $settings.newReleasesNotify)
                        .help("A macOS notification after each sweep that found something. Click it to open the playlist.")
                    if settings.newReleasesNotify, model.notifier.authorization == .denied {
                        caption("Notifications are turned off for Spotify Menu Bar in System Settings ▸ Notifications.")
                    }
                }
            }
        } header: {
            Text("New releases")
        }
    }

    // MARK: Top tracks (last.fm)

    /// Three playlists mirroring the user's most played songs on last.fm, one per period.
    @ViewBuilder private var topTracksSection: some View {
        Section {
            caption("Keeps a playlist of your most played songs — all time, the last 6 months, the last 30 days — from your last.fm scrobbles, once a day while the app is running.")

            if !model.topTracks.hasLastFMKey {
                caption("No last.fm API key found. Add `LASTFM_API_KEY` to `Secrets.xcconfig` and rebuild (see README).")
            } else if !model.isAuthorized {
                caption("Log in to Spotify to use this.")
            } else {
                TextField("last.fm username", text: $settings.topTracksLastFMUser)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.topTracks.isRunning)

                Picker("Playlist length", selection: $settings.topTracksLimit) {
                    ForEach(TopTracksLogic.allowedLimits, id: \.self) { Text("\($0) songs").tag($0) }
                }
                .disabled(model.topTracks.isRunning)

                ForEach(TopTracksPeriod.allCases) { period in
                    Divider()
                    periodControls(period)
                }

                Divider()
                topTracksStatus
            }
        } header: {
            Text("Top tracks (last.fm)")
        }
    }

    @ViewBuilder private func periodControls(_ period: TopTracksPeriod) -> some View {
        let config = settings.topTracks(period)
        Toggle(period.label, isOn: topTracksEnabledBinding(period))

        if config.enabled {
            // Locked while a sync runs for the same reason the radar's picker is.
            Picker("Add to", selection: topTracksTargetBinding(period)) {
                Text("None").tag("")
                ForEach(model.editablePlaylists) { p in Text(p.name).tag(p.id) }
            }
            .disabled(model.topTracks.isRunning)

            let owned = model.topTracksTargetIsOwned(period)
            HStack {
                caption(config.playlistName.map { "Adding to: \($0)" + (owned ? " (created by this app)" : "") }
                        ?? "Pick a playlist, or let the app make one for you.")
                Spacer()
                Button("Create “\(period.defaultPlaylistName)”") { model.createTopTracksPlaylist(for: period) }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.topTracks.isRunning)
            }

            if config.playlistId != nil {
                Picker("Mode", selection: topTracksModeBinding(period)) {
                    ForEach(TopTracksSyncMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!owned || model.topTracks.isRunning)
                caption(owned
                        ? "Append only adds. Replace rewrites the playlist to mirror your top \(settings.topTracksLimit) in order, removing anything else."
                        : "Replace is only available on a playlist this app created for this period — press Create. Append never removes anything.")
            }

            if let status = model.topTracks.status[period], let summary = status.lastSummary {
                caption(summary + (status.lastSyncAt.map { " — \(relative($0))" } ?? ""))
            }
        }
    }

    @ViewBuilder private var topTracksStatus: some View {
        switch model.topTracks.state {
        case .running(let message):
            HStack {
                ProgressView().controlSize(.small)
                caption(message)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            syncNowButton
        case .idle:
            syncNowButton
        }
    }

    private var anyTopTracksPeriodReady: Bool {
        TopTracksPeriod.allCases.contains { settings.topTracks($0).enabled && settings.topTracks($0).playlistId != nil }
    }

    @ViewBuilder private var syncNowButton: some View {
        HStack {
            Spacer()
            Button("Sync now") { model.topTracks.syncNow() }
                .controlSize(.small)
                .disabled(!anyTopTracksPeriodReady || model.topTracks.isRunning
                          || settings.topTracksLastFMUser.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func topTracksEnabledBinding(_ period: TopTracksPeriod) -> Binding<Bool> {
        Binding(get: { settings.topTracks(period).enabled },
                set: { on in settings.updateTopTracks(period) { $0.enabled = on } })
    }

    private func topTracksTargetBinding(_ period: TopTracksPeriod) -> Binding<String> {
        Binding(
            get: { settings.topTracks(period).playlistId ?? "" },
            set: { id in
                if id.isEmpty { model.clearTopTracksTarget(for: period); return }
                if let p = model.editablePlaylists.first(where: { $0.id == id }) {
                    model.setTopTracksTarget(p, for: period)
                }
            }
        )
    }

    /// Replace goes through the one-time confirmation the first time; after that the guard in
    /// `AppModel.setTopTracksMode` is the only check, and it refuses anything we don't own.
    private func topTracksModeBinding(_ period: TopTracksPeriod) -> Binding<TopTracksSyncMode> {
        Binding(
            get: { settings.topTracks(period).mode },
            set: { mode in
                if mode == .replace, !settings.topTracksReplaceAcknowledged {
                    pendingReplacePeriod = period
                } else {
                    model.setTopTracksMode(mode, for: period)
                }
            }
        )
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
                    // Not "already empty": a clear only touches what was approved, so zero can
                    // also mean everything on that list was unsaved elsewhere first.
                    caption(removed == 0 ? "Nothing left to remove."
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

    // MARK: Discover mode

    @ViewBuilder private var discoverSection: some View {
        Section {
            Toggle("Discover mode", isOn: $settings.discoveryEnabled)
            Text("Pauses each song just before it ends so you can decide — Add, Remove, or Next — without it auto-advancing. Great for triaging new-releases playlists. Also in the panel, next to the playback controls.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The alert and auto-skip options for Discover mode. Shown even while the mode is off so
    /// they can be set up ahead of flipping the switch in the panel.
    @ViewBuilder private var discoverAdvancedSection: some View {
        Section {
            if !settings.discoveryEnabled {
                caption("Discover mode is off. These apply once it's on.")
            }
            Group {
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
            Text("Discover mode")
        }
    }

    // MARK: System

    @ViewBuilder private var systemSection: some View {
        Section("System") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            if BuildInfo.isTransientBuild {
                Text("Launch at login is unavailable for a debug build — move the app to /Applications first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(BuildInfo.shortSummary).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Always last and always visible, whatever Advanced is doing.
    private var quitSection: some View {
        Section {
            HStack {
                Spacer()
                Button("Quit Spotify Menu Bar", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
