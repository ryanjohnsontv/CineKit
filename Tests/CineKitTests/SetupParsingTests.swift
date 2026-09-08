import Testing
@testable import CineKit

@Suite(.enabled(if: TestFixtures.samplesAvailable))
struct SetupParsingTests {
    /// Regression canary: the `Mark` field's offset (140 bytes into SETUP)
    /// was validated by hand against a raw hex dump of a real file, where it
    /// landed exactly on ASCII "ST". If this ever fails, the offset table
    /// (or everything computed before it) has regressed.
    @Test func markCanaryAcrossAllSamples() throws {
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.mark == "ST", "\(name)")
        }
    }

    @Test func setupLengthIsShorterThanNewestSchema() throws {
        // Every real sample we've seen has an on-disk SETUP block shorter
        // than the newest known struct (~13484 bytes) — camera software
        // versions differ. This isn't a hard invariant of the format, but
        // regressing to "always reads the full struct" would silently start
        // fabricating field values again, so pin the observed range.
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.length >= 9000, "\(name)")
            #expect(file.setup.length < SetupFieldLayout.maxKnownSize, "\(name)")
        }
    }

    @Test func allSamplesAreBayerColorSensors() throws {
        // Surprising finding worth pinning: despite 10-bit-packed pixel data
        // that looks mono-shaped, all 4 real samples are actually Bayer
        // color sensors (CFA==3, "gbrg") with color enabled.
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.cfa == .bayer, "\(name)")
            #expect(file.setup.isColorEnabled == true, "\(name)")
            #expect(file.setup.realBPP == 10, "\(name)")
        }
    }

    @Test func blackAndWhiteLevelsAreConsistentAcrossSamples() throws {
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.blackLevel == 64, "\(name)")
            #expect(file.setup.whiteLevel == 1015, "\(name)")
        }
    }

    @Test func colorCalibrationFieldsMatchKnownValues() throws {
        // Cross-checked directly against the raw bytes of a real sample
        // file (see the task's research notes) -- these are genuine,
        // non-trivial calibration values actually present on disk, not
        // garbage read past `Setup.Length`.
        let file = try CineFile(url: TestFixtures.url("Noise on Complex Image.cine"))
        let setup = file.setup

        #expect(setup.wbGainR != nil)
        #expect(setup.wbGainB != nil)
        #expect(abs((setup.wbGainR ?? 0) - 1.4338) < 0.001)
        #expect(abs((setup.wbGainB ?? 0) - 1.7335) < 0.001)

        #expect(abs((setup.fGamma ?? 0) - 2.2) < 0.001)

        guard let cm = setup.cmCalib else {
            Issue.record("cmCalib should be present in this sample")
            return
        }
        #expect(cm.count == 9)
        #expect(abs(cm[0] - 2.38109) < 0.001)
        #expect(abs(cm[8] - 3.0455) < 0.001)

        guard let calibration = setup.colorCalibration else {
            Issue.record("colorCalibration should decompose successfully for this sample")
            return
        }
        // The decomposed white-balance gains should match the file's
        // separately-stored WBGain[0] values almost exactly -- a strong
        // sanity check that both the raw field reads and the
        // decomposition algorithm are correct.
        #expect(abs(calibration.whiteBalanceR - (setup.wbGainR ?? 0)) < 0.001)
        #expect(abs(calibration.whiteBalanceG - 1.0) < 0.001)
        #expect(abs(calibration.whiteBalanceB - (setup.wbGainB ?? 0)) < 0.001)
        // Normalized color matrix's first row must sum to 1 by construction.
        #expect(abs(calibration.matrix[0] + calibration.matrix[1] + calibration.matrix[2] - 1.0) < 0.0001)
    }

    @Test func multiHeadWhiteBalanceRotateAndWBViewMatchKnownValues() throws {
        // Regression baseline for the 3 fields immediately after WBGain[0]:
        // heads 1-3 are "not meaningful" on these single-head cameras
        // (either a neutral 1.0/1.0 or a zeroed-out 0.0/0.0 default,
        // depending on the file's own software version -- both are
        // consistent with "unused slot", not evidence of a wrong offset),
        // rotationDegrees is always 0 (none of these captures were
        // recorded rotated), and wbView is a neutral 1.0/1.0 independent
        // of whatever head 0's own gain is (see "Noise on Complex
        // Image.cine" below, whose head 0 is a real non-identity gain).
        let cases: [(file: String, unusedHeadGain: Float)] = [
            ("Noise on Complex Image.cine", 1.0),
            ("Over Exposed (1000FPS).cine", 0.0),
            ("Point Sourse Light + under Exposed (1000FPS).cine", 0.0),
            ("Underexposed (240fps).cine", 0.0),
        ]
        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))
            let setup = file.setup
            #expect(setup.wbGain1R == c.unusedHeadGain, "\(c.file)")
            #expect(setup.wbGain1B == c.unusedHeadGain, "\(c.file)")
            #expect(setup.wbGain2R == c.unusedHeadGain, "\(c.file)")
            #expect(setup.wbGain2B == c.unusedHeadGain, "\(c.file)")
            #expect(setup.wbGain3R == c.unusedHeadGain, "\(c.file)")
            #expect(setup.wbGain3B == c.unusedHeadGain, "\(c.file)")
            #expect(setup.rotationDegrees == 0, "\(c.file)")
            #expect(setup.wbViewR == 1.0, "\(c.file)")
            #expect(setup.wbViewB == 1.0, "\(c.file)")
        }
    }

    @Test func pbRateIsTwentyFourAcrossAllSamples() throws {
        // `fPbRate` is the on-camera "video system" review rate, distinct
        // from the sensor's own capture rate (see `frameRateMatchesKnownValues`
        // below, whose capture rates for these same files are 1000/240/1536/
        // 1536fps) -- every real sample nonetheless reads exactly 24.0 here.
        for name in TestFixtures.knownFiles {
            let file = try CineFile(url: TestFixtures.url(name))
            #expect(file.setup.pbRate != nil, "\(name)")
            #expect(abs((file.setup.pbRate ?? 0) - 24.0) < 0.001, "\(name)")
        }
    }

    @Test func frameRateMatchesKnownValues() throws {
        let cases: [(file: String, expectedFPS: UInt32)] = [
            ("Over Exposed (1000FPS).cine", 1536), // named 1000FPS but header reports the camera's actual rate
            ("Point Sourse Light + under Exposed (1000FPS).cine", 1536),
            ("Underexposed (240fps).cine", 240),
        ]
        for c in cases {
            let file = try CineFile(url: TestFixtures.url(c.file))
            #expect(file.setup.frameRate == c.expectedFPS, "\(c.file)")
        }
    }
}
