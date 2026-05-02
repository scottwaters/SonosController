/// BugReportBundle.swift — Assembles a diagnostic bundle for the
/// Diagnostics window's encrypted-report flow.
///
/// Produces a JSON envelope whose header is plaintext (so the
/// maintainer can sort received bundles without decrypting first) and
/// whose body is opaque ciphertext from `BugReportEncryptor`. The
/// header carries non-PII context only — Choragus version, macOS
/// version, build tag, locale, event count, timestamp.
///
/// Wire layout (UTF-8 JSON):
///
///   {
///     "format": "ChoragusBugBundle",
///     "formatVersion": 1,
///     "generatedAt": "2026-05-02T12:00:00Z",
///     "choragusVersion": "4.x",
///     "macOSVersion": "26.3.1",
///     "buildTag": "B2154",
///     "bundleId": "com.choragus.app",
///     "eventCount": 47,
///     "locale": "en_AU",
///     "encryptedBody": "<base64 of BugReportEncryptor.wrap(events.json)>"
///   }
///
/// The `encryptedBody` decrypts to a UTF-8 JSON array:
///
///   [
///     { "timestamp": "...", "level": "ERROR", "tag": "SOAP",
///       "message": "...", "context": "..." },
///     ...
///   ]
///
/// Wire format version is bumped whenever either layer's schema
/// changes.
import Foundation

public enum BugReportBundle {
    public enum Error: Swift.Error, LocalizedError {
        case envelopeAssembly
        case bodyEncoding
        case envelopeMalformed
        case bodyMalformed

        public var errorDescription: String? {
            switch self {
            case .envelopeAssembly: return "Could not assemble the bug-report envelope."
            case .bodyEncoding:     return "Could not encode the bug-report body."
            case .envelopeMalformed: return "Bug-report envelope is malformed."
            case .bodyMalformed:    return "Bug-report body is malformed."
            }
        }
    }

    public static let formatTag = "ChoragusBugBundle"
    public static let formatVersion: Int = 1

    /// Plain-Swift representation of one diagnostic entry as it
    /// appears inside the encrypted body. Intentionally a flat dict
    /// so the maintainer-side decrypt CLI doesn't need to import
    /// SonosKit.
    public struct EntryPayload: Codable {
        public let timestamp: String
        public let level: String
        public let tag: String
        public let message: String
        public let context: String?

        public init(timestamp: String, level: String, tag: String,
                    message: String, context: String?) {
            self.timestamp = timestamp
            self.level = level
            self.tag = tag
            self.message = message
            self.context = context
        }
    }

    /// Plaintext envelope read by the maintainer-side decrypt CLI
    /// before any unwrap happens. Lets the maintainer sort received
    /// bundles by version / macOS / timestamp without holding the
    /// private key locally.
    public struct Header: Codable {
        public let format: String
        public let formatVersion: Int
        public let generatedAt: String
        public let choragusVersion: String?
        public let macOSVersion: String?
        public let buildTag: String?
        public let bundleId: String?
        public let eventCount: Int
        public let locale: String?
        public let encryptedBody: String   // base64
    }

    /// Builds the envelope: serialises `entries` as JSON, runs the
    /// JSON through `BugReportEncryptor.wrap(...)`, base64-encodes the
    /// result, and wraps in the JSON header. Returns the file bytes
    /// the caller writes to disk.
    public static func assemble(entries: [EntryPayload]) throws -> Data {
        // 1. Encode the entry list as compact JSON.
        let bodyEncoder = JSONEncoder()
        bodyEncoder.outputFormatting = [.sortedKeys]
        let bodyJSON: Data
        do {
            bodyJSON = try bodyEncoder.encode(entries)
        } catch {
            throw Error.bodyEncoding
        }

        // 2. Wrap the body bytes for the maintainer's public key.
        let ciphertext = try BugReportEncryptor.wrap(bodyJSON)

        // 3. Build the plaintext header carrying non-PII context.
        let header = Header(
            format: formatTag,
            formatVersion: formatVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            choragusVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            buildTag: Bundle.main.infoDictionary?["ChoragusBuildTag"] as? String,
            bundleId: Bundle.main.bundleIdentifier,
            eventCount: entries.count,
            locale: Locale.current.identifier,
            encryptedBody: ciphertext.base64EncodedString()
        )

        // 4. Serialise the envelope.
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try envelopeEncoder.encode(header)
        } catch {
            throw Error.envelopeAssembly
        }
    }

    /// Reads the plaintext envelope without unwrapping the body. Used
    /// by the maintainer-side decrypt CLI to inspect provenance
    /// metadata before deciding whether to decrypt.
    public static func readHeader(_ envelopeBytes: Data) throws -> Header {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Header.self, from: envelopeBytes)
        } catch {
            throw Error.envelopeMalformed
        }
    }

    /// Full read + unwrap. Called by the maintainer-side CLI with the
    /// matching private key. Returns the entry list plus the header
    /// metadata.
    public static func decode(envelopeBytes: Data,
                              privateKey: Curve25519KeyAgreementPrivateKeyProtocol) throws
        -> (header: Header, entries: [EntryPayload])
    {
        let header = try readHeader(envelopeBytes)
        guard header.format == formatTag else { throw Error.envelopeMalformed }
        guard let ciphertext = Data(base64Encoded: header.encryptedBody) else {
            throw Error.envelopeMalformed
        }
        let bodyJSON = try privateKey.unwrap(envelope: ciphertext)
        let decoder = JSONDecoder()
        do {
            let entries = try decoder.decode([EntryPayload].self, from: bodyJSON)
            return (header, entries)
        } catch {
            throw Error.bodyMalformed
        }
    }
}

/// Indirection so the maintainer-side CLI can use `Curve25519` from
/// CryptoKit without taking a SonosKit dependency. The CLI conforms a
/// `CryptoKit.Curve25519.KeyAgreement.PrivateKey` to this protocol via
/// a small extension.
public protocol Curve25519KeyAgreementPrivateKeyProtocol {
    func unwrap(envelope: Data) throws -> Data
}
