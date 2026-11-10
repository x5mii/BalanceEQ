// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fits compatible targets and measured response using the existing native biquads.
/// No extra playback buffer or work on the audio thread.
enum TargetFitter {
    static func fit(frequencies: [Double], delta: [Double], sampleRate: Double, maximumBands: Int) throws -> [EQBand] {
        guard frequencies.count == delta.count, frequencies.count >= 2, delta.allSatisfy(\.isFinite),
              delta.allSatisfy({ abs($0) <= 40 }), sampleRate.isFinite, (8000...384000).contains(sampleRate),
              frequencies.allSatisfy({ $0.isFinite && $0 > 0 && $0 < sampleRate / 2 }), (0...6).contains(maximumBands) else {
            throw EQError.invalid("The selected target cannot be fitted safely.")
        }
        if delta.allSatisfy({ abs($0) < 0.02 }) { return [] }
        guard maximumBands > 0 else { throw EQError.invalid("Make room below the 32-band limit before applying this target.") }
        let maximum = min(16000, sampleRate * 0.45)
        let seeds: [(EQFilterType,Double)] = [(.lowShelf,105),(.highShelf,8000),(.peak,250),(.peak,1000),(.peak,3000),(.peak,6000)]
        let bands = seeds.prefix(maximumBands).map { EQBand(type: $0.0, frequency: min($0.1, maximum), q: 0.7) }
        return try optimize(bands: bands, frequencies: frequencies, delta: delta, sampleRate: sampleRate)
    }

    /// Refit the actual measurement, retaining the published correction as the fallback and treble anchor.
    static func fitMeasurement(frequencies: [Double], measured: [Double], target: [Double], seed: [EQBand], sampleRate: Double) throws -> [EQBand] {
        guard frequencies.count >= 2, measured.count == frequencies.count, target.count == frequencies.count,
              (frequencies + measured + target).allSatisfy(\.isFinite),
              zip(frequencies,frequencies.dropFirst()).allSatisfy({ $0 < $1 }),
              frequencies.allSatisfy({ $0 >= 20 && $0 < sampleRate / 2 }) else {
            throw EQError.invalid("The headphone measurement cannot be fitted safely.")
        }
        let original = EQPreset(name: "Published correction", bands: seed)
        try original.validate(sampleRate: sampleRate)
        let baseline = original.responseDB(at: frequencies, sampleRate: sampleRate)
        let error = zip(target,measured).map(-)
        // ponytail: model measurements cannot locate a listener's narrow treble resonances reliably.
        // Smooth the fit only, taper to the existing correction from 6–10 kHz, and keep the graph raw.
        let desired = frequencies.enumerated().map { i, frequency -> Double in
            let halfWidth = frequency < 2000 ? 1.0 / 12 : 1.0 / 6
            let neighbors = frequencies.indices.filter { abs(log2(frequencies[$0] / frequency)) <= halfWidth }
            let smoothed = neighbors.reduce(0.0) { $0 + error[$1] } / Double(neighbors.count)
            let strength = max(0, min(1, log(10000 / frequency) / log(10000.0 / 6000)))
            return strength * smoothed + (1 - strength) * baseline[i]
        }
        let fitted = try optimize(bands: seed, frequencies: frequencies, delta: desired, sampleRate: sampleRate, measurement: true)
        let response = EQPreset(name: "Measured fit", bands: fitted).responseDB(at: frequencies, sampleRate: sampleRate)
        func residual(_ correction: [Double]) -> Double {
            frequencies.indices.filter { frequencies[$0] <= 6000 }.reduce(0.0) { $0 + pow(correction[$1] - error[$1], 2) }
        }
        // Never trade a prettier smoothed objective for worse raw predicted accuracy in the fitted range.
        return residual(response) + 1e-9 < residual(baseline) ? fitted : seed
    }

    private static func optimize(bands initial: [EQBand], frequencies: [Double], delta: [Double], sampleRate: Double,
                                 measurement: Bool = false) throws -> [EQBand] {
        var bands = initial
        let maximum = min(measurement ? 6000 : 16000, sampleRate * 0.45)
        var curves = bands.map { EQPreset(name: "Fit band", bands: [$0]).responseDB(at: frequencies, sampleRate: sampleRate) }
        var total = curves.reduce(Array(repeating: 0.0, count: frequencies.count)) { zip($0,$1).map(+) }
        let baseline = total
        let boostCeiling = max(6, total.max() ?? 0)
        func loss(_ values: [Double]) -> Double { values.indices.reduce(0) { $0 + pow(values[$1] - delta[$1], 2) * (measurement && frequencies[$1] >= 10000 ? 4 : 1) } }
        var bestLoss = loss(total)
        // ponytail: bounded coordinate descent reuses the existing biquads; no runtime dependency or additional filter stage. Residuals stay visible.
        for step in [3.0, 1.5, 0.75, 0.3, 0.1] {
            for _ in 0..<(measurement ? 8 : 3) {
                try Task.checkCancellation()
                let previousLoss = bestLoss
                for i in bands.indices {
                    if measurement && (!bands[i].enabled || initial[i].frequency > maximum) { continue }
                    let others = zip(total,curves[i]).map(-)
                    for parameter in 0..<3 {
                        for direction in [-1.0,1] {
                            var candidate = bands[i]
                            switch parameter {
                            case 0: candidate.gainDB = max(measurement ? -24 : -12, min(measurement ? 24 : 12, candidate.gainDB + direction * step))
                            case 1: candidate.frequency = max(20, min(maximum, candidate.frequency * pow(2, direction * step / 3)))
                            default: candidate.q = max(0.3, min(candidate.type == .peak ? (measurement ? max(6,initial[i].q) : 3) : 0.7, candidate.q * pow(2, direction * step / 3)))
                            }
                            let response = EQPreset(name: "Target fitting", bands: [candidate]).responseDB(at: frequencies, sampleRate: sampleRate)
                            let combined = zip(others,response).map(+)
                            if measurement && combined.contains(where: { $0 > boostCeiling + 1e-9 }) { continue }
                            if measurement && frequencies.indices.contains(where: { frequencies[$0] >= 10000 && abs(combined[$0] - baseline[$0]) > 1 }) { continue }
                            let error = loss(combined)
                            if error + 1e-12 < bestLoss {
                                bands[i] = candidate; curves[i] = response; total = combined; bestLoss = error
                            }
                        }
                    }
                }
                if previousLoss - bestLoss < 1e-9 { break }
            }
        }
        return measurement ? bands : bands.filter { abs($0.gainDB) >= 0.02 }
    }
}
