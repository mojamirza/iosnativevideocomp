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

    // Presets stored by versions that carried a softwareEncode flag (the
    // feature removed after it crashed on device) must still decode — the
    // unknown key is simply ignored by Codable.
    func testLegacySoftwareFlagDecodeIsTolerated() throws {
        let json = #"{"name":"sw","codec":"hevc","resolution":"keep","softwareEncode":true}"#
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(p.codec, .hevc)
    }

    // Built-in identity derives from a FIXED system key — renaming must not
    // reset the last-used selection or orphan stored references. The ids
    // are pinned to the EXACT literals Preset.stableID derives from those
    // keys. (The old test compared two accesses of the same static let —
    // equal by construction, it stayed green even if stableID was dropped
    // and every launch minted fresh UUID()s, which WOULD orphan stored
    // references on the first relaunch.)
    func testBuiltInIDsMatchThePinnedSystemKeys() {
        let pinned = [
            UUID(uuidString: "52da5dd1-46ad-440b-a35d-a36897c6de94")!,  // builtin.high
            UUID(uuidString: "c799358f-3d25-4f14-800d-9bbab2c91449")!,  // builtin.720p
            UUID(uuidString: "3644b565-468f-4a96-bb66-4ed313cb08ff")!,  // builtin.480p
            UUID(uuidString: "462aed8d-18bf-4a9e-a994-6851abea3b5f")!,  // builtin.lecture-small
            UUID(uuidString: "bd736547-35f1-450e-9ed9-b98274ec61d5")!,  // builtin.lecture-sharp
        ]
        XCTAssertEqual(Preset.builtIn.map(\.id), pinned)
    }
}
