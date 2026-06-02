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
        }
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { settings.targetPlaylistId ?? "" },
            set: { id in
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
            Group {
                Text("Alert me when a song is held:").font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-open the panel", isOn: $settings.alertAutoOpenPanel)
                Toggle("Pulse / badge the menu bar icon", isOn: $settings.alertBadgeIcon)
                Toggle("Play a sound", isOn: $settings.alertSound)
            }
            .disabled(!settings.discoveryEnabled)

            Group {
                Text("Auto-skip (don't hold) when:").font(.caption).foregroundStyle(.secondary)
                Toggle("Song is already in the target playlist", isOn: $settings.skipIfInTarget)
                Toggle("…and also remove it from the source", isOn: $settings.skipInTargetAlsoRemove)
                    .padding(.leading, 16)
                    .disabled(!settings.skipIfInTarget)
                Toggle("I've already reviewed the song", isOn: $settings.skipAlreadyReviewed)
            }
            .disabled(!settings.discoveryEnabled)
        } header: {
            Text("Discovery mode")
        } footer: {
            Text("The hold-and-judge behavior ships in the next update; these preferences are saved now.")
                .font(.caption)
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
