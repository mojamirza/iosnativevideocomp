import XCTest
@testable import VidCompress

/// Preset persistence contract: legacy display-string decodes, range
/// clamping on untrusted values, stable built-in identity, and the
/// software-encode flag round-trip.
final class PresetTests: XCTestCase {

    // Older builds persisted DISPLAY strings as codec/resolution raw values;
    // init(from:) must accept both spellings.
    func testLegacyDisplayStringDecoding() throws {
        let json = #"{"name":"Old","codec":"HEVC (H.265)","resolution":"1080p"}"#
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(p.codec, .hevc)
        XCTAssertEqual(p.resolution, .fhd)
    }

    // A hand-edited store must never reach the engine with out-of-range
    // values (e.g. a huge fps cap would trap CMTimeScale inside VT helpers).
    func testValuesAreClampedOnConstruction() {
        let p = Preset(name: "clamp", codec: .hevc, resolution: .keep,
                       fixedBitrateMbps: 100, fpsCap: 1000,
                       audioBitrateKbps: 1000, targetSizeMB: 5000,
                       audioChannels: 7)
        XCTAssertEqual(p.fixedBitrateMbps, Preset.bitrateRange.upperBound)
        XCTAssertEqual(p.fpsCap, Preset.fpsCapRange.upperBound)
        XCTAssertEqual(p.audioBitrateKbps, Preset.audioRange.upperBound)
        XCTAssertEqual(p.targetSizeMB, 2000)
        XCTAssertEqual(p.audioChannels, 2)
    }

    func testSoftwareEncodeRoundTrip() throws {
        var p = Preset(name: "sw", codec: .hevc, resolution: .keep)
        p.softwareEncode = true
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(back.softwareEncode, true)
        XCTAssertEqual(back.id, p.id)
    }

    func testDefaultPresetHasNoSoftwareFlag() throws {
        let p = Preset(name: "hw", codec: .h264, resolution: .fhd)
        XCTAssertNil(p.softwareEncode)
        let back = try JSONDecoder().decode(Preset.self, from: try JSONEncoder().encode(p))
        XCTAssertNil(back.softwareEncode)
    }

    // Built-in identity derives from a FIXED system key — renaming must not
    // reset the last-used selection or orphan stored references.
    func testBuiltInIDsAreStableAcrossAccesses() {
        let first = Preset.builtIn.map(\.id)
        let second = Preset.builtIn.map(\.id)
        XCTAssertEqual(first, second)
    }
}
