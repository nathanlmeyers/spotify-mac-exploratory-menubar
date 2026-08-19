import SwiftUI

/// The "Artists to Follow" window: artists the user listens to but hasn't followed.
///
/// The app's first scrolling, image-heavy view, so it sets no new conventions of its own —
/// stock SwiftUI semantic styling, `.caption` + `.secondary` for explanatory lines, SF Symbols
/// with `.help` on every icon-only button, exactly as `NowPlayingView` and `SettingsView` do.
struct SuggestedArtistsView: View {
    @EnvironmentObject var model: AppModel

    /// Artwork is drawn at 56pt — a little smaller than the panel's 64pt now-playing art,
    /// because a list of them needs to stay scannable rather than dominate.
    private let artworkSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
        .onAppear { model.suggestions.refreshIfStale() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Artists to Follow").font(.headline)
                Text(ArtistSuggestionLogic.updatedLabel(
                    lastRefreshAt: model.suggestions.lastRefreshAt, now: Date()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.suggestions.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { model.suggestions.refreshNow() }
                .controlSize(.small)
                .disabled(model.suggestions.isLoading || !model.hasSuggestScopes)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.isAuthorized {
            message("Log in to Spotify to see suggestions.",
                    systemImage: "person.crop.circle.badge.questionmark")
        } else if !model.hasSuggestScopes {
            scopeGate
        } else if case .failed(let reason) = model.suggestions.state, model.suggestions.rows.isEmpty {
            message(reason, systemImage: "exclamationmark.triangle", isError: true)
        } else if model.suggestions.rows.isEmpty {
            if model.suggestions.isLoading {
                message("Working out who you listen to…", systemImage: "waveform")
            } else {
                message("Nothing new — you already follow everyone you listen to.",
                        systemImage: "checkmark.circle")
            }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            // Lazy because artwork is loaded per row by `AsyncImage`, which has no cache beyond
            // `URLSession`'s: an eager stack would fire every request the moment the window opens.
            LazyVStack(spacing: 0) {
                ForEach(model.suggestions.rows) { row in
                    artistRow(row)
                    Divider().padding(.leading, 16 + artworkSize + 12)
                }
            }
        }
    }

    private func artistRow(_ row: ArtistSuggestionEngine.Row) -> some View {
        HStack(spacing: 12) {
            artwork(row.imageURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.headline).lineLimit(1)
                Text(row.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !row.genres.isEmpty {
                    Text(row.genres.prefix(3).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button { model.playArtist(id: row.id) } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                // Says what it actually does. Spotify picks the song because the API can no
                // longer tell us which one is biggest — see AppModel.playArtist.
                .help("Play \(row.name) in Spotify, starting with their most popular song")

                Button { model.openArtistInSpotify(id: row.id) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open \(row.name) in Spotify")

                if row.isFollowed {
                    Label("Following", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .help("You followed \(row.name). They'll drop off this list next refresh.")
                } else {
                    Button { model.followSuggested(id: row.id, name: row.name) } label: {
                        Label("Follow", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .help("Follow \(row.name) on Spotify")

                    Button { model.dismissSuggested(id: row.id) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    // Spelled out because the button sits next to Follow and looks destructive.
                    // It isn't: nothing is unfollowed, nothing leaves the account.
                    .help("Not interested — hides \(row.name) from this list only. Nothing on your Spotify account changes.")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func artwork(_ url: URL?) -> some View {
        ZStack {
            // Circular, which is how Spotify draws artists everywhere else — the shape is the
            // fastest signal that a row is a person rather than an album.
            Circle().fill(.quaternary)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Image(systemName: "person.fill").foregroundStyle(.secondary) }
            } else {
                Image(systemName: "person.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(Circle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let undo = model.suggestions.undoable {
                Text("Hid \(undo.name).").font(.caption).foregroundStyle(.secondary)
                Button("Undo") { model.suggestions.undoDismiss() }
                    .controlSize(.small)
            } else if case .failed(let reason) = model.suggestions.state,
                      !model.suggestions.rows.isEmpty {
                // Rows are still on screen and still usable — this is "couldn't update", not
                // "broken", so it goes in the footer rather than replacing the list.
                Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let summary = model.suggestions.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 38)
    }

    // MARK: - States

    private var scopeGate: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.rotation").font(.largeTitle).foregroundStyle(.secondary)
            Text("This feature needs new permissions.").font(.headline)
            // A refresh token can never widen scopes, so there is genuinely no way round this
            // one — the same forced re-login Clear Your Episodes and New From Followed needed.
            Text("Reading your top artists and following someone needs permissions your current login doesn't have. Log out and log back in once.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Log out") { model.logout() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func message(_ text: String, systemImage: String, isError: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(isError ? Color.red : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
