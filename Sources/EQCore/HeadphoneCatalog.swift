// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct HeadphoneProfile: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let creator: String
    public let description: String
    public let sourceURL: URL?
    private let presetName: String
    private let preampDB: Double
    private let bands: [Band]

    private struct Band: Decodable, Hashable, Sendable {
        let type: EQFilterType
        let frequency: Double
        let gainDB: Double
        let q: Double
        var value: EQBand { EQBand(type: type, frequency: frequency, gainDB: gainDB, q: q) }
    }

    public func preset() throws -> EQPreset {
        try validateMetadata()
        let credit = "\(creator) • \(description) • OPRA \(HeadphoneCatalog.upstreamURL.absoluteString) @ \(HeadphoneCatalog.sourceCommit) • Profile: \(id) • \(sourceURL?.absoluteString ?? "") • Profile data: CC BY-SA 4.0 https://creativecommons.org/licenses/by-sa/4.0/ • Converted to Equalizer for Mac format; editable."
        let preset = EQPreset(name: presetName, preampDB: preampDB, bands: bands.map(\.value), attribution: credit)
        try preset.validate()
        return preset
    }

    private func validateMetadata() throws {
        let fields = [id, name, creator, description, presetName]
        guard !id.isEmpty, id.count <= 200, !name.isEmpty, name.count <= 70,
              !creator.isEmpty, creator.count <= 25, description.count <= 200,
              fields.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              sourceURL == nil || (sourceURL?.scheme == "https" && sourceURL?.host != nil
                                  && sourceURL?.user == nil && sourceURL?.password == nil
                                  && (sourceURL?.absoluteString.count ?? 0) <= 300) else {
            throw EQError.invalid("The headphone profile contains invalid metadata.")
        }
    }
}

public enum HeadphoneCatalog {
    public static let sourceCommit = "0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865"
    public static let upstreamURL = URL(string: "https://github.com/opra-project/OPRA")!
    public static let excludedCount = 6
    public static var logoURL: URL? { resourceBundle(for: .main)?.url(forResource: "opra_logo_landscape", withExtension: "png") }
    public static var licenseURL: URL? { resourceBundle(for: .main)?.url(forResource: "OPRA-LICENSE", withExtension: "md") }

    static func resourceBundle(for app: Bundle) -> Bundle? {
        // SwiftPM 6.2's generated accessor does not search Contents/Resources.
        if app.bundleURL.pathExtension == "app" {
            return app.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("EqualizerForMac_EQCore.bundle")) }
        }
        return Bundle.module
    }

    private struct Index: Decodable {
        let version: Int
        let commit: String
        let profiles: [HeadphoneProfile]
    }

    public static func bundled() throws -> [HeadphoneProfile] {
        guard let url = resourceBundle(for: .main)?.url(forResource: "headphones", withExtension: "json") else {
            throw EQError.invalid("The headphone catalog is missing. Reinstall the app to restore it.")
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [HeadphoneProfile] {
        guard data.count <= 16_777_216 else { throw EQError.invalid("The headphone catalog is too large.") }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version == 1, index.commit == sourceCommit, !index.profiles.isEmpty,
              index.profiles.count <= 20_000,
              Set(index.profiles.map(\.id)).count == index.profiles.count else {
            throw EQError.invalid("The headphone catalog has an unsupported version or invalid entries.")
        }
        for profile in index.profiles { _ = try profile.preset() }
        return index.profiles
    }
}
