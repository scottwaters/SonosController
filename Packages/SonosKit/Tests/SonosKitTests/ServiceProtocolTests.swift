/// ServiceProtocolTests.swift — Tests for protocol conformance, state mutation,
/// metadata enrichment, grace periods, and mock services.
import XCTest
@testable import SonosKit

// MARK: - TrackMetadata Enrichment Tests

final class TrackMetadataEnrichmentTests: XCTestCase {

    let testDevice = SonosDevice(id: "RINCON_TEST", ip: "192.168.1.10", port: 1400, roomName: "Living Room")

    func testEnrichFromMediaInfoSetsStationName() {
        var metadata = TrackMetadata(title: "", stationName: "")
        let mediaInfo: [String: String] = [
            "CurrentURIMetaData": "<DIDL-Lite><item><dc:title>Classic FM</dc:title><upnp:albumArtURI>/art.jpg</upnp:albumArtURI></item></DIDL-Lite>",
            "CurrentURI": "x-sonosapi-stream:s12345"
        ]
        metadata.enrichFromMediaInfo(mediaInfo, device: testDevice)
        XCTAssertEqual(metadata.stationName, "Classic FM")
        XCTAssertEqual(metadata.albumArtURI, "http://192.168.1.10:1400/art.jpg")
    }

    func testEnrichFromMediaInfoSetsTitleWhenEmpty() {
        var metadata = TrackMetadata(title: "", stationName: "existing")
        let mediaInfo: [String: String] = [
            "CurrentURIMetaData": "<DIDL-Lite><item><dc:title>Some Title</dc:title></item></DIDL-Lite>",
            "CurrentURI": "http://stream.example.com/audio"
        ]
        metadata.enrichFromMediaInfo(mediaInfo, device: testDevice)
        XCTAssertEqual(metadata.title, "Some Title")
        // Not radio, so station name unchanged
        XCTAssertEqual(metadata.stationName, "existing")
    }

    func testEnrichFromMediaInfoSkipsNotImplemented() {
        var metadata = TrackMetadata(title: "Original")
        let mediaInfo: [String: String] = [
            "CurrentURIMetaData": "NOT_IMPLEMENTED",
            "CurrentURI": "x-sonosapi-stream:s999"
        ]
        metadata.enrichFromMediaInfo(mediaInfo, device: testDevice)
        XCTAssertEqual(metadata.title, "Original")
    }

    func testEnrichFromMediaInfoSkipsEmptyDIDL() {
        var metadata = TrackMetadata(title: "Original")
        let mediaInfo: [String: String] = [
            "CurrentURIMetaData": "",
            "CurrentURI": "x-sonosapi-stream:s999"
        ]
        metadata.enrichFromMediaInfo(mediaInfo, device: testDevice)
        XCTAssertEqual(metadata.title, "Original")
    }

    func testEnrichFromMediaInfoHandlesXMLEscaped() {
        var metadata = TrackMetadata(title: "")
        let mediaInfo: [String: String] = [
            "CurrentURIMetaData": "&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Escaped Title&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;",
            "CurrentURI": "x-sonosapi-radio:r12345"
        ]
        metadata.enrichFromMediaInfo(mediaInfo, device: testDevice)
        XCTAssertEqual(metadata.title, "Escaped Title")
        XCTAssertEqual(metadata.stationName, "Escaped Title")
    }

    func testMakeAbsoluteURLConvertsRelativePath() {
        let device = SonosDevice(id: "RINCON_TEST", ip: "10.0.0.5", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL("/getaa?s=1"), "http://10.0.0.5:1400/getaa?s=1")
    }

    func testMakeAbsoluteURLLeavesAbsoluteUnchanged() {
        let device = SonosDevice(id: "RINCON_TEST", ip: "10.0.0.5", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL("http://example.com/art.jpg"), "http://example.com/art.jpg")
    }

    func testMakeAbsoluteURLHandlesEmptyString() {
        let device = SonosDevice(id: "RINCON_TEST", ip: "10.0.0.5", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL(""), "")
    }
}

// MARK: - Mock Services State Mutation Tests

@MainActor
final class MockServicesTests: XCTestCase {

    func testUpdateTransportState() async {
        let mock = MockSonosServices()
        mock.updateTransportState("group1", state: .playing)
        XCTAssertEqual(mock.groupTransportStates["group1"], .playing)
    }

    func testUpdateDeviceVolume() async {
        let mock = MockSonosServices()
        mock.updateDeviceVolume("dev1", volume: 42)
        XCTAssertEqual(mock.deviceVolumes["dev1"], 42)
    }

    func testUpdateDeviceMute() async {
        let mock = MockSonosServices()
        mock.updateDeviceMute("dev1", muted: true)
        XCTAssertEqual(mock.deviceMutes["dev1"], true)
    }

    func testUpdatePlayMode() async {
        let mock = MockSonosServices()
        mock.updatePlayMode("group1", mode: .shuffle)
        XCTAssertEqual(mock.groupPlayModes["group1"], .shuffle)
    }

    func testGracePeriodActivation() async {
        let mock = MockSonosServices()
        mock.setVolumeGrace(deviceID: "dev1", duration: 5)
        XCTAssertTrue(mock.isVolumeGraceActive(deviceID: "dev1"))
        XCTAssertFalse(mock.isVolumeGraceActive(deviceID: "dev2"))
    }

    func testMuteGracePeriod() async {
        let mock = MockSonosServices()
        mock.setMuteGrace(deviceID: "dev1", duration: 5)
        XCTAssertTrue(mock.isMuteGraceActive(deviceID: "dev1"))
        XCTAssertFalse(mock.isMuteGraceActive(deviceID: "dev2"))
    }

    func testPlayCallsTracked() async throws {
        let mock = MockSonosServices()
        let group = SonosGroup(id: "g1", coordinatorID: "RINCON_001", members: [
            SonosDevice(id: "RINCON_001", ip: "10.0.0.1", roomName: "Room")
        ])
        try await mock.play(group: group)
        XCTAssertTrue(mock.playCalled)
    }

    func testVolumeSetTracked() async throws {
        let mock = MockSonosServices()
        let device = SonosDevice(id: "RINCON_001", ip: "10.0.0.1", roomName: "Room")
        try await mock.setVolume(device: device, volume: 55)
        XCTAssertEqual(mock.lastSetVolume?.0, "RINCON_001")
        XCTAssertEqual(mock.lastSetVolume?.1, 55)
    }

    func testCacheArtURL() async {
        let mock = MockSonosServices()
        mock.cacheArtURL("http://art.jpg", forURI: "x-file://song.mp3", title: "Song", itemID: "FV:2/1")
        XCTAssertEqual(mock.discoveredArtURLs["x-file://song.mp3"], "http://art.jpg")
        XCTAssertEqual(mock.discoveredArtURLs["FV:2/1"], "http://art.jpg")
    }

    func testArtCacheLookup() async {
        let mock = MockSonosServices()
        mock.discoveredArtURLs["uri:123"] = "http://art.jpg"
        XCTAssertEqual(mock.lookupCachedArt(uri: "uri:123", title: ""), "http://art.jpg")
        XCTAssertNil(mock.lookupCachedArt(uri: "uri:999", title: ""))
    }
}

// MARK: - URI Prefix Tests

final class URIPrefixTests: XCTestCase {

    func testIsRadioDetectsStreamPrefix() {
        XCTAssertTrue(URIPrefix.isRadio("x-sonosapi-stream:s12345"))
        XCTAssertTrue(URIPrefix.isRadio("x-sonosapi-radio:r12345"))
        XCTAssertTrue(URIPrefix.isRadio("x-rincon-mp3radio://stream.com"))
    }

    func testIsRadioRejectsNonRadio() {
        XCTAssertFalse(URIPrefix.isRadio("x-sonos-http:song.mp3"))
        XCTAssertFalse(URIPrefix.isRadio("x-file-cifs://nas/music.mp3"))
        XCTAssertFalse(URIPrefix.isRadio(""))
    }

    func testIsLocalDetectsFileProtocols() {
        XCTAssertTrue(URIPrefix.isLocal("x-file-cifs://nas/music.mp3"))
        XCTAssertTrue(URIPrefix.isLocal("x-smb://server/share/song.flac"))
    }

    func testIsLocalRejectsStreaming() {
        XCTAssertFalse(URIPrefix.isLocal("x-sonosapi-stream:s12345"))
        XCTAssertFalse(URIPrefix.isLocal("x-sonos-http:song.mp3"))
    }
}
