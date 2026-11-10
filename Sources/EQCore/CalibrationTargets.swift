// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CalibrationTargetMode: String, Codable, CaseIterable, Sendable {
    case neutral, harman, custom
    public var title: String { rawValue.capitalized }
}

public struct CalibrationTarget: Decodable, Sendable {
    public let id: String
    public let name: String
    public let frequencies: [Double]
    public let levels: [Double]
    public let bassGain: Double
    public let sourceURL: URL

    /// Target data is acoustic and independent of the output's rate. AutoEq defines its preference shelf at 44.1 kHz.
    public func response(at grid: [Double], bass: Bool, anchor: Double) -> [Double] {
        let shelf = EQPreset(name: "Target bass", bands: [EQBand(type: .lowShelf, frequency: 105, gainDB: bass ? bassGain : 0, q: 0.7)])
        let values = CalibrationCurve.interpolate(levels, frequencies: frequencies, at: grid)
        let delta = shelf.responseDB(at: grid, sampleRate: 44100)
        let center = CalibrationCurve.interpolate(levels, frequencies: frequencies, at: [1000])[0] + shelf.responseDB(at: 1000, sampleRate: 44100)
        return zip(values, delta).map { $0 + $1 - center + anchor }
    }
}

public struct CalibrationTargets: Decodable, Sendable {
    let version: Int
    let commit: String
    public let targets: [CalibrationTarget]
    let matches: [String: [String: String]]
    private static let cached = Result { () throws -> CalibrationTargets in
        guard let url = HeadphoneCatalog.resourceBundle(for: .main)?.url(forResource: "calibration-targets", withExtension: "json") else {
            throw EQError.invalid("Calibration targets are missing. Reinstall BalanceEQ.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let ids = Set(value.targets.map(\.id))
        guard value.version == 1, value.commit == CalibrationCatalog.sourceCommit, ids.count == value.targets.count,
              value.targets.allSatisfy({ t in
                  t.id.count == 24 && t.id.allSatisfy(\.isHexDigit) && (2...8192).contains(t.frequencies.count) &&
                  t.frequencies.count == t.levels.count && t.frequencies.first! > 0 && t.frequencies.first! <= 20 && t.frequencies.last! >= 19900 &&
                  zip(t.frequencies,t.frequencies.dropFirst()).allSatisfy({ $0 < $1 }) &&
                  (t.frequencies + t.levels).allSatisfy(\.isFinite) && t.levels.allSatisfy({ abs($0) <= 200 }) &&
                  t.bassGain.isFinite && (0...12).contains(t.bassGain) && t.sourceURL.scheme == "https"
              }), value.matches.values.allSatisfy({ Set($0.values).isSubset(of: ids) }) else {
            throw EQError.invalid("Calibration target data is invalid.")
        }
        return value
    }
    public static func bundled() throws -> Self { try cached.get() }
    public func target(id: String) throws -> CalibrationTarget {
        guard let target = targets.first(where: { $0.id == id }) else { throw EQError.invalid("The saved target is unavailable. Your EQ still works; apply a supported target to restore the graph.") }
        return target
    }
    public func target(for profile: CalibrationProfile, mode: CalibrationTargetMode) -> CalibrationTarget? {
        guard let id = matches[profile.source + "/" + profile.variant]?[mode == .harman ? "harman" : "neutral"] else { return nil }
        return targets.first { $0.id == id }
    }
}

extension CalibrationProfile {
    public func calibrated(curve: CalibrationCurve, mode: CalibrationTargetMode, customBase: CalibrationTargetMode = .neutral,
                           customBands: [EQBand] = [], sampleRate: Double) throws -> EQPreset {
        guard customBase != .custom else { throw EQError.invalid("Choose Neutral or Harman as the custom target's base.") }
        let base = mode == .custom ? customBase : mode
        guard let target = try CalibrationTargets.bundled().target(for: self, mode: base) else {
            throw EQError.invalid("No compatible \(base.title) target is available for this measurement. Choose another measured variant or use Advanced EQ.")
        }
        var result = try preset(curve: curve)
        try result.validate(sampleRate: sampleRate)
        let grid = (0...191).map { 20 * pow(min(20000, sampleRate * 0.49) / 20, Double($0) / 191) }
        let reference = CalibrationCurve.interpolate(curve.target, frequencies: curve.frequencies, at: grid)
        let anchor = CalibrationCurve.interpolate(curve.target, frequencies: curve.frequencies, at: [1000])[0]
        let desired = target.response(at: grid, bass: base == .harman, anchor: anchor)
        let custom = mode == .custom ? customBands : []
        guard custom.count + result.bands.count <= 32 else { throw EQError.invalid("The correction and custom target exceed 32 bands.") }
        let adjustment = try TargetFitter.fit(frequencies: grid, delta: zip(desired, reference).map(-), sampleRate: sampleRate,
                                             maximumBands: min(6, 32 - result.bands.count - custom.count))
        result.bands += adjustment
        if base == .neutral {
            let fitGrid = (0...384).map { 20 * pow(min(20000, sampleRate * 0.49) / 20, Double($0) / 384) }
            let measured = CalibrationCurve.interpolate(curve.measured, frequencies: curve.frequencies, at: fitGrid)
            let fitTarget = target.response(at: fitGrid, bass: false, anchor: anchor)
            result.bands = try TargetFitter.fitMeasurement(frequencies: fitGrid, measured: measured, target: fitTarget,
                                                         seed: result.bands, sampleRate: sampleRate)
            result.calibration?.measurementFitVersion = 1
        }
        result.bands += custom
        result.name = String((name + " · " + mode.title).prefix(100))
        result.calibration?.targetID = target.id
        result.calibration?.targetMode = mode
        result.calibration?.customBase = base
        result.calibration?.customBandIDs = custom.map(\.id)
        result.calibration?.customTargetEnabled = mode == .custom
        result.preampDB = result.recommendedPreamp(sampleRate: sampleRate)
        try result.validate(sampleRate: sampleRate)
        return result
    }
}
