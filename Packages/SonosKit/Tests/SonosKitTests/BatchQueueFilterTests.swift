/// BatchQueueFilterTests.swift — Pin the queueable-item contract for
/// the batch queue actions (`addBrowseItemsToQueue` and
/// `fillQueueInBackground`).
///
/// The bug this guards: a previous filter `!item.isContainer` silently
/// dropped every container from the batch queue paths, so on an
/// artist's album list:
///   - Add All — no-op (every item was an album container, all dropped)
///   - Play All — only the FIRST album played (singular path doesn't
///     filter); the background fill silently dropped the rest
/// while the per-item paths (Play Next on a single album, drag-to-queue)
/// kept working because they used the singular `addBrowseItemToQueue`,
/// which routes container URIs straight to `AddURIToQueue` and lets
/// Sonos expand them server-side.
///
/// `SonosManager.isQueueable(_:)` is the contract: any item with a
/// non-empty `resourceURI` flows to the SOAP layer as-is, container or
/// not. Items with no URI (UPnP browse-only containers like local-
/// library albums) need a separate child-fetch path and are not
/// queueable here.
import XCTest
@testable import SonosKit

@MainActor
final class BatchQueueFilterTests: XCTestCase {

    // MARK: - Per-service realistic URIs

    private func spotifyTrack() -> BrowseItem {
        BrowseItem(
            id: "smapi:9:spotify:track:abc",
            title: "Jingo",
            itemClass: .musicTrack,
            resourceURI: "x-sonos-spotify:spotify%3atrack%3aabc?sid=9&flags=8224&sn=1"
        )
    }

    private func spotifyAlbumContainer() -> BrowseItem {
        BrowseItem(
            id: "smapi:9:spotify:album:xyz",
            title: "Some Album",
            itemClass: .musicAlbum,
            resourceURI: "x-rincon-cpcontainer:1004206calbum%3axyz?sid=9&flags=8300&sn=1"
        )
    }

    private func appleMusicAlbumContainer() -> BrowseItem {
        BrowseItem(
            id: "apple:album:123",
            title: "AM Album",
            itemClass: .musicAlbum,
            resourceURI: "x-rincon-cpcontainer:1006206calbum%3a123?sid=204&flags=8300&sn=1"
        )
    }

    private func plexPlaylistContainer() -> BrowseItem {
        BrowseItem(
            id: "smapi:212:plex:playlist:abc",
            title: "Plex Mix",
            itemClass: .playlist,
            resourceURI: "x-rincon-cpcontainer:1004206cplaylist%3aabc?sid=212&flags=8300&sn=1"
        )
    }

    private func upnpOnlyAlbumNoURI() -> BrowseItem {
        // Local library album as it arrives from a UPnP Browse — no
        // resourceURI; the player needs to browse children to enqueue.
        BrowseItem(
            id: "A:ALBUM/Some%20Album",
            title: "Local Album",
            itemClass: .musicAlbum,
            resourceURI: nil
        )
    }

    private func emptyURIItem() -> BrowseItem {
        BrowseItem(
            id: "weird:1",
            title: "Empty URI",
            itemClass: .musicTrack,
            resourceURI: ""
        )
    }

    // MARK: - Track items always queueable

    func testTrackWithURIIsQueueable() {
        XCTAssertTrue(SonosManager.isQueueable(spotifyTrack()))
    }

    // MARK: - Container items are queueable when they carry a URI
    //
    // The regression: pre-fix, `addBrowseItemsToQueue` and
    // `fillQueueInBackground` filtered these out via `!item.isContainer`.
    // The user-visible symptom was "Add All on artist albums silently
    // does nothing" and "Play All on artist albums plays only the
    // first album." Sonos's SOAP layer accepts these URIs in the same
    // batch action and expands them server-side — same path the
    // singular `addBrowseItemToQueue` already used.

    func testSpotifyAlbumContainerWithURIIsQueueable() {
        XCTAssertTrue(SonosManager.isQueueable(spotifyAlbumContainer()),
                      "SMAPI album containers carry an x-rincon-cpcontainer: URI that Sonos expands server-side. Filtering them out was the bug.")
    }

    func testAppleMusicAlbumContainerWithURIIsQueueable() {
        XCTAssertTrue(SonosManager.isQueueable(appleMusicAlbumContainer()))
    }

    func testPlexPlaylistContainerWithURIIsQueueable() {
        XCTAssertTrue(SonosManager.isQueueable(plexPlaylistContainer()))
    }

    // MARK: - Items without a URI are not queueable

    func testUPnPBrowseOnlyContainerIsNotQueueable() {
        XCTAssertFalse(SonosManager.isQueueable(upnpOnlyAlbumNoURI()),
                       "UPnP local-library albums arrive with nil resourceURI — they need a child-fetch path before queueing, not a direct enqueue.")
    }

    func testEmptyURIIsNotQueueable() {
        XCTAssertFalse(SonosManager.isQueueable(emptyURIItem()))
    }

    // MARK: - Mixed list — the typical Add All payload

    func testMixedListPreservesURIBearingItemsAndDropsURIless() throws {
        let items: [BrowseItem] = [
            spotifyTrack(),                  // track + URI         → queue
            spotifyAlbumContainer(),         // container + URI     → queue
            appleMusicAlbumContainer(),      // container + URI     → queue
            upnpOnlyAlbumNoURI(),            // container, no URI   → drop
            emptyURIItem(),                  // track, empty URI    → drop
            plexPlaylistContainer(),         // container + URI     → queue
        ]
        let queueable = items.filter(SonosManager.isQueueable)
        XCTAssertEqual(queueable.count, 4,
                       "4 of 6 items have URIs and must reach the SOAP layer; only the URI-less ones drop.")
        XCTAssertEqual(queueable.map(\.title),
                       ["Jingo", "Some Album", "AM Album", "Plex Mix"])
    }
}
