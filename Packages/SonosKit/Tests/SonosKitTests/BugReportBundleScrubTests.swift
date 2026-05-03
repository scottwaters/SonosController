/// BugReportBundleScrubTests.swift — Pin the bundle-export contract:
/// every payload string that leaves the process via `BugReportBundle`
/// must have run through `DiagnosticsRedactor.scrubForPublicOutput`
/// first, even though the body is encrypted to the maintainer's pubkey.
///
/// This test exists because the bundle path silently shipped raw `sn=`
/// account bindings to GitHub for one release (the diagnostic side of
/// issue #19) — the redactor was correct, but the assembly path didn't
/// apply it. The pre-fix DiagnosticsView built `EntryPayload` from raw
/// `e.message` and `e.contextJSON`, so anything below the
/// scrubForPublicOutput barrier reached the encrypted body in
/// cleartext. After the fix, callers compose
/// `BugReportBundle.scrubForPublicOutput` then `assemble`, and this
/// test pins the helper's behaviour.
import XCTest
import CryptoKit
@testable import SonosKit

final class BugReportBundleScrubTests: XCTestCase {

    private func makeRawEntry(message: String, context: String?) -> BugReportBundle.EntryPayload {
        BugReportBundle.EntryPayload(
            timestamp: "2026-05-02T13:10:53Z",
            level: "ERROR",
            tag: "PLAYBACK",
            message: message,
            context: context
        )
    }

    /// The exact signature of issue #19's bundle leak: a context blob
    /// carrying `sn=274` and a LAN URL. After the helper, neither must
    /// survive — but `sid=` is preserved because it's diagnostic gold.
    func testScrubRemovesSnAndLANIPFromContext() {
        let raw = makeRawEntry(
            message: "Direct play failed for Jingo",
            context: "{\"uri\":\"x-sonos-http:spotify%3atrack%3aXYZ?sid=9&flags=8224&sn=274\",\"url\":\"http://192.168.1.12:1400/MediaRenderer/AVTransport/Control\"}"
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])

        XCTAssertEqual(scrubbed.count, 1)
        let ctx = scrubbed[0].context ?? ""
        XCTAssertFalse(ctx.contains("sn=274"),
                       "Pre-fix bundle leaked sn= account bindings — regression guard.")
        XCTAssertTrue(ctx.contains("sn=*"))
        XCTAssertTrue(ctx.contains("sid=9"),
                      "sid= is the maintainer's primary diagnostic signal — must survive scrub.")
        XCTAssertFalse(ctx.contains("192.168.1.12"))
        XCTAssertTrue(ctx.contains("<lan-ip>"))
    }

    func testScrubAppliesToMessageNotJustContext() {
        let raw = makeRawEntry(
            message: "Failed to write \(NSHomeDirectory())/Library/Caches/foo",
            context: nil
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertFalse(scrubbed[0].message.contains(NSHomeDirectory()),
                       "Message strings must also pass through scrubForPublicOutput — not just context.")
        XCTAssertTrue(scrubbed[0].message.contains("~/"))
    }

    func testScrubLeavesNonPIIFieldsUntouched() {
        let raw = makeRawEntry(
            message: "Direct play failed for Jingo",
            context: "{\"service\":\"Spotify\",\"title\":\"Jingo\",\"artist\":\"Candido\",\"sid\":\"9\"}"
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertEqual(scrubbed[0].message, "Direct play failed for Jingo",
                       "Plain prose with no PII signatures passes through unchanged.")
        XCTAssertEqual(scrubbed[0].context,
                       "{\"service\":\"Spotify\",\"title\":\"Jingo\",\"artist\":\"Candido\",\"sid\":\"9\"}",
                       "Service name, title, artist, sid all stay — they're either public or load-bearing for diagnosis.")
    }

    func testScrubHandlesNilContext() {
        let raw = makeRawEntry(message: "Plain message", context: nil)
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertNil(scrubbed[0].context)
        XCTAssertEqual(scrubbed[0].message, "Plain message")
    }

    func testScrubPreservesEntryStructureAndOrder() {
        let raws = (0..<5).map { i in
            BugReportBundle.EntryPayload(
                timestamp: "T\(i)",
                level: "INFO",
                tag: "TAG\(i)",
                message: "msg \(i)",
                context: nil
            )
        }
        let scrubbed = BugReportBundle.scrubForPublicOutput(raws)
        XCTAssertEqual(scrubbed.count, 5)
        XCTAssertEqual(scrubbed.map(\.timestamp), raws.map(\.timestamp))
        XCTAssertEqual(scrubbed.map(\.level), raws.map(\.level))
        XCTAssertEqual(scrubbed.map(\.tag), raws.map(\.tag))
    }

    /// Round-trip test: build raw entries containing PII, scrub via the
    /// helper, encrypt with a test keypair, decrypt with the matching
    /// private key, and assert the decrypted JSON contains no leaked
    /// values. This is the literal end-to-end path a real bundle takes
    /// — minus the Info.plist read for the maintainer pubkey, which is
    /// stubbed via the direct-key `wrap(_:for:)` overload.
    func testEncryptedBundleRoundTripContainsNoLeakedSecrets() throws {
        let raws = [
            makeRawEntry(
                message: "Direct play failed",
                context: "{\"uri\":\"x-sonos-http:spotify%3atrack%3aXYZ?sid=9&sn=274\",\"url\":\"http://192.168.1.12:1400/X\"}"
            ),
            makeRawEntry(
                message: "Token refresh: Bearer eyJSecretBlobABCDEF",
                context: "{\"path\":\"\(NSHomeDirectory())/Library/Caches/foo\"}"
            ),
        ]
        let scrubbed = BugReportBundle.scrubForPublicOutput(raws)

        // Drive the encryptor with a freshly-minted keypair so the
        // test doesn't depend on the production Info.plist slot.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let plaintextJSON = try JSONEncoder().encode(scrubbed)
        let envelope = try BugReportEncryptor.wrap(plaintextJSON, for: priv.publicKey)

        // Round-trip through the static decryptor.
        let decrypted = try BugReportEncryptor.unwrap(envelope, with: priv)
        let roundTripped = try JSONDecoder().decode([BugReportBundle.EntryPayload].self, from: decrypted)
        XCTAssertEqual(roundTripped.count, scrubbed.count)

        // The decrypted body — what the maintainer actually reads —
        // must not contain any of the user's private values.
        let combined = roundTripped
            .map { ($0.message) + " " + ($0.context ?? "") }
            .joined(separator: " ")

        XCTAssertFalse(combined.contains("sn=274"),
                       "Encrypted bundle must not carry the user's SMAPI account binding through to the decrypted view.")
        XCTAssertFalse(combined.contains("192.168.1.12"),
                       "Encrypted bundle must not carry LAN IPs.")
        XCTAssertFalse(combined.contains(NSHomeDirectory()),
                       "Encrypted bundle must not carry the user's home directory.")
        XCTAssertFalse(combined.contains("eyJSecretBlobABCDEF"),
                       "Encrypted bundle must not carry Bearer tokens.")

        // sid= is the explicit not-PII exception — keep it for diagnosis.
        XCTAssertTrue(combined.contains("sid=9"),
                      "sid= must survive end-to-end so the maintainer can identify which SMAPI service the row references.")
    }
}

