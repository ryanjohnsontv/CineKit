import Testing
@testable import CineKit

/// No real sample `.cube` file exists in this repo (unlike the real `.cine`
/// samples gated behind `TestFixtures.samplesAvailable`) — every fixture here
/// is a small, valid, synthetic LUT written inline as a string literal, so
/// these tests always run regardless of `CINE_SAMPLES_DIR`.
struct CubeLUTTests {
    /// A 2x2x2 LUT whose 8 data lines each carry distinct, exactly
    /// float-representable values (integers and quarters — no decimal
    /// rounding ambiguity): line `i`'s triple is `(i, i+0.25, i+0.5)`. This
    /// is deliberately NOT a coordinate-identity LUT (where each entry's
    /// value simply equals its own [0,1] grid coordinate) — using distinct,
    /// easily-traced-back-to-their-source-line values makes it possible to
    /// assert *which* file line ended up at *which* flat array index,
    /// directly verifying the R-fastest/G-next/B-slowest ordering rather
    /// than merely checking that plausible-looking values came out.
    private static let taggedLUTLines: [String] = (0..<8).map { i in
        "\(i) \(Double(i) + 0.25) \(Double(i) + 0.5)"
    }

    private static func taggedLUTText(size: Int = 2) -> String {
        (["LUT_3D_SIZE \(size)"] + taggedLUTLines).joined(separator: "\n")
    }

    // MARK: (a) valid LUT parses with exact size/values in the exact expected order

    @Test func parsesTaggedLUTWithExactSizeAndValues() throws {
        let lut = try CubeLUT(text: Self.taggedLUTText())

        #expect(lut.size == 2)
        #expect(lut.values.count == 2 * 2 * 2 * 3)

        // The full flat array, in file order, must come through completely
        // unreordered (this type stores R,G,B per entry, entries in file
        // order -- no reordering/expansion happens here).
        var expected: [Float] = []
        for i in 0..<8 {
            expected.append(Float(i))
            expected.append(Float(i) + 0.25)
            expected.append(Float(i) + 0.5)
        }
        #expect(lut.values == expected)

        // Explicitly verify the R-fastest/G-next/B-slowest ordering formula
        // (`r = i % N, g = (i / N) % N, b = i / (N * N)`) by picking three
        // grid coordinates that each vary only one axis away from (0,0,0)
        // and confirming each lands at the flat index the formula predicts,
        // not just "some" index.
        let n = lut.size

        func flatIndex(r: Int, g: Int, b: Int) -> Int {
            r + g * n + b * n * n
        }

        // (1,0,0) -> only R advances -> must be the SECOND data line (i=1),
        // i.e. flat index 1 (R varies fastest).
        let rNeighborIndex = flatIndex(r: 1, g: 0, b: 0)
        #expect(rNeighborIndex == 1)
        #expect(lut.values[rNeighborIndex * 3] == 1.0)

        // (0,1,0) -> only G advances -> must be data line i=2 (flat index 2:
        // G is the second-fastest axis, stepping by N=2).
        let gNeighborIndex = flatIndex(r: 0, g: 1, b: 0)
        #expect(gNeighborIndex == 2)
        #expect(lut.values[gNeighborIndex * 3] == 2.0)

        // (0,0,1) -> only B advances -> must be data line i=4 (flat index 4:
        // B is the slowest axis, stepping by N*N=4).
        let bNeighborIndex = flatIndex(r: 0, g: 0, b: 1)
        #expect(bNeighborIndex == 4)
        #expect(lut.values[bNeighborIndex * 3] == 4.0)
    }

    // MARK: (a2) round-trips through write/re-parse exactly

    @Test func cubeTextRoundTripsExactly() throws {
        let original = try CubeLUT(text: Self.taggedLUTText())
        let reparsed = try CubeLUT(text: original.cubeText)
        #expect(reparsed.size == original.size)
        #expect(reparsed.values == original.values)
    }

    // MARK: (b) LUT_1D_SIZE throws .unsupported1DLUT

    @Test func lut1DSizeThrowsUnsupported1DLUT() throws {
        let text = """
        LUT_1D_SIZE 4
        0.0 0.0 0.0
        0.33 0.33 0.33
        0.66 0.66 0.66
        1.0 1.0 1.0
        """

        do {
            _ = try CubeLUT(text: text)
            Issue.record("Expected CubeLUTError.unsupported1DLUT to be thrown")
        } catch CubeLUTError.unsupported1DLUT {
            // expected
        } catch {
            Issue.record("Expected .unsupported1DLUT, got \(error)")
        }
    }

    // MARK: (c) row count mismatch (too few / too many) throws .rowCountMismatch with correct numbers

    @Test func tooFewDataLinesThrowsRowCountMismatchWithCorrectCounts() throws {
        // Declares a 2x2x2 LUT (needs 8 data lines) but only supplies 6.
        let text = (["LUT_3D_SIZE 2"] + Self.taggedLUTLines.prefix(6)).joined(separator: "\n")

        do {
            _ = try CubeLUT(text: text)
            Issue.record("Expected CubeLUTError.rowCountMismatch to be thrown")
        } catch CubeLUTError.rowCountMismatch(let expected, let found) {
            #expect(expected == 8)
            #expect(found == 6)
        } catch {
            Issue.record("Expected .rowCountMismatch, got \(error)")
        }
    }

    @Test func tooManyDataLinesThrowsRowCountMismatchWithCorrectCounts() throws {
        // Declares a 2x2x2 LUT (needs 8 data lines) but supplies 9 (one
        // extra bogus row appended).
        let text = (["LUT_3D_SIZE 2"] + Self.taggedLUTLines + ["9 9.25 9.5"]).joined(separator: "\n")

        do {
            _ = try CubeLUT(text: text)
            Issue.record("Expected CubeLUTError.rowCountMismatch to be thrown")
        } catch CubeLUTError.rowCountMismatch(let expected, let found) {
            #expect(expected == 8)
            #expect(found == 9)
        } catch {
            Issue.record("Expected .rowCountMismatch, got \(error)")
        }
    }

    // MARK: (d) comments and blank lines interspersed are correctly ignored

    @Test func commentsAndBlankLinesInterspersedAreIgnored() throws {
        var lines: [String] = [
            "# a synthetic tiny LUT for testing",
            "",
            "TITLE \"Test LUT\"",
            "",
            "# size directive follows",
            "LUT_3D_SIZE 2",
            "",
            "# first data line",
        ]
        for (i, line) in Self.taggedLUTLines.enumerated() {
            lines.append(line)
            lines.append("# comment after data line \(i)")
            if i == 3 {
                lines.append("")
                lines.append("# a blank line and comment in the middle of the data block")
            }
        }
        lines.append("")

        let lut = try CubeLUT(text: lines.joined(separator: "\n"))

        #expect(lut.size == 2)
        var expected: [Float] = []
        for i in 0..<8 {
            expected.append(Float(i))
            expected.append(Float(i) + 0.25)
            expected.append(Float(i) + 0.5)
        }
        #expect(lut.values == expected)
    }

    // MARK: (e) non-default DOMAIN_MIN / DOMAIN_MAX throws .unsupportedDomain

    @Test func nonDefaultDomainMinThrowsUnsupportedDomain() throws {
        let text = (["LUT_3D_SIZE 2", "DOMAIN_MIN 0.1 0.0 0.0"] + Self.taggedLUTLines).joined(separator: "\n")

        do {
            _ = try CubeLUT(text: text)
            Issue.record("Expected CubeLUTError.unsupportedDomain to be thrown")
        } catch CubeLUTError.unsupportedDomain {
            // expected
        } catch {
            Issue.record("Expected .unsupportedDomain, got \(error)")
        }
    }

    @Test func nonDefaultDomainMaxThrowsUnsupportedDomain() throws {
        let text = (["LUT_3D_SIZE 2", "DOMAIN_MAX 1.0 1.0 2.0"] + Self.taggedLUTLines).joined(separator: "\n")

        do {
            _ = try CubeLUT(text: text)
            Issue.record("Expected CubeLUTError.unsupportedDomain to be thrown")
        } catch CubeLUTError.unsupportedDomain {
            // expected
        } catch {
            Issue.record("Expected .unsupportedDomain, got \(error)")
        }
    }

    @Test func defaultDomainMinAndMaxAreAccepted() throws {
        // The exact default values, spelled out explicitly, must NOT throw
        // -- only a genuinely non-default domain should.
        let text = ([
            "LUT_3D_SIZE 2",
            "DOMAIN_MIN 0.0 0.0 0.0",
            "DOMAIN_MAX 1.0 1.0 1.0",
        ] + Self.taggedLUTLines).joined(separator: "\n")

        let lut = try CubeLUT(text: text)
        #expect(lut.size == 2)
    }
}
