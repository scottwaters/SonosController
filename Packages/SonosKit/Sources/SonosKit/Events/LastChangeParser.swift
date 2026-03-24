/// LastChangeParser.swift — Parses UPnP LastChange XML from Sonos event notifications.
///
/// Sonos event NOTIFY bodies wrap state changes in a double-encoded format:
/// 1. Outer: XML propertyset envelope
/// 2. Inner: XML-escaped LastChange containing self-closing elements with val attributes
///
/// AVTransport events contain: TransportState, CurrentTrackMetaData, CurrentPlayMode, etc.
/// RenderingControl events contain: Volume, Mute, Bass, Treble, Loudness per channel.
/// ZoneGroupTopology events contain: ZoneGroupState as XML.
import Foundation

// MARK: - Event Data Types

public struct AVTransportEventData {
    public var transportState: TransportState?
    public var currentTrackMetaData: String?    // Raw DIDL-Lite XML
    public var currentTrackURI: String?
    public var currentPlayMode: PlayMode?
    public var currentTrackDuration: String?
    public var numberOfTracks: Int?
    public var currentSection: Int?
}

public struct RenderingControlEventData {
    public var volume: Int?
    public var mute: Bool?
    public var bass: Int?
    public var treble: Int?
    public var loudness: Bool?
}

// MARK: - Parser

public enum LastChangeParser {

    /// Extracts the LastChange XML from a UPnP NOTIFY propertyset body
    /// and parses it into key-value pairs from the val attributes.
    public static func parsePropertySet(_ xml: String) -> [String: String] {
        // Step 1: Extract the LastChange content from the propertyset
        guard let lastChangeContent = extractLastChange(from: xml) else {
            return [:]
        }

        // Step 2: Unescape the XML-escaped LastChange content
        let unescaped = XMLResponseParser.xmlUnescape(lastChangeContent)

        // Step 3: Parse the inner Event XML to extract val attributes
        return parseEventXML(unescaped)
    }

    /// Parses an AVTransport event NOTIFY body into structured data
    public static func parseAVTransportEvent(_ xml: String) -> AVTransportEventData {
        let values = parsePropertySet(xml)
        var event = AVTransportEventData()

        if let stateStr = values["TransportState"] {
            event.transportState = TransportState(rawValue: stateStr)
        }
        event.currentTrackMetaData = values["CurrentTrackMetaData"]
        event.currentTrackURI = values["CurrentTrackURI"]
        if let modeStr = values["CurrentPlayMode"] {
            event.currentPlayMode = PlayMode(rawValue: modeStr)
        }
        event.currentTrackDuration = values["CurrentTrackDuration"]
        if let numStr = values["NumberOfTracks"] {
            event.numberOfTracks = Int(numStr)
        }
        if let secStr = values["CurrentSection"] {
            event.currentSection = Int(secStr)
        }

        return event
    }

    /// Parses a RenderingControl event NOTIFY body into structured data
    public static func parseRenderingControlEvent(_ xml: String) -> RenderingControlEventData {
        let values = parsePropertySet(xml)
        var event = RenderingControlEventData()

        // Volume comes as channel-specific: look for Master channel
        if let volStr = values["Volume"] {
            event.volume = Int(volStr)
        }
        if let muteStr = values["Mute"] {
            event.mute = muteStr == "1"
        }
        if let bassStr = values["Bass"] {
            event.bass = Int(bassStr)
        }
        if let trebleStr = values["Treble"] {
            event.treble = Int(trebleStr)
        }
        if let loudStr = values["Loudness"] {
            event.loudness = loudStr == "1"
        }

        return event
    }

    /// Extracts raw ZoneGroupState from a topology event
    public static func parseTopologyEvent(_ xml: String) -> [ZoneGroupData]? {
        let values = parsePropertySet(xml)
        guard let zoneGroupState = values["ZoneGroupState"] else { return nil }
        // The ZoneGroupState is further XML-escaped inside the event
        return XMLResponseParser.parseZoneGroupState(zoneGroupState)
    }

    // MARK: - Private Helpers

    /// Finds <LastChange>...</LastChange> or <ZoneGroupState>...</ZoneGroupState>
    /// content inside a propertyset envelope
    private static func extractLastChange(from xml: String) -> String? {
        // Try LastChange first (AVTransport, RenderingControl)
        if let content = extractElement("LastChange", from: xml) {
            return content
        }
        // Try ZoneGroupState (ZoneGroupTopology)
        if let content = extractElement("ZoneGroupState", from: xml) {
            return content
        }
        // Fallback: maybe it's already just the inner XML
        if xml.contains("val=") {
            return xml
        }
        return nil
    }

    private static func extractElement(_ name: String, from xml: String) -> String? {
        guard let startRange = xml.range(of: "<\(name)>") else { return nil }
        let afterStart = startRange.upperBound
        guard let endRange = xml.range(of: "</\(name)>", range: afterStart..<xml.endIndex) else { return nil }
        return String(xml[afterStart..<endRange.lowerBound])
    }

    /// Parses Event XML where values are in val="" attributes on self-closing elements.
    /// Example: <TransportState val="PLAYING"/>
    /// Also handles channel-qualified elements like <Volume channel="Master" val="42"/>
    private static func parseEventXML(_ xml: String) -> [String: String] {
        let parser = EventXMLParser()
        return parser.parse(xml)
    }
}

// MARK: - SAX Parser for Event XML

/// Parses UPnP event XML where state values are in val="" attributes.
/// Handles both simple elements (<TransportState val="PLAYING"/>)
/// and channel-qualified elements (<Volume channel="Master" val="42"/>).
private class EventXMLParser: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]

    func parse(_ xml: String) -> [String: String] {
        guard let data = xml.data(using: .utf8) else { return [:] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard let val = attributes["val"] else { return }

        // Strip namespace prefix
        let name = elementName.components(separatedBy: ":").last ?? elementName

        // Skip InstanceID element
        guard name != "InstanceID" && name != "Event" else { return }

        // For channel-qualified elements, only keep Master channel
        if let channel = attributes["channel"] {
            if channel == "Master" {
                values[name] = val
            }
            // Skip non-Master channels (LF, RF, etc.)
        } else {
            values[name] = val
        }
    }
}
