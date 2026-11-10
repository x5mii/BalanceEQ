import XCTest
@testable import EQCore

final class CalibrationTests: XCTestCase {
    func testSuppliedCommaAndShelfFile() throws {
        let url = Bundle.module.url(forResource: "Beyerdynamic T5 3rd", withExtension: "txt", subdirectory: "Fixtures")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let preset = try APOCodec.parse(text, name: "T5")
        XCTAssertEqual(preset.preampDB, -5)
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.bands.map(\.frequency), [105,120,260,390,800,1600,3500,6100,8100,10000])
        XCTAssertEqual(preset.bands.map(\.gainDB), [5.5,-4.1,-7.3,4.2,-3.7,6,-1,-3,-7,-3])
        XCTAssertEqual(preset.bands.map(\.q), [0.71,1.3,0.71,1.3,1,0.71,5,3,4.5,0.71])
        let explicit = try APOCodec.parse(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " LS ", with: " LSC ").replacingOccurrences(of: " HS ", with: " HSC "), name: "T5")
        let exported = try APOCodec.parse(APOCodec.export(preset), name: "Round trip")
        for rate in [44100.0,48000,96000] {
            for f in [20.0,105,260,1000,10000,19000] {
                XCTAssertEqual(preset.responseDB(at: f, sampleRate: rate), explicit.responseDB(at: f, sampleRate: rate), accuracy: 1e-9)
                XCTAssertEqual(preset.responseDB(at: f, sampleRate: rate), exported.responseDB(at: f, sampleRate: rate), accuracy: 1e-9)
            }
        }
        XCTAssertEqual(try APOCodec.parse("Preamp: -5,0 dB\nFilter 1: ON PK Fc 100,5 Hz Gain 1,2 dB Q 0,710", name: "Decimals").bands[0].frequency,100.5)
        for invalid in ["1,2.3", "1,,2", "nan", "inf", "1e999"] {
            XCTAssertThrowsError(try APOCodec.parse("# header\nPreamp: \(invalid) dB", name: "Bad")) { error in
                XCTAssertTrue(error.localizedDescription.contains("Line 2"))
                XCTAssertTrue(error.localizedDescription.contains(invalid))
            }
            for line in ["Filter 1: ON PK Fc \(invalid) Hz Gain 1 dB Q 1",
                         "Filter 1: ON PK Fc 100 Hz Gain \(invalid) dB Q 1",
                         "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q \(invalid)"] {
                XCTAssertThrowsError(try APOCodec.parse("# header\n" + line, name: "Bad")) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Line 2"))
                    XCTAssertTrue(error.localizedDescription.contains(invalid))
                }
            }
        }
    }

    private func curve() -> CalibrationCurve {
        CalibrationCurve(frequencies: [20,1000,20000], measured: [4,4,4], target: [0,0,0], preampDB: 0, bands: [])
    }
    private func calibrated() -> EQPreset {
        var preset = EQPreset(name: "Synthetic", preampDB: -9, bands: [EQBand(type: .lowShelf, frequency: 100, gainDB: 4, q: 0.71)])
        preset.calibration = CalibrationSettings(measurementID: String(repeating: "a", count: 24))
        return preset
    }

    func testPredictionResidualBypassAndCustomTarget() throws {
        var preset = calibrated()
        let base = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        XCTAssertEqual(base.before[0], 4)
        XCTAssertGreaterThan(base.after[0], 7.5, "Prediction must retain an incorrect correction, not force flatness")
        let band = EQBand(type: .highShelf, frequency: 4000, gainDB: -3, q: 0.71)
        preset.bands.append(band)
        preset.calibration?.customBandIDs = [band.id]
        preset.calibration?.customTargetEnabled = true
        for rate in [8000.0,44100,48000,96000] {
            // At 8 kHz this enabled shelf is invalid; it must never silently disappear.
            if rate == 8000 { XCTAssertThrowsError(try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: true)); continue }
            let response = try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: false)
            let deviation = try curve().response(preset: preset, sampleRate: rate, bypassed: false, relative: true)
            let bypass = try curve().response(preset: preset, sampleRate: rate, bypassed: true, relative: true)
            for i in 0..<response.frequencies.count {
                XCTAssertEqual(response.after[i], 4 + preset.responseDB(at: response.frequencies[i], sampleRate: rate) - preset.preampDB, accuracy: 1e-9)
                XCTAssertEqual(deviation.after[i], response.after[i] - response.target[i], accuracy: 1e-9)
                XCTAssertEqual(bypass.after[i], bypass.before[i], accuracy: 1e-9)
            }
        }
        let active = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        for i in base.after.indices { XCTAssertEqual(base.after[i], active.after[i], accuracy: 1e-9, "Custom delta belongs in both playback and target") }
        preset.preampDB = -20
        let attenuated = try curve().response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        for i in active.after.indices { XCTAssertEqual(active.after[i], attenuated.after[i], accuracy: 1e-9) }
        preset.calibration?.customTargetEnabled = false
        XCTAssertEqual(preset.activeBands.count,1)
        let flatExport = try APOCodec.parse(APOCodec.export(preset), name: "Export")
        XCTAssertFalse(flatExport.bands[1].enabled)
        XCTAssertEqual(flatExport.responseDB(at: 10000, sampleRate: 48000), preset.responseDB(at: 10000, sampleRate: 48000), accuracy: 1e-9)
    }

    func testKnownCorrectionReallyPredictsFlat() throws {
        let preset = calibrated()
        let frequencies = (0...384).map { 20 * pow(1000, Double($0) / 384) }
        let inverse = preset.responseDB(at: frequencies, sampleRate: 48000).map { preset.preampDB - $0 }
        let measurement = CalibrationCurve(frequencies: frequencies, measured: inverse, target: frequencies.map { _ in 0 }, preampDB: 0, bands: [])
        let response = try measurement.response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
        XCTAssertTrue(response.after.allSatisfy { abs($0) < 1e-9 })
        let restored = try JSONDecoder().decode(EQPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(restored.calibration, preset.calibration)
    }

    func testMetadataCompatibilityBoundsAndRoundTrip() throws {
        var preset = calibrated()
        let custom = EQBand(type: .peak, frequency: 1200, gainDB: 3, q: 0.2)
        preset.bands.append(custom)
        preset.calibration?.customBandIDs = [custom.id]
        preset.calibration?.customTargetEnabled = true
        let copy = try JSONDecoder().decode(EQPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(copy,preset)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PresetStore(directory: directory)
        let library = PresetLibrary(presets: [preset], selectedPresetID: preset.id, lastPreset: preset)
        try store.save(library)
        XCTAssertEqual(try PresetStore(directory: directory).load(), library)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as! [String:Any]
        legacy.removeValue(forKey: "calibration")
        XCTAssertNil(try JSONDecoder().decode(EQPreset.self, from: JSONSerialization.data(withJSONObject: legacy)).calibration)
        preset.calibration?.customBandIDs = [UUID()]
        XCTAssertThrowsError(try preset.validate())
        preset = calibrated()
        preset.bands = (0..<32).map { _ in EQBand() }
        try preset.validate()
        preset.bands.append(EQBand())
        XCTAssertThrowsError(try preset.validate())
        let bad = CalibrationCurve(frequencies: [20,20,20000], measured: [0,0,0], target: [0,0,0], preampDB: 0, bands: [])
        XCTAssertThrowsError(try bad.validate())
    }

    func testBundledCalibrationPairsAndRequiredHeadphones() throws {
        let catalog = try CalibrationCatalog.bundled()
        XCTAssertFalse(catalog.isEmpty)
        for name in ["Beyerdynamic T5 (3rd Gen)", "Beyerdynamic DT 990 (fresh earpads)", "Beyerdynamic DT 990 (worn earpads)"] {
            let profile = try XCTUnwrap(catalog.first { $0.name == name })
            let curve = try profile.loadCurve()
            let preset = try profile.preset(curve: curve)
            let result = try curve.response(preset: preset, sampleRate: 48000, bypassed: false, relative: true)
            XCTAssertEqual(result.after.count,385)
            XCTAssertTrue(result.after.allSatisfy(\.isFinite))
            XCTAssertEqual(result.target, Array(repeating: 0.0, count: 385))
        }
        // Every index entry must point at a complete valid curve and playable filter set.
        for profile in catalog { _ = try profile.preset(curve: profile.loadCurve()) }
    }
    func testTargetFittingAndLimits() throws {
        let grid = (0...191).map { 20 * pow(1000, Double($0) / 191) }
        let desired = EQPreset(name: "Known shelf", bands: [EQBand(type: .lowShelf, frequency: 105, gainDB: -6, q: 0.7)])
        let delta = desired.responseDB(at: grid, sampleRate: 48000)
        let fitted = try TargetFitter.fit(frequencies: grid, delta: delta, sampleRate: 48000, maximumBands: 6)
        let response = EQPreset(name: "Fit", bands: fitted).responseDB(at: grid, sampleRate: 48000)
        let rms = sqrt(zip(response,delta).reduce(0) { $0 + pow($1.0 - $1.1,2) } / Double(grid.count))
        XCTAssertLessThan(rms, 0.15)
        XCTAssertLessThanOrEqual(fitted.count,6)
        XCTAssertEqual(try TargetFitter.fit(frequencies: grid, delta: grid.map { _ in 0 }, sampleRate: 48000, maximumBands: 0).count,0)
        XCTAssertThrowsError(try TargetFitter.fit(frequencies: grid, delta: delta, sampleRate: 48000, maximumBands: 0))
        XCTAssertThrowsError(try TargetFitter.fit(frequencies: grid, delta: grid.map { _ in .nan }, sampleRate: 48000, maximumBands: 6))
        XCTAssertThrowsError(try TargetFitter.fit(frequencies: grid, delta: delta, sampleRate: 8000, maximumBands: 6))
    }

    func testNeutralHarmanAndCustomReallyChangePlayback() throws {
        let profile = try XCTUnwrap(CalibrationCatalog.bundled().first { $0.name == "Beyerdynamic DT 990 Pro" })
        let curve = try profile.loadCurve()
        for rate in [44100.0,48000,96000] {
            let neutral = try profile.calibrated(curve: curve, mode: .neutral, sampleRate: rate)
            let harman = try profile.calibrated(curve: curve, mode: .harman, sampleRate: rate)
            XCTAssertGreaterThan(harman.responseDB(at: 40, sampleRate: rate) - harman.preampDB - neutral.responseDB(at: 40, sampleRate: rate) + neutral.preampDB,4)
            let n = try curve.result(preset: neutral, profile: profile, sampleRate: rate, bypassed: false)
            let h = try curve.result(preset: harman, profile: profile, sampleRate: rate, bypassed: false)
            XCTAssertTrue(n.target.allSatisfy { abs($0) < 1e-9 })
            XCTAssertGreaterThan(h.target[0],5)
            XCTAssertEqual(n.before,h.before, "All targets share one display reference")
            for i in n.frequencies.indices {
                XCTAssertEqual(h.after[i]-n.after[i], harman.responseDB(at: n.frequencies[i], sampleRate: rate)-harman.preampDB-neutral.responseDB(at: n.frequencies[i], sampleRate: rate)+neutral.preampDB, accuracy: 1e-8)
            }
            let bypass = try curve.result(preset: harman, profile: profile, sampleRate: rate, bypassed: true)
            XCTAssertEqual(bypass.before,bypass.after)
            let bell = EQBand(frequency: 1500, gainDB: 3, q: 1)
            let custom = try profile.calibrated(curve: curve, mode: .custom, customBase: .neutral, customBands: [bell], sampleRate: rate)
            XCTAssertEqual(custom.calibration?.customBandIDs,[bell.id])
            let c = try curve.result(preset: custom, profile: profile, sampleRate: rate, bypassed: false)
            let bellResponse = EQPreset(name: "Custom",bands: [bell]).responseDB(at: c.frequencies,sampleRate: rate)
            for i in c.frequencies.indices {
                XCTAssertEqual(c.target[i]-n.target[i],bellResponse[i],accuracy:1e-8)
                XCTAssertEqual(c.after[i]-n.after[i],bellResponse[i],accuracy:1e-8)
            }
            XCTAssertEqual(try JSONDecoder().decode(EQPreset.self,from: JSONEncoder().encode(custom)),custom)
            let exported = try APOCodec.parse(APOCodec.export(custom),name: "Combined")
            XCTAssertEqual(exported.responseDB(at: 1500,sampleRate: rate),custom.responseDB(at: 1500,sampleRate: rate),accuracy:1e-7)
        }
    }

    func testTargetsUseExplicitMappingsAndLegacyMetadataSurvives() throws {
        let targets = try CalibrationTargets.bundled()
        let catalog = try CalibrationCatalog.bundled()
        let unsupported = try XCTUnwrap(catalog.first { $0.source == "Rtings" && $0.variant == "Bruel & Kjaer 5128 over-ear" })
        XCTAssertNil(targets.target(for: unsupported,mode: .harman))
        XCTAssertNotNil(targets.target(for: unsupported,mode: .neutral))
        XCTAssertThrowsError(try unsupported.calibrated(curve: unsupported.loadCurve(), mode: .harman, sampleRate: 48000))
        var legacy = calibrated()
        let decoded = try JSONDecoder().decode(EQPreset.self,from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.calibration?.targetID)
        XCTAssertNil(decoded.calibration?.targetMode)
        XCTAssertEqual(decoded,legacy)
        legacy.calibration?.targetMode = .neutral
        XCTAssertThrowsError(try legacy.validate())
        for name in ["Beyerdynamic T5 (3rd Gen)","Beyerdynamic DT 990 (fresh earpads)","Beyerdynamic DT 990 (worn earpads)"] {
            let profile = try XCTUnwrap(catalog.first { $0.name == name })
            XCTAssertNotNil(targets.target(for: profile,mode: .neutral))
            XCTAssertNotNil(targets.target(for: profile,mode: .harman))
        }
    }

    func testFrequencyOrderingPreservesBandIdentityAndStorage() throws {
        let a = EQBand(frequency: 8000), b = EQBand(frequency: 100), c = EQBand(frequency: 100)
        var preset = EQPreset(name: "Order",bands: [a,b,c])
        XCTAssertEqual(preset.frequencyOrderedBands.map(\.id),[b.id,c.id,a.id])
        XCTAssertEqual(preset.bands.map(\.id),[a.id,b.id,c.id])
        preset.bands[0].frequency = 20
        XCTAssertEqual(preset.frequencyOrderedBands.map(\.id),[a.id,b.id,c.id])
        XCTAssertEqual(preset.bands[0].id,a.id)
    }

    func testTargetFitAcrossMeasurementFamilies() throws {
        let targets = try CalibrationTargets.bundled()
        let catalog = try CalibrationCatalog.bundled()
        var checked = Set<String>()
        for profile in catalog {
            let curve = try profile.loadCurve()
            let original = try profile.preset(curve: curve)
            for mode in [CalibrationTargetMode.neutral,.harman] {
                guard let target = targets.target(for: profile,mode: mode), checked.insert(target.id + mode.rawValue).inserted else { continue }
                let preset = try profile.calibrated(curve: curve,mode: mode,sampleRate: 48000)
                let before = try curve.response(preset: original,sampleRate: 48000,bypassed: false,relative: false)
                let after = try curve.response(preset: preset,sampleRate: 48000,bypassed: false,relative: false)
                let errors = zip(zip(after.after,before.after),zip(after.target,before.target)).map { ($0.0-$0.1)-($1.0-$1.1) }
                let rms = sqrt(errors.reduce(0) { $0+$1*$1 } / Double(errors.count))
                if mode == .harman { XCTAssertLessThan(rms,1.0,"Target adaptation error for \(target.name) / \(mode): \(rms) dB") }
                else { XCTAssertEqual(preset.calibration?.measurementFitVersion,1) }
                XCTAssertLessThanOrEqual(preset.bands.count,32)
            }
        }
        XCTAssertEqual(checked.count,10) // Ten distinct target/mode pairs in the pinned catalog.
    }

    func testMeasuredNeutralImprovesRealProfilesWithoutChangingTheReference() throws {
        let catalog = try CalibrationCatalog.bundled(), targets = try CalibrationTargets.bundled()
        for name in ["Beyerdynamic DT 990 Pro", "Beyerdynamic DT 990 (fresh earpads)", "Beyerdynamic DT 990 (worn earpads)", "Beyerdynamic T5 (3rd Gen)"] {
            let profile = try XCTUnwrap(catalog.first { $0.name == name }), curve = try profile.loadCurve()
            for rate in [44100.0,48000,96000] {
                let fitted = try profile.calibrated(curve: curve, mode: .neutral, sampleRate: rate)
                let target = try XCTUnwrap(targets.target(for: profile,mode: .neutral))
                let grid = (0...191).map { 20 * pow(1000,Double($0) / 191) }
                let anchor = CalibrationCurve.interpolate(curve.target,frequencies: curve.frequencies,at: [1000])[0]
                let desired = target.response(at: grid,bass: false,anchor: anchor)
                let reference = CalibrationCurve.interpolate(curve.target,frequencies: curve.frequencies,at: grid)
                var legacy = try profile.preset(curve: curve)
                legacy.bands += try TargetFitter.fit(frequencies: grid,delta: zip(desired,reference).map(-),sampleRate: rate,maximumBands: 6)
                legacy.calibration = fitted.calibration
                let old = try curve.response(preset: legacy,sampleRate: rate,bypassed: false,relative: true)
                let new = try curve.response(preset: fitted,sampleRate: rate,bypassed: false,relative: true)
                let indices = new.frequencies.indices.filter { new.frequencies[$0] <= 6000 }
                func rms(_ values: [Double]) -> Double { sqrt(indices.reduce(0) { $0 + values[$1] * values[$1] } / Double(indices.count)) }
                XCTAssertLessThanOrEqual(rms(new.after),rms(old.after) + 1e-8)
                XCTAssertEqual(fitted.bands.count,legacy.bands.count,"Refitting must not add playback work")
                let oldTreble = legacy.bands.filter { $0.frequency > 6000 }, newTreble = fitted.bands.filter { $0.frequency > 6000 }
                XCTAssertEqual(oldTreble.map(\.frequency),newTreble.map(\.frequency))
                XCTAssertEqual(oldTreble.map(\.gainDB),newTreble.map(\.gainDB))
                XCTAssertEqual(oldTreble.map(\.q),newTreble.map(\.q))
                let oldGain = legacy.responseDB(at: new.frequencies,sampleRate: rate).map { $0 - legacy.preampDB }
                let newGain = fitted.responseDB(at: new.frequencies,sampleRate: rate).map { $0 - fitted.preampDB }
                for i in new.frequencies.indices where new.frequencies[i] >= 10000 {
                    XCTAssertLessThanOrEqual(abs(newGain[i] - oldGain[i]),1 + 1e-8)
                }
                XCTAssertLessThanOrEqual(newGain.max()!,max(6,oldGain.max()!) + 1e-8)
                if name == "Beyerdynamic DT 990 Pro" {
                    XCTAssertLessThan(rms(new.after),rms(old.after) * 0.9)
                    print("Neutral fit \(name) at \(rate): \(rms(old.after)) -> \(rms(new.after)) dB RMS, 20 Hz–6 kHz")
                }
                XCTAssertEqual(fitted.preampDB,fitted.recommendedPreamp(sampleRate: rate),accuracy: 1e-9)
                XCTAssertEqual(try JSONDecoder().decode(EQPreset.self,from: JSONEncoder().encode(fitted)),fitted)
                var saved = fitted
                saved.calibration?.measurementFitVersion = nil // Previously saved 1.2 Neutral stays playable.
                XCTAssertNoThrow(try saved.validate(sampleRate: rate))
                saved.calibration?.measurementFitVersion = 2
                XCTAssertThrowsError(try saved.validate())
            }
        }
    }

    func testMeasurementFitBoundariesAndSyntheticCorrection() throws {
        let grid = (0...384).map { 20 * pow(1000,Double($0) / 384) }
        let shape = EQPreset(name: "Synthetic",bands: [EQBand(frequency: 1000,gainDB: 4,q: 1)])
        let measured = shape.responseDB(at: grid,sampleRate: 48000), flat = grid.map { _ in 0.0 }
        let seed = [EQBand(frequency: 1000,gainDB: 0,q: 1)]
        let fit = try TargetFitter.fitMeasurement(frequencies: grid,measured: measured,target: flat,seed: seed,sampleRate: 48000)
        let response = EQPreset(name: "Fit",bands: fit).responseDB(at: grid,sampleRate: 48000)
        XCTAssertLessThan(sqrt(zip(response,measured).reduce(0) { $0 + pow($1.0+$1.1,2) } / Double(grid.count)),0.2)
        XCTAssertEqual(fit.map(\.id),seed.map(\.id))
        XCTAssertEqual(try TargetFitter.fitMeasurement(frequencies: grid,measured: flat,target: flat,seed: seed,sampleRate: 48000),seed)
        let deepDip = measured.map { -10 * $0 }
        let bounded = try TargetFitter.fitMeasurement(frequencies: grid,measured: deepDip,target: flat,seed: seed,sampleRate: 48000)
        XCTAssertLessThanOrEqual(EQPreset(name: "Bounded",bands: bounded).responseDB(at: grid,sampleRate: 48000).max()!,6 + 1e-8)
        XCTAssertThrowsError(try TargetFitter.fitMeasurement(frequencies: grid,measured: [.nan],target: flat,seed: seed,sampleRate: 48000))
        XCTAssertThrowsError(try TargetFitter.fitMeasurement(frequencies: grid.reversed(),measured: flat,target: flat,seed: seed,sampleRate: 48000))
        XCTAssertThrowsError(try TargetFitter.fitMeasurement(frequencies: grid,measured: flat,target: flat,seed: seed,sampleRate: 8000))
    }

}
