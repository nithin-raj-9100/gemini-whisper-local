import Foundation

/// The modifier key that starts and stops dictation.
///
/// Right Option types special characters on many keyboard layouts (for example
/// Option+L is "@" on German layouts), so it is not right for everyone. Each key
/// is matched by its virtual key code and its device-specific modifier bit
/// (IOLLEvent.h), which, unlike the generic Option/Command flag, tells left and
/// right apart: releasing Right Option is seen even while Left Option is held.
public enum HotkeyKey: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case rightShift
    case function

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .function: return "Fn / Globe (🌐)"
        }
    }

    /// Carbon virtual key code (kVK_*).
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .function: return 63
        }
    }

    /// Device-dependent modifier bit carried in CGEventFlags / NSEvent.modifierFlags raw values.
    public var deviceFlagMask: UInt64 {
        switch self {
        case .rightOption: return 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .leftOption: return 0x0000_0020 // NX_DEVICELALTKEYMASK
        case .rightCommand: return 0x0000_0010 // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000 // NX_DEVICERCTLKEYMASK
        case .rightShift: return 0x0000_0004 // NX_DEVICERSHIFTKEYMASK
        case .function: return 0x0080_0000 // NX_SECONDARYFNMASK
        }
    }

    /// Whether this key is held, given the raw modifier flags of a flagsChanged event.
    public func isDown(flags: UInt64) -> Bool {
        flags & deviceFlagMask != 0
    }

    /// Settings value, tolerating removed or unknown entries.
    public init(storedValue: String?) {
        self = storedValue.flatMap(HotkeyKey.init(rawValue:)) ?? .rightOption
    }
}
