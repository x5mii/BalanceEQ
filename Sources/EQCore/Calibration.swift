// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Optional metadata; the ordered effective filters remain compatible with APO export.
public struct CalibrationSettings: Codable, Equatable, Sendable {
    public var measurementID: String
    public var sourceCommit: String
    public var customBandIDs: [UUID] = []
    public var customTargetEnabled = false
    public var automaticHeadroom = true
    public var targetID: String?
    public var targetMode: CalibrationTargetMode?
    public var customBase: CalibrationTargetMode?
    public init(measurementID: String, sourceCommit: String = CalibrationCatalog.sourceCommit) {
        self.measurementID = measurementID; self.sourceCommit = sourceCommit
    }
}

public struct CalibrationProfile: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let source: String
    public let variant: String
    public let targetName: String
    public let sourceURL: URL
    let offset: UInt64
    let length: Int

    public func loadCurve() throws -> CalibrationCurve {
        guard let url = HeadphoneCatalog.resourceBundle(for: .main)?.url(forResource: "calibration-curves", withExtension: "jsonl") else {
            throw EQError.invalid("Calibration measurements are missing. Reinstall BalanceEQ to restore them.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: length), data.count == length else {
            throw EQError.invalid("The selected measurement is incomplete.")
        }
        let curve = try JSONDecoder().decode(CalibrationCurve.self, from: data)
        try curve.validate()
        return curve
    }

    public func preset(curve: CalibrationCurve) throws -> EQPreset {
        try curve.validate()
        var result = EQPreset(name: String((name + " · Calibrated").prefix(100)), preampDB: curve.preampDB,
            bands: curve.bands.map(\.value),
            attribution: "\(source) • \(variant) • AutoEq \(CalibrationCatalog.sourceCommit) • \(sourceURL.absoluteString) • MIT; measurement and published target retained.")
        result.calibration = CalibrationSettings(measurementID: id)
        try result.validate()
        return result
    }
}

public enum CalibrationCatalog {
    public static let sourceCommit = "7ae0f56d53074872b028649617a22bbb4232feb7"
    public static func bundled() throws -> [CalibrationProfile] {
        guard let url = HeadphoneCatalog.resourceBundle(for: .main)?.url(forResource: "calibration-index", withExtension: "json") else {
            throw EQError.invalid("The calibration catalog is missing. Reinstall BalanceEQ to restore it.")
        }
        struct Index: Decodable { let version: Int; let commit: String; let profiles: [CalibrationProfile] }
        let data = try Data(contentsOf: url)
        guard data.count <= 16_777_216 else { throw EQError.invalid("Calibration catalog is too large.") }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version == 1, index.commit == sourceCommit, !index.profiles.isEmpty,
              index.profiles.count <= 20_000, Set(index.profiles.map(\.id)).count == index.profiles.count,
              index.profiles.allSatisfy({ p in
                  p.id.count == 24 && p.id.allSatisfy(\.isHexDigit) && !p.name.isEmpty && p.name.count <= 200 &&
                  p.length > 0 && p.length <= 1_048_576 && p.sourceURL.scheme == "https" && p.sourceURL.host == "github.com"
              }) else { throw EQError.invalid("The calibration catalog has unsupported or invalid entries.") }
        return index.profiles
    }
}

public struct CalibrationCurve: Decodable, Sendable {
    public let frequencies: [Double]
    public let measured: [Double]
    public let target: [Double]
    public let preampDB: Double
    public let bands: [Filter]
    public struct Filter: Decodable, Sendable {
        let type: EQFilterType; let enabled: Bool; let frequency: Double; let gainDB: Double; let q: Double
        var value: EQBand { EQBand(type: type, enabled: enabled, frequency: frequency, gainDB: gainDB, q: q) }
    }

    public func validate() throws {
        guard (2...8192).contains(frequencies.count), frequencies.count == measured.count,
              frequencies.count == target.count, frequencies.first! <= 20, frequencies.first! > 0,
              frequencies.last! >= 19900, frequencies.last! <= 96000,
              zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0 < $1 }),
              (frequencies + measured + target).allSatisfy(\.isFinite),
              (measured + target).allSatisfy({ abs($0) <= 200 }) else {
            throw EQError.invalid("The headphone measurement has invalid or incomplete frequency data.")
        }
        try EQPreset(name: "Calibration", preampDB: preampDB, bands: bands.map(\.value)).validate()
    }

    public struct Response: Sendable {
        public let frequencies: [Double]
        public let before: [Double]
        public let after: [Double]
        public let target: [Double]
    }

    /// A prediction in the published measurement's reference system, not an SPL measurement.
    public func response(preset: EQPreset, sampleRate: Double, bypassed: Bool, relative: Bool) throws -> Response {
        try validate()
        try preset.validate(sampleRate: bypassed ? nil : sampleRate)
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 384000 else { throw EQError.invalid("Unsupported sample rate.") }
        let maximum = min(20000, sampleRate * 0.49)
        let grid = (0...384).map { 20 * pow(maximum / 20, Double($0) / 384) }
        let raw = Self.interpolate(measured, frequencies: frequencies, at: grid)
        var reference = Self.interpolate(target, frequencies: frequencies, at: grid)
        if let id = preset.calibration?.targetID {
            let selected = try CalibrationTargets.bundled().target(id: id)
            let mode = preset.calibration?.targetMode
            let bass = mode == .harman || (mode == .custom && preset.calibration?.customBase == .harman)
            let anchor = Self.interpolate(target, frequencies: frequencies, at: [1000])[0]
            reference = selected.response(at: grid, bass: bass, anchor: anchor)
        }
        let customIDs = Set(preset.calibration?.customBandIDs ?? [])
        let custom = EQPreset(name: "Target", bands: preset.activeBands.filter { customIDs.contains($0.id) })
        let delta = custom.responseDB(at: grid, sampleRate: sampleRate)
        let desired = zip(reference, delta).map(+)
        let correction = bypassed ? grid.map { _ in 0.0 } : preset.responseDB(at: grid, sampleRate: sampleRate).map { $0 - preset.preampDB }
        guard (desired + correction).allSatisfy(\.isFinite) else { throw EQError.invalid("These filters cannot be plotted at this sample rate.") }
        let after = zip(raw, correction).map(+)
        return Response(frequencies: grid, before: relative ? zip(raw, desired).map(-) : raw,
                        after: relative ? zip(after, desired).map(-) : after,
                        target: relative ? grid.map { _ in 0 } : desired)
    }

    /// One fixed Neutral reference for before, after and target; deviations are never normalized away.
    public func result(preset: EQPreset, profile: CalibrationProfile, sampleRate: Double, bypassed: Bool) throws -> Response {
        let response = try response(preset: preset, sampleRate: sampleRate, bypassed: bypassed, relative: false)
        let anchor = Self.interpolate(target, frequencies: frequencies, at: [1000])[0]
        let neutral = try CalibrationTargets.bundled().target(for: profile, mode: .neutral)
        let baseline = neutral?.response(at: response.frequencies, bass: false, anchor: anchor)
            ?? Self.interpolate(target, frequencies: frequencies, at: response.frequencies)
        return Response(frequencies: response.frequencies, before: zip(response.before,baseline).map(-),
                        after: zip(response.after,baseline).map(-), target: zip(response.target,baseline).map(-))
    }

    static func interpolate(_ values: [Double], frequencies: [Double], at grid: [Double]) -> [Double] {
        var index = 0
        return grid.map { f in
            while index + 1 < frequencies.count - 1 && frequencies[index + 1] < f { index += 1 }
            let t = max(0, min(1, log(f / frequencies[index]) / log(frequencies[index + 1] / frequencies[index])))
            return values[index] + t * (values[index + 1] - values[index])
        }
    }
}
