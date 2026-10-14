import XCTest

/// The rule behind the Add button's checkmark. It is disabled when checked, so a false positive
/// here is a song the user cannot add at all — every "unknown" case below must answer false.
final class CurationLogicTests: XCTestCase {

    private let song = "spotify:track:abc"
    private let target = "playlist1"

    private func shows(uri: String?,
                       loadedFor: String? = "playlist1",
                       current: String? = "playlist1",
                       membership: Set<String>) -> Bool {
        CurationLogic.showsInTarget(trackURI: uri,
                                    membershipTargetId: loadedFor,
                                    currentTargetId: current,
                                    membership: membership)
    }

    func testTrackInTheCurrentTargetShowsAsAdded() {
        XCTAssertTrue(shows(uri: song, membership: [song]))
    }

    func testTrackNotInTheTargetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, membership: ["spotify:track:other"]))
    }

    /// Cold start, a rate-limited fetch, or an offline launch all land here. Unknown reads as
    /// "not added" so the button stays pressable.
    func testUnloadedMembershipIsNotAdded() {
        XCTAssertFalse(shows(uri: song, membership: []))
    }

    func testNilAndEmptyURIsAreNotAdded() {
        XCTAssertFalse(shows(uri: nil, membership: [song]))
        XCTAssertFalse(shows(uri: "", membership: [song, ""]))
    }

    /// `playlistTrackURIs` stores whatever the playlist holds, episodes included — but Add
    /// refuses non-songs, so one must never wear the checkmark.
    func testNonCuratableURIsAreNotAddedEvenWhenPresent() {
        for uri in ["spotify:episode:abc", "spotify:local:abc", "spotify:ad:abc", "nonsense"] {
            XCTAssertFalse(shows(uri: uri, membership: [uri]), uri)
        }
    }

    /// The set belongs to the playlist we just switched away from. Answering from it would grey
    /// out Add for songs that are not in the new target at all.
    func testMembershipLoadedForADifferentTargetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, loadedFor: "playlist2", current: target, membership: [song]))
    }

    func testNoTargetSetIsNotAdded() {
        XCTAssertFalse(shows(uri: song, loadedFor: nil, current: nil, membership: [song]))
    }

    /// Both nil would compare equal; a target has to actually exist before Add can be "done".
    func testNilTargetDoesNotMatchNilMembershipTarget() {
        XCTAssertFalse(shows(uri: song, loadedFor: nil, current: nil, membership: [song]))
        XCTAssertFalse(shows(uri: song, loadedFor: target, current: nil, membership: [song]))
    }

    // MARK: removalTargets — what one Remove press deletes from

    private let crabHands = "crab"
    private let newSpots = "spots"

    private func editable(_ id: String, name: String, for uri: String) -> SourceContext {
        SourceContext(playlistId: id, playlistName: name, isEditablePlaylist: true,
                      trackURI: uri, resolvedForURI: uri)
    }

    private func album(for uri: String?) -> SourceContext {
        SourceContext(playlistId: nil, playlistName: nil, isEditablePlaylist: false,
                      trackURI: nil, resolvedForURI: uri)
    }

    private func targets(uri: String = "spotify:track:abc",
                         source: SourceContext,
                         discovery: String? = "crab",
                         loadedFor: String? = "crab",
                         membership: Set<String>) -> [RemovalTarget] {
        CurationLogic.removalTargets(uri: uri, source: source,
                                     discoveryPlaylistId: discovery,
                                     discoveryPlaylistName: discovery == nil ? nil : "Crab Hands",
                                     membershipLoadedFor: loadedFor,
                                     membership: membership)
    }

    func testRemovalTargetsEditableSourceOnly() {
        let t = targets(source: editable(newSpots, name: "new spots 13", for: song),
                        discovery: nil, loadedFor: nil, membership: [])
        XCTAssertEqual(t, [RemovalTarget(playlistId: newSpots, playlistName: "new spots 13")])
    }

    /// The whole point: an album track that sits in Crab Hands is removable from Crab Hands.
    func testRemovalTargetsDiscoveryOnlyFromAlbum() {
        let t = targets(source: album(for: song), membership: [song])
        XCTAssertEqual(t, [RemovalTarget(playlistId: crabHands, playlistName: "Crab Hands")])
    }

    func testRemovalTargetsBothWhenSourceIsAnotherEditablePlaylist() {
        let t = targets(source: editable(newSpots, name: "new spots 13", for: song), membership: [song])
        XCTAssertEqual(t.map(\.playlistId), [newSpots, crabHands])
    }

    /// Playing Crab Hands itself: one removal, exactly as before the discovery playlist existed.
    func testRemovalTargetsSourceIsDiscoveryPlaylistYieldsOneEntry() {
        let t = targets(source: editable(crabHands, name: "Crab Hands", for: song), membership: [song])
        XCTAssertEqual(t.map(\.playlistId), [crabHands])
    }

    func testRemovalTargetsNonEditableSourceStillRemovesFromDiscovery() {
        let weekly = SourceContext(playlistId: "dw", playlistName: "Discover Weekly", isEditablePlaylist: false,
                                   trackURI: song, resolvedForURI: song)
        XCTAssertEqual(targets(source: weekly, membership: [song]).map(\.playlistId), [crabHands])
    }

    /// The source was confirmed for the previous track; it must not be acted on for this one.
    func testRemovalTargetsStaleSourceTrackURIOmitsSource() {
        let stale = SourceContext(playlistId: newSpots, playlistName: "new spots 13", isEditablePlaylist: true,
                                  trackURI: "spotify:track:OLD", resolvedForURI: "spotify:track:OLD")
        XCTAssertEqual(targets(source: stale, membership: [song]), [])
    }

    /// No lookup has finished for this track, so nothing is known about where it plays from.
    func testRemovalTargetsUnresolvedContextYieldsNothing() {
        XCTAssertEqual(targets(source: album(for: nil), membership: [song]), [])
        XCTAssertEqual(targets(source: .none, membership: [song]), [])
    }

    func testRemovalTargetsMembershipLoadedForOtherPlaylistIsIgnored() {
        XCTAssertEqual(targets(source: album(for: song), loadedFor: "other", membership: [song]), [])
    }

    func testRemovalTargetsEmptyMembershipIsNotInDiscovery() {
        XCTAssertEqual(targets(source: album(for: song), membership: []), [])
    }

    func testRemovalTargetsNonCuratableURIYieldsNothing() {
        let episode = "spotify:episode:abc"
        XCTAssertEqual(targets(uri: episode, source: album(for: episode), membership: [episode]), [])
        XCTAssertEqual(targets(uri: episode, source: editable(newSpots, name: "n", for: episode), membership: []), [])
    }

    func testRemovalTargetsNoDiscoveryIdNoSourceYieldsNothing() {
        XCTAssertEqual(targets(source: album(for: song), discovery: nil, loadedFor: nil, membership: [song]), [])
    }

    // MARK: Strings

    func testRemoveHelpJoinsNames() {
        let a = RemovalTarget(playlistId: "a", playlistName: "new spots 13")
        let b = RemovalTarget(playlistId: "b", playlistName: "Crab Hands")
        XCTAssertEqual(CurationLogic.removeHelp(targets: [a]), "Remove from new spots 13")
        XCTAssertEqual(CurationLogic.removeHelp(targets: [a, b]), "Remove from new spots 13 and Crab Hands")
    }

    func testRemovedStatusNamesEveryPlaylist() {
        XCTAssertEqual(CurationLogic.removedStatus(succeeded: ["new spots 13", "Crab Hands"], failed: []),
                       "Removed from new spots 13 and Crab Hands")
        XCTAssertEqual(CurationLogic.removedStatus(succeeded: ["Crab Hands"], failed: []),
                       "Removed from Crab Hands")
    }

    func testPartialFailureStatusNamesOnlyTheFailure() {
        XCTAssertEqual(CurationLogic.removedStatus(succeeded: ["new spots 13"],
                                                   failed: [("Crab Hands", "429")]),
                       "Removed from new spots 13, but couldn't remove from Crab Hands: 429")
        XCTAssertEqual(CurationLogic.removedStatus(succeeded: [], failed: [("Crab Hands", "429")]),
                       "Remove failed: couldn't remove from Crab Hands: 429")
    }
}
