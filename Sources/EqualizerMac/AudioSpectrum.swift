// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import CEQ
import Foundation
import Combine

struct Spectrum: Equatable, Sendable {
    var before: [Double] = []
    var after: [Double] = []
    var sampleRate: Double = 48000
}

@MainActor
final class SpectrumModel: ObservableObject {
    @Published var frame = Spectrum()
}

/// Runs only on the serial audio control queue, never inside the audio callback.
final class AudioSpectrum {
    static let count = Int(EQ_ANALYSIS_FRAMES)
    private let setup: vDSP_DFT_Setup
    private var samples = [Float](repeating: 0, count: 4 * count)
    private let window = (0..<count).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count))) }
    private let imaginary = [Float](repeating: 0, count: count)
    private var input = [Float](repeating: 0, count: count)
    private var real = [Float](repeating: 0, count: count)
    private var imag = [Float](repeating: 0, count: count)

    init?() {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.count), .FORWARD) else { return nil }
        self.setup = setup
    }
    deinit { vDSP_DFT_DestroySetup(setup) }

    func discard(_ dsp: OpaquePointer) {
        _ = eq_dsp_read_analysis(dsp, &samples, UInt32(samples.count))
    }

    func read(_ dsp: OpaquePointer, sampleRate: Double) -> Spectrum? {
        defer { eq_dsp_request_analysis(dsp) }
        guard eq_dsp_read_analysis(dsp, &samples, UInt32(samples.count)) else { return nil }
        return transform(samples, sampleRate: sampleRate)
    }

    private func transform(_ channels: [Float], sampleRate: Double) -> Spectrum {
        let n = Self.count
        let scale = pow(2.0 / Double(window.reduce(0, +)), 2)
        var powers = [[Double]](repeating: [Double](repeating: 0, count: n / 2), count: 2)
        for channel in 0..<4 {
            for i in 0..<n { input[i] = channels[channel * n + i] * window[i] }
            vDSP_DFT_Execute(setup, input, imaginary, &real, &imag)
            for bin in 1..<n / 2 {
                powers[channel / 2][bin] += (Double(real[bin]) * Double(real[bin]) + Double(imag[bin]) * Double(imag[bin])) * scale / 2
            }
        }
        // Stereo power average prevents opposite-phase channels from cancelling visually.
        let db = powers.map { $0.map { power in
            let value = 10 * log10(max(1e-10, power))
            // An over-range input can overflow the float FFT; saturate the display safely.
            return value.isFinite ? min(120, max(-100, value)) : 120
        } }
        return Spectrum(before: db[0], after: db[1], sampleRate: sampleRate)
    }

    #if DEBUG
    static func check() {
        let analyzer = AudioSpectrum()!
        for rate in [44100.0, 48000, 96000] {
            let tone = (0..<count).map { Float(0.5 * sin(2 * .pi * 32 * Double($0) / Double(count))) }
            let result = analyzer.transform(tone + tone.map { -$0 } + tone.map { $0 * 0.5 } + tone.map { -$0 * 0.5 }, sampleRate: rate)
            precondition(abs(result.before[32] + 6.0206) < 0.01)
            precondition(abs(result.after[32] - result.before[32] + 6.0206) < 0.01)
            precondition(result.sampleRate == rate && result.before.allSatisfy(\.isFinite))
        }
        let silent = analyzer.transform([Float](repeating: 0, count: 4 * count), sampleRate: 48000)
        precondition(silent.before.allSatisfy { $0 == -100 })
    }
    #endif
}
