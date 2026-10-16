import Foundation
import CEQ

public enum EQFilterType: String, Codable, CaseIterable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch

    public var title: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low pass"
        case .highPass: "High pass"
        case .notch: "Notch"
        }
    }

    var cValue: Int32 {
        switch self {
        case .peak: 0
        case .lowShelf: 1
        case .highShelf: 2
        case .lowPass: 3
        case .highPass: 4
        case .notch: 5
        }
    }
}

public enum EQError: Error, LocalizedError, Equatable {
    case invalid(String)
    case line(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .line(let number, let message): "Line \(number): \(message)"
        }
    }
}

public struct EQBand: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var type: EQFilterType
    public var enabled: Bool
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(id: UUID = UUID(), type: EQFilterType = .peak, enabled: Bool = true,
                frequency: Double = 1_000, gainDB: Double = 0, q: Double = 1) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    func validate(sampleRate: Double? = nil) throws {
        guard frequency.isFinite, (10...20_000).contains(frequency) else {
            throw EQError.invalid("Frequency must be between 10 and 20,000 Hz.")
        }
        guard gainDB.isFinite, (-24...24).contains(gainDB) else {
            throw EQError.invalid("Band gain must be between −24 and +24 dB.")
        }
        guard q.isFinite, (0.1...30).contains(q) else {
            throw EQError.invalid("Q must be between 0.1 and 30.")
        }
        if enabled, let sampleRate, frequency >= sampleRate / 2 {
            throw EQError.invalid("The active \(frequency.formatted()) Hz band must be below \((sampleRate / 2).formatted()) Hz for this output. Disable it or lower its frequency.")
        }
    }

    var cBand: CEQ.EQBand {
        CEQ.EQBand(type: type.cValue, enabled: enabled ? 1 : 0,
                   frequency: frequency, gainDB: gainDB, q: q)
    }
}

public struct EQPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var preampDB: Double
    public var bands: [EQBand]
    public var version: Int
    public var attribution: String?

    public init(id: UUID = UUID(), name: String, preampDB: Double = 0,
                bands: [EQBand] = [], version: Int = 1, attribution: String? = nil) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
        self.version = version
        self.attribution = attribution
    }

    public static var flat: EQPreset {
        EQPreset(name: "Flat", bands: [31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
            .map { EQBand(frequency: $0) })
    }

    public func validate(sampleRate: Double? = nil) throws {
        guard version == 1 else { throw EQError.invalid("Unsupported preset version \(version).") }
        if let attribution {
            guard attribution.count <= 1_000, !attribution.contains(where: { $0.isNewline }) else {
                throw EQError.invalid("Profile attribution must be a single line of at most 1,000 characters.")
            }
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
            throw EQError.invalid("Preset names must contain 1–100 characters.")
        }
        guard preampDB.isFinite, (-60...12).contains(preampDB) else {
            throw EQError.invalid("Preamp must be between −60 and +12 dB.")
        }
        guard bands.count <= 32 else { throw EQError.invalid("A preset supports at most 32 bands.") }
        guard Set(bands.map(\.id)).count == bands.count else {
            throw EQError.invalid("Preset contains duplicate band identifiers.")
        }
        if let sampleRate {
            guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else {
                throw EQError.invalid("Unsupported output sample rate.")
            }
        }
        for band in bands { try band.validate(sampleRate: sampleRate) }
    }

    public func parameters(sampleRate: Double, bypassed: Bool = false) throws -> CEQ.EQParameters {
        // Bypass still validates stored data, but inactive filters do not constrain the route.
        try validate(sampleRate: bypassed ? nil : sampleRate)
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else {
            throw EQError.invalid("Unsupported output sample rate.")
        }
        var result = CEQ.EQParameters()
        result.count = UInt32(bands.count)
        result.preampDB = preampDB
        result.bypass = bypassed ? 1 : 0
        for (index, band) in bands.enumerated() {
            guard eq_parameters_set_band(&result, UInt32(index), band.cBand) else {
                throw EQError.invalid("The audio engine rejected band \(index + 1).")
            }
        }
        return result
    }

    /// Uses the engine's exact coefficients. Invalid routes produce no drawable response.
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        guard frequency.isFinite, frequency > 0, frequency < sampleRate / 2,
              (try? validate(sampleRate: sampleRate)) != nil else { return .nan }
        return preampDB + bands.filter(\.enabled).reduce(0) {
            $0 + eq_response_db($1.cBand, sampleRate, frequency)
        }
    }

    /// Prepare coefficients once per curve, rather than once per frequency and band.
    public func responseDB(at frequencies: [Double], sampleRate: Double) -> [Double] {
        guard (try? validate(sampleRate: sampleRate)) != nil else {
            return frequencies.map { _ in .nan }
        }
        var coefficients: [[Double]] = []
        for band in bands where band.enabled {
            var c = [Double](repeating: 0, count: 5)
            guard eq_coefficients(band.cBand, sampleRate, &c) else { return frequencies.map { _ in .nan } }
            coefficients.append(c)
        }
        return frequencies.map { frequency in
            guard frequency.isFinite, frequency > 0, frequency < sampleRate / 2 else { return .nan }
            let w = 2 * Double.pi * frequency / sampleRate
            let c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w)
            return coefficients.reduce(preampDB) { total, c in
                total + 20 * log10(hypot(c[0] + c[1] * c1 + c[2] * c2, -c[1] * s1 - c[2] * s2) /
                                  hypot(1 + c[3] * c1 + c[4] * c2, -c[3] * s1 - c[4] * s2))
            }
        }
    }

    /// Approximate steady-state headroom, bounded by the preamp control; not a peak limiter.
    public func recommendedPreamp(sampleRate: Double) -> Double {
        guard (try? validate(sampleRate: sampleRate)) != nil else { return .nan }
        let upper = min(20_000, sampleRate / 2 * 0.999)
        // ponytail: sampled response estimate; use peak optimization if precise headroom is needed.
        let frequencies = (0...1_024).map { 10 * pow(upper / 10, Double($0) / 1_024) }
            + bands.filter(\.enabled).map(\.frequency)
        let peak = responseDB(at: frequencies, sampleRate: sampleRate).reduce(0.0) { max($0, $1 - preampDB) }
        return max(-60, min(0, -peak))
    }
}
