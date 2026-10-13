import Foundation

public enum APOCodec {
    public static let maximumBytes = 65_536

    public static func parse(_ text: String, name: String) throws -> EQPreset {
        guard text.utf8.count <= maximumBytes else { throw EQError.invalid("APO files must be 64 KB or smaller.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var preset = EQPreset(name: name)
        var filterNumbers = Set<Int>()
        var foundPreamp = false
        var foundCommand = false
        for (index, rawLine) in normalized.components(separatedBy: "\n").enumerated() {
            let comment = rawLine.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if comment.lowercased().hasPrefix("# attribution:") {
                guard preset.attribution == nil else { throw EQError.line(index + 1, "Duplicate attribution comment.") }
                preset.attribution = String(comment.dropFirst("# attribution:".count)).trimmingCharacters(in: .whitespaces)
                do { try preset.validate() }
                catch { throw EQError.line(index + 1, error.localizedDescription) }
            }
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { continue }
            do {
                guard let colon = line.firstIndex(of: ":") else { throw EQError.invalid("Expected a command followed by ':'.") }
                let command = line[..<colon].split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                let values = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
                if command == ["preamp"] {
                    guard !foundPreamp else { throw EQError.invalid("Duplicate Preamp command.") }
                    guard values.count == 2, values[1].lowercased() == "db", let gain = Double(values[0]) else {
                        throw EQError.invalid("Expected Preamp: <gain> dB.")
                    }
                    preset.preampDB = gain
                    foundPreamp = true
                } else if command.count == 2, command[0] == "filter", let number = Int(command[1]), number > 0 {
                    guard filterNumbers.insert(number).inserted else { throw EQError.invalid("Duplicate filter number \(number).") }
                    guard preset.bands.count < 32 else { throw EQError.invalid("At most 32 filters are supported.") }
                    preset.bands.append(try parseFilter(values))
                } else {
                    throw EQError.invalid("Unsupported command. Only Preamp and numbered Filter commands are supported; Include, Device, Channel, expressions and other processing are not imported.")
                }
                try preset.validate()
                foundCommand = true
            } catch {
                throw EQError.line(index + 1, error.localizedDescription)
            }
        }
        guard foundCommand else { throw EQError.invalid("This file contains no supported EQ commands.") }
        try preset.validate()
        return preset
    }

    private static func parseFilter(_ values: [String]) throws -> EQBand {
        let tokens = values.map { $0.lowercased() }
        guard tokens.count >= 5, ["on", "off"].contains(tokens[0]), tokens[2] == "fc", tokens[4] == "hz",
              let frequency = apoFrequency(tokens[3]) else {
            throw EQError.invalid("Expected Filter <n>: ON|OFF <type> Fc <frequency> Hz …")
        }
        let type: EQFilterType
        switch tokens[1] {
        case "pk", "peq": type = .peak
        case "lsc": type = .lowShelf
        case "hsc": type = .highShelf
        case "lpq": type = .lowPass
        case "hpq": type = .highPass
        case "no": type = .notch
        default: throw EQError.invalid("Unsupported filter type. Use PK/PEQ, LSC/HSC, HPQ/LPQ, or NO with Q; shelf slopes and bandwidth forms are not supported.")
        }
        var gain = 0.0
        var q = 30.0 // Equalizer APO's default for a notch without an explicit Q.
        switch type {
        case .peak, .lowShelf, .highShelf:
            guard tokens.count == 10, tokens[5] == "gain", tokens[7] == "db", tokens[8] == "q",
                  let parsedGain = Double(tokens[6]), let parsedQ = Double(tokens[9]) else {
                throw EQError.invalid("This filter requires Gain <gain> dB Q <Q>; slope and bandwidth forms are unsupported.")
            }
            gain = parsedGain
            q = parsedQ
        case .lowPass, .highPass, .notch:
            if type == .notch && tokens.count == 5 { break }
            guard tokens.count == 7, tokens[5] == "q", let parsedQ = Double(tokens[6]) else {
                throw EQError.invalid("This filter requires Q <Q> (optional for NO).")
            }
            q = parsedQ
        }
        let band = EQBand(type: type, enabled: tokens[0] == "on", frequency: frequency, gainDB: gain, q: q)
        try band.validate()
        return band
    }

    private static func apoFrequency(_ token: String) -> Double? {
        guard var frequency = Double(token) else { return nil }
        // APO treats a trailing group of exactly three digits as thousands, unless an exponent is present.
        if !token.contains("e"), token.count >= 5, token[token.index(token.endIndex, offsetBy: -4)] == "." {
            frequency *= 1_000
        }
        return frequency
    }

    public static func export(_ preset: EQPreset) -> String {
        var lines = ["# Equalizer for Mac — supported Equalizer APO filters", "Preamp: \(preset.preampDB) dB"]
        if let attribution = preset.attribution { lines.insert("# Attribution: \(attribution)", at: 1) }
        for (index, band) in preset.bands.enumerated() {
            let type: String
            switch band.type {
            case .peak: type = "PK"
            case .lowShelf: type = "LSC"
            case .highShelf: type = "HSC"
            case .lowPass: type = "LPQ"
            case .highPass: type = "HPQ"
            case .notch: type = "NO"
            }
            // An explicit exponent prevents APO interpreting 31.125 Hz as 31,125 Hz.
            var frequency = String(band.frequency)
            if !frequency.lowercased().contains("e") { frequency += "e0" }
            var line = "Filter \(index + 1): \(band.enabled ? "ON" : "OFF") \(type) Fc \(frequency) Hz"
            if [.peak, .lowShelf, .highShelf].contains(band.type) { line += " Gain \(band.gainDB) dB" }
            lines.append(line + " Q \(band.q)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
