import Foundation

public enum CineError: Error, CustomStringConvertible {
    case invalidMagic(found: UInt16)
    case unsupportedCompression(UInt32)
    case unsupportedBitCount(UInt16)
    case corruptFrame(index: Int, reason: String)
    case frameIndexOutOfRange(index: Int, count: Int)
    case fileTooSmall
    case invalidTrimRange(range: ClosedRange<Int>, frameCount: Int)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidMagic(let found):
            return "Not a .cine file (expected magic 'CI', found 0x\(String(found, radix: 16)))"
        case .unsupportedCompression(let code):
            return "Unsupported biCompression value: \(code)"
        case .unsupportedBitCount(let bits):
            return "Unsupported biBitCount value: \(bits)"
        case .corruptFrame(let index, let reason):
            return "Corrupt frame at index \(index): \(reason)"
        case .frameIndexOutOfRange(let index, let count):
            return "Frame index \(index) out of range (file has \(count) frames)"
        case .fileTooSmall:
            return "File is too small to contain a valid .cine header"
        case .invalidTrimRange(let range, let frameCount):
            return "Invalid trim range \(range.lowerBound)...\(range.upperBound) for a file with \(frameCount) frame(s)"
        case .writeFailed(let reason):
            return "Failed to write .cine file: \(reason)"
        }
    }
}
