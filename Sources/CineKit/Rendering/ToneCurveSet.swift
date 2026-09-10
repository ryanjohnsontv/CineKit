import Foundation

/// The four tone-curve channels: primary (applied to all channels) plus
/// independent per-channel curves.
public enum ToneCurveChannel: Int, CaseIterable, Sendable, Hashable {
    case primary, red, green, blue

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

/// One `ToneCurve` per `ToneCurveChannel`.
public struct ToneCurveSet: Equatable, Sendable {
    public var primary: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve

    public static let identity = ToneCurveSet()

    public init(
        primary: ToneCurve = .identity,
        red: ToneCurve = .identity,
        green: ToneCurve = .identity,
        blue: ToneCurve = .identity
    ) {
        self.primary = primary
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: ToneCurveChannel) -> ToneCurve {
        get {
            switch channel {
            case .primary: return primary
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .primary: primary = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}
