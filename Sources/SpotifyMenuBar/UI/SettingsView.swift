import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            account
            curationSection
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

    // MARK: Menu bar

    @ViewBuilder private var menuBarSection: some View {
        Section("Menu bar") {
            Toggle("Show track title next to the icon", isOn: $settings.showTrackTitleInMenuBar)
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
                    Toggle("…and also remove it from the source", isOn: $settings.skipInTargetAlsoRemove)
                        .padding(.leading, 16)
                        .disabled(!settings.skipIfInTarget)
                    Toggle("I've already reviewed the song", isOn: $settings.skipAlreadyReviewed)
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
            HStack {
                Spacer()
                Button("Quit Spotify Menu Bar", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
