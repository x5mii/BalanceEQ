// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CEQ

private final class Renderer: @unchecked Sendable {
    let dsp: OpaquePointer
    init(rate: Double = 48_000, capacity: UInt32 = 256) {
        dsp = eq_dsp_create(rate, capacity)!
    }
    deinit { eq_dsp_destroy(dsp) }

    func set(bands: [EQBand] = [], preamp: Double = 0, bypass: Bool = false) -> Bool {
        var parameters = EQParameters()
        parameters.preampDB = preamp
        parameters.bypass = bypass ? 1 : 0
        for (index, band) in bands.enumerated() {
            guard eq_parameters_set_band(&parameters, UInt32(index), band) else { return false }
        }
        return eq_dsp_set_parameters(dsp, &parameters)
    }

    func render(_ left: [Float], right: [Float]? = nil) -> ([Float], [Float]) {
        var outputL = [Float](repeating: 0, count: left.count)
        var outputR = outputL
        left.withUnsafeBufferPointer { input in
            outputL.withUnsafeMutableBufferPointer { l in
                outputR.withUnsafeMutableBufferPointer { r in
                    if let right {
                        precondition(right.count == left.count)
                        right.withUnsafeBufferPointer { inputR in
                            eq_dsp_process(dsp, input.baseAddress, inputR.baseAddress, 1,
                                           l.baseAddress, r.baseAddress, 1, UInt32(left.count))
                        }
                    } else {
                        eq_dsp_process(dsp, input.baseAddress, nil, 1,
                                       l.baseAddress, r.baseAddress, 1, UInt32(left.count))
                    }
                }
            }
        }
        return (outputL, outputR)
    }

    func settle(rate: Double) { _ = render([Float](repeating: 0, count: Int(rate / 10))) }
}

final class DSPTests: XCTestCase {
    private func band(_ type: Int32 = Int32(EQ_PEAK), frequency: Double = 1_000,
                      gain: Double = 6, q: Double = 1) -> EQBand {
        EQBand(type: type, enabled: 1, frequency: frequency, gainDB: gain, q: q)
    }

    func testAnalysisSnapshotOwnsCompleteStereoInputAndClippedOutput() {
        let renderer = Renderer(capacity: 37) // Snapshot spans many callback chunks.
        XCTAssertTrue(renderer.set(preamp: -6))
        renderer.settle(rate: 48000)
        let n = Int(EQ_ANALYSIS_FRAMES)
        var snapshot = [Float](repeating: 99, count: 4 * n)
        XCTAssertFalse(eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)))
        eq_dsp_request_analysis(renderer.dsp)
        _ = renderer.render([Float](repeating: 0.5, count: n - 1), right: [Float](repeating: -0.25, count: n - 1))
        XCTAssertFalse(eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)))
        XCTAssertEqual(snapshot[0], 99, "Never expose an incomplete snapshot")
        _ = renderer.render([0.5], right: [-0.25])
        eq_dsp_request_analysis(renderer.dsp) // A ready snapshot must not be overwritten.
        _ = renderer.render([0.9])
        XCTAssertFalse(eq_dsp_read_analysis(renderer.dsp, &snapshot, 1))
        XCTAssertTrue(eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)))
        XCTAssertTrue(snapshot[0..<n].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(snapshot[n..<2*n].allSatisfy { $0 == -0.25 })
        let gain = Float(pow(10.0, -6.0 / 20.0))
        XCTAssertTrue(snapshot[2*n..<3*n].allSatisfy { abs($0 - 0.5 * gain) < 1e-6 })
        XCTAssertTrue(snapshot[3*n..<4*n].allSatisfy { abs($0 + 0.25 * gain) < 1e-6 })
        XCTAssertFalse(eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)))
        XCTAssertTrue(renderer.set(preamp: 12, bypass: true))
        renderer.settle(rate: 48000)
        eq_dsp_request_analysis(renderer.dsp)
        var left = [Float](repeating: 2, count: n)
        var right = [Float](repeating: -0.3, count: n)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq_dsp_process(renderer.dsp, l.baseAddress, r.baseAddress, 1, l.baseAddress, r.baseAddress, 1, UInt32(n))
            }
        }
        XCTAssertTrue(eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)))
        XCTAssertEqual(snapshot[0], 2, "In-place processing must preserve the original input snapshot")
        XCTAssertEqual(snapshot[2*n], 1, "Show final clipped output")
        XCTAssertEqual(snapshot[3*n], -0.3, "Bypass must not apply preamp")
    }

    func testConcurrentAnalysisSnapshotsRemainConsistent() {
        let renderer = Renderer()
        let group = DispatchGroup()
        var snapshot = [Float](repeating: 0, count: 4 * Int(EQ_ANALYSIS_FRAMES))
        eq_dsp_request_analysis(renderer.dsp)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for block in 0..<4096 {
                let value = Float(block % 97) / 100
                _ = renderer.render([Float](repeating: value, count: 256),
                                    right: [Float](repeating: -value, count: 256))
            }
        }
        var received = 0
        while true {
            let finished = group.wait(timeout: .now()) == .success
            if eq_dsp_read_analysis(renderer.dsp, &snapshot, UInt32(snapshot.count)) {
                received += 1
                let n = Int(EQ_ANALYSIS_FRAMES)
                for i in 0..<n {
                    XCTAssertEqual(snapshot[i], snapshot[2*n+i])
                    XCTAssertEqual(snapshot[n+i], snapshot[3*n+i])
                    XCTAssertEqual(snapshot[i], -snapshot[n+i])
                }
            }
            if finished { break }
            eq_dsp_request_analysis(renderer.dsp)
        }
        XCTAssertGreaterThan(received, 0)
    }

    func testFlatMonoStereoAndInterleavedAreExact() {
        let left: [Float] = [-1, -0.7, -0.1, 0, 0.2, 0.8, 1]
        let right = left.reversed().map { $0 }
        for rate in [44_100.0, 48_000, 96_000] {
            let renderer = Renderer(rate: rate, capacity: 3)
            XCTAssertTrue(renderer.set(bands: (0..<10).map { band(frequency: 30 * pow(2, Double($0)), gain: 0) }))
            let mono = renderer.render(left)
            XCTAssertEqual(mono.0, left)
            XCTAssertEqual(mono.1, left)
            let stereo = renderer.render(left, right: right)
            XCTAssertEqual(stereo.0, left)
            XCTAssertEqual(stereo.1, right)
            var interleaved = zip(left, right).flatMap { [$0, $1] }
            interleaved.withUnsafeMutableBufferPointer { data in
                eq_dsp_process(renderer.dsp, data.baseAddress, data.baseAddress! + 1, 2,
                               data.baseAddress, data.baseAddress! + 1, 2, UInt32(left.count))
            }
            XCTAssertEqual(interleaved, zip(left, right).flatMap { [$0, $1] })
            XCTAssertEqual(eq_dsp_peak(renderer.dsp), 1)
            XCTAssertFalse(eq_dsp_take_clipping(renderer.dsp))
        }
    }

    func testResponseMatchesRenderedTonesForEveryFilterAndSampleRate() {
        let types = [EQ_PEAK, EQ_LOW_SHELF, EQ_HIGH_SHELF, EQ_LOW_PASS, EQ_HIGH_PASS, EQ_NOTCH]
        for rate in [44_100.0, 48_000, 96_000] {
            for type in types {
                for frequency in [375.0, 1_500, 6_000] {
                    let filter = band(Int32(type), frequency: 1_500, gain: 9, q: 0.7071067811865476)
                    let renderer = Renderer(rate: rate)
                    XCTAssertTrue(renderer.set(bands: [filter]))
                    renderer.settle(rate: rate)
                    let samples = (0..<Int(rate)).map { Float(0.01 * sin(2 * .pi * frequency * Double($0) / rate)) }
                    let output = renderer.render(samples).0
                    let measured = rms(Array(output.suffix(Int(rate / 2))))
                    let expectedDB = eq_response_db(filter, rate, frequency)
                    if type == EQ_NOTCH && frequency == filter.frequency {
                        XCTAssertLessThan(measured, 1e-8)
                    } else {
                        let measuredDB = 20 * log10(measured / rms(Array(samples.suffix(Int(rate / 2)))))
                        XCTAssertEqual(measuredDB, expectedDB, accuracy: 0.015,
                                       "type \(type), Fs \(rate), frequency \(frequency)")
                    }
                }
            }
        }
    }

    func testImpulseMatchesSharedCoefficients() {
        for rate in [44_100.0, 48_000, 96_000] {
            let filter = band(gain: 12, q: 8)
            let renderer = Renderer(rate: rate)
            XCTAssertTrue(renderer.set(bands: [filter]))
            renderer.settle(rate: rate)
            var input = [Float](repeating: 0, count: 16_384)
            input[0] = 0.01
            let impulse = renderer.render(input).0
            for frequency in [80.0, 1_000, 8_000] {
                var re = 0.0, im = 0.0
                for (index, sample) in impulse.enumerated() {
                    let phase = 2 * .pi * frequency * Double(index) / rate
                    re += Double(sample) * cos(phase)
                    im -= Double(sample) * sin(phase)
                }
                let measured = 20 * log10(hypot(re, im) / Double(input[0]))
                XCTAssertEqual(measured, eq_response_db(filter, rate, frequency), accuracy: 0.005)
            }
        }
    }

    func testParameterBoundariesAndInvalidValuesKeepLastValidState() {
        var coefficients = [Double](repeating: 0, count: 5)
        for rate in [8_000.0, 44_100, 48_000, 96_000, 384_000] {
            for type in [EQ_PEAK, EQ_LOW_SHELF, EQ_HIGH_SHELF, EQ_LOW_PASS, EQ_HIGH_PASS, EQ_NOTCH] {
                for frequency in [10.0, min(20_000, rate / 2 - 1)] {
                    for q in [0.1, 30] {
                        for gain in [-24.0, 24] {
                            XCTAssertTrue(eq_coefficients(band(Int32(type), frequency: frequency, gain: gain, q: q),
                                                          rate, &coefficients))
                            XCTAssertTrue(coefficients.allSatisfy(\.isFinite))
                        }
                    }
                }
            }
        }
        let renderer = Renderer()
        XCTAssertTrue(renderer.set(preamp: -6))
        renderer.settle(rate: 48_000)
        for filter in [band(frequency: .nan), band(frequency: 24_000), band(gain: .infinity),
                       band(q: 0), band(q: 30.1), band(99)] {
            XCTAssertFalse(renderer.set(bands: [filter]))
        }
        XCTAssertFalse(renderer.set(preamp: .nan))
        XCTAssertFalse(renderer.set(preamp: 12.1))
        XCTAssertFalse(renderer.set(preamp: -60.1))
        XCTAssertEqual(renderer.render([0.5]).0[0], Float(0.5 * pow(10, -6 / 20)), accuracy: 1e-7)
        let lowRate = Renderer(rate: 8_000)
        XCTAssertFalse(lowRate.set(bands: [band(frequency: 4_000)]))
        XCTAssertTrue(lowRate.set(bands: [band(frequency: 16_000)], bypass: true))
        var disabled = band(frequency: 16_000)
        disabled.enabled = 0
        XCTAssertTrue(lowRate.set(bands: [disabled]))
        XCTAssertNil(eq_dsp_create(.nan, 256))
        XCTAssertNil(eq_dsp_create(48_000, 0))
        XCTAssertNil(eq_dsp_create(48_000, 65_537))
    }

    func testBypassRemovesPreampAndRampsSmoothly() {
        for rate in [44_100.0, 48_000, 96_000] {
            let renderer = Renderer(rate: rate)
            XCTAssertTrue(renderer.set(preamp: -20))
            renderer.settle(rate: rate)
            XCTAssertTrue(renderer.set(preamp: -20, bypass: true))
            let output = renderer.render([Float](repeating: 0.5, count: Int(rate / 20))).0
            XCTAssertLessThan(abs(output[0] - 0.05), 0.001)
            for (previous, next) in zip(output, output.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next, previous)
                XCTAssertLessThan(abs(next - previous), 0.001)
            }
            XCTAssertEqual(output.last, 0.5)
            XCTAssertTrue(renderer.set(bands: [band(gain: 12)], preamp: -30))
            renderer.settle(rate: rate)
            XCTAssertTrue(renderer.set(bands: [band(gain: 12)], preamp: -30, bypass: true))
            renderer.settle(rate: rate)
            let input: [Float] = [-0.7, 0, 0.3, 0.8]
            XCTAssertEqual(renderer.render(input).0, input)
        }
    }

    func testRapidConcurrentEditsCoalesceToLatestAndNeverProduceNonfiniteAudio() {
        let renderer = Renderer()
        let finished = expectation(description: "Serial parameter producer finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<5_000 {
                var parameters = EQParameters()
                parameters.preampDB = Double(-(i % 20))
                parameters.bypass = i.isMultiple(of: 3) ? 1 : 0
                let filter = EQBand(type: Int32(i % 6), enabled: 1,
                                    frequency: Double(100 + i % 15_000), gainDB: Double(i % 25 - 12), q: 0.7)
                _ = eq_parameters_set_band(&parameters, 0, filter)
                XCTAssertTrue(eq_dsp_set_parameters(renderer.dsp, &parameters))
            }
            var final = EQParameters()
            final.bypass = 1
            XCTAssertTrue(eq_dsp_set_parameters(renderer.dsp, &final))
            finished.fulfill()
        }
        let input = (0..<128).map { Float(0.1 * sin(Double($0) / 7)) }
        for _ in 0..<1_500 {
            let output = renderer.render(input)
            XCTAssertTrue(output.0.allSatisfy { $0.isFinite && abs($0) <= 1 })
            XCTAssertTrue(output.1.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
        wait(for: [finished], timeout: 10)
        renderer.settle(rate: 48_000)
        XCTAssertEqual(renderer.render(input).0, input)
    }

    func testClippingIsReportedBeforeHardClipAndNonfiniteInputIsContained() {
        let renderer = Renderer()
        XCTAssertTrue(renderer.set(preamp: 12))
        renderer.settle(rate: 48_000)
        let output = renderer.render([0.5, -0.5, .nan, .infinity, -.infinity]).0
        XCTAssertEqual(output, [1, -1, 0, 0, 0])
        XCTAssertEqual(eq_dsp_peak(renderer.dsp), Float(0.5 * pow(10, 12 / 20)), accuracy: 1e-6)
        XCTAssertTrue(eq_dsp_take_clipping(renderer.dsp))
        XCTAssertFalse(eq_dsp_take_clipping(renderer.dsp))
        XCTAssertTrue(renderer.render([0]).0.allSatisfy(\.isFinite))
    }

    func testFull32BandCascadeIsFiniteAndRejectsTooManyBands() {
        let renderer = Renderer()
        let filters = (0..<32).map { index in
            band(frequency: 20 * pow(1_000, Double(index) / 31), gain: 24, q: 30)
        }
        XCTAssertTrue(renderer.set(bands: filters, preamp: -60))
        renderer.settle(rate: 48_000)
        var impulse = [Float](repeating: 0, count: 96_000)
        impulse[0] = 0.5
        let output = renderer.render(impulse)
        XCTAssertTrue(output.0.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertEqual(output.0, output.1)
        var invalid = EQParameters()
        invalid.count = 33
        XCTAssertFalse(eq_dsp_set_parameters(renderer.dsp, &invalid))
        XCTAssertFalse(eq_parameters_set_band(&invalid, 32, band()))
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}
