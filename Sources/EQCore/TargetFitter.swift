// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fits the smooth difference between two compatible targets. The measured AutoEq correction remains the seed.
/// No measurement inversion, extra playback buffer or work on the audio thread.
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
        var bands = seeds.prefix(maximumBands).map { EQBand(type: $0.0, frequency: min($0.1, maximum), q: 0.7) }
        var curves = bands.map { _ in Array(repeating: 0.0, count: frequencies.count) }
        var total = Array(repeating: 0.0, count: frequencies.count)
        func loss(_ values: [Double]) -> Double { zip(values,delta).reduce(0) { $0 + pow($1.0 - $1.1, 2) } }
        var bestLoss = loss(total)
        // ponytail: bounded coordinate descent over six broad target filters; residuals remain visible. Use a larger optimizer only if measured target-fit error warrants it.
        for step in [3.0, 1.5, 0.75, 0.3, 0.1] {
            for _ in 0..<3 {
                try Task.checkCancellation()
                for i in bands.indices {
                    let others = zip(total,curves[i]).map(-)
                    for parameter in 0..<3 {
                        for direction in [-1.0,1] {
                            var candidate = bands[i]
                            switch parameter {
                            case 0: candidate.gainDB = max(-12, min(12, candidate.gainDB + direction * step))
                            case 1: candidate.frequency = max(20, min(maximum, candidate.frequency * pow(2, direction * step / 3)))
                            default: candidate.q = max(0.3, min(candidate.type == .peak ? 3 : 0.7, candidate.q * pow(2, direction * step / 3)))
                            }
                            let response = EQPreset(name: "Target fitting", bands: [candidate]).responseDB(at: frequencies, sampleRate: sampleRate)
                            let combined = zip(others,response).map(+)
                            let error = loss(combined)
                            if error + 1e-12 < bestLoss {
                                bands[i] = candidate; curves[i] = response; total = combined; bestLoss = error
                            }
                        }
                    }
                }
            }
        }
        return bands.filter { abs($0.gainDB) >= 0.02 }
    }
}
