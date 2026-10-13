import XCTest
@testable import EQCore

final class HeadphoneCatalogTests: XCTestCase {
    func testOfflineCatalogPreservesFiltersAndAttribution() throws {
        let profiles = try HeadphoneCatalog.bundled()
        XCTAssertEqual(profiles.count, 12_588)
        XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count)
        let names = try profiles.map { try $0.preset().name }
        XCTAssertEqual(Set(names).count, profiles.count)
        XCTAssertTrue(names.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(HeadphoneCatalog.excludedCount, 6)
        XCTAssertNotNil(HeadphoneCatalog.logoURL)
        XCTAssertNotNil(HeadphoneCatalog.licenseURL)
        XCTAssertFalse(profiles.contains(where: { $0.id == "ultrasone:edition_15::oratory1990_harman_target" }))
        XCTAssertFalse(profiles.contains(where: { $0.id == "tin_hifi:p1::oratory1990_harman_target" }))

        let profile = try XCTUnwrap(profiles.first(where: { $0.id == "sennheiser:hd_650::oratory1990_harman_target" }))
        XCTAssertEqual(profile.name, "Sennheiser HD 650")
        XCTAssertEqual(profile.creator, "oratory1990")
        let preset = try profile.preset()
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.preampDB, -9.3)
        XCTAssertEqual(preset.bands[2].type, .lowShelf)
        XCTAssertEqual(preset.bands[2].frequency, 105)
        XCTAssertEqual(preset.bands[2].gainDB, 5.5)
        XCTAssertEqual(preset.bands[2].q, 0.71)
        XCTAssertEqual(preset.bands[9].type, .highShelf)
        XCTAssertEqual(preset.bands[9].frequency, 11_000)
        XCTAssertTrue(preset.attribution?.contains("oratory1990") == true)
        XCTAssertTrue(preset.attribution?.contains("CC BY-SA 4.0") == true)
        XCTAssertTrue(preset.attribution?.contains(HeadphoneCatalog.sourceCommit) == true)
        let restored = try APOCodec.parse(APOCodec.export(preset), name: preset.name)
        XCTAssertEqual(restored.attribution, preset.attribution)
        for frequency in [20.0, 100, 1_000, 10_000, 20_000] {
            XCTAssertEqual(restored.responseDB(at: frequency, sampleRate: 48_000),
                           preset.responseDB(at: frequency, sampleRate: 48_000), accuracy: 0.000_001)
        }
    }

    func testInvalidCatalogIsRejectedAsAWhole() throws {
        let valid: [String: Any] = [
            "id": "example:headphone::creator", "name": "Example Headphone", "presetName": "Example Headphone — Creator", "creator": "Creator", "description": "Reference target",
            "sourceURL": "https://example.com/profile", "preampDB": -3,
            "bands": [["type": "peak", "frequency": 1_000, "gainDB": 3, "q": 1]],
        ]
        func decode(_ profiles: [[String: Any]], version: Int = 1, commit: String = HeadphoneCatalog.sourceCommit) throws -> [HeadphoneProfile] {
            try HeadphoneCatalog.decode(JSONSerialization.data(withJSONObject: ["version": version, "commit": commit, "profiles": profiles]))
        }
        let profile = try XCTUnwrap(decode([valid]).first)
        XCTAssertEqual(try profile.preset().bands[0].frequency, 1_000)
        XCTAssertThrowsError(try decode([valid, valid]))
        XCTAssertThrowsError(try decode([valid], version: 2))
        XCTAssertThrowsError(try decode([valid], commit: "unreviewed"))
        for (key, value) in [("sourceURL", "file:///tmp/profile"), ("name", "Invalid\nname"), ("creator", "")] {
            var invalid = valid
            invalid["id"] = "different"
            invalid[key] = value
            XCTAssertThrowsError(try decode([valid, invalid]))
        }
        for band in [
            ["type": "peak", "frequency": 8.5, "gainDB": 3, "q": 1] as [String: Any],
            ["type": "peak", "frequency": 1_000, "gainDB": 3, "q": 31],
            ["type": "unsupported", "frequency": 1_000, "gainDB": 3, "q": 1],
        ] {
            var invalid = valid
            invalid["id"] = "different"
            invalid["bands"] = [band]
            XCTAssertThrowsError(try decode([valid, invalid]))
        }
    }
}
