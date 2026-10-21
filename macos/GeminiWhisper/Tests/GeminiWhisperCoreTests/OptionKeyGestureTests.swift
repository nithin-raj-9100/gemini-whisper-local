import Foundation
@testable import GeminiWhisperCore
import Testing

@Suite("Right Option tap and hold")
struct OptionKeyGestureTests {
    @Test func quickTapTogglesAndDuplicateEventsDoNothing() {
        var gesture = OptionKeyGesture()
        #expect(gesture.press(at: 0) == [.prepare])
        #expect(gesture.press(at: 0.01).isEmpty)
        #expect(gesture.release(at: 0.15) == [.toggle])
        #expect(gesture.release(at: 0.16).isEmpty)
        #expect(gesture.advance(to: 0.7).isEmpty)
    }

    @Test func holdingPastTheOldExpiryKeepsRecordingUntilRelease() {
        var gesture = OptionKeyGesture()
        #expect(gesture.press(at: 0) == [.prepare])
        #expect(gesture.advance(to: 0.59).isEmpty)
        #expect(gesture.advance(to: 0.6) == [.startHold])
        for time in [0.7, 1, 2, 10, 60] {
            #expect(gesture.advance(to: time).isEmpty)
            #expect(gesture.press(at: time).isEmpty)
        }
        #expect(gesture.release(at: 61) == [.finishHold])
        #expect(gesture.release(at: 61.01).isEmpty)
    }

    @Test func delayedTimerDoesNotLoseAHeldUtterance() {
        var gesture = OptionKeyGesture()
        _ = gesture.press(at: 0)
        #expect(gesture.release(at: 2) == [.startHold, .finishHold])
        #expect(gesture.advance(to: 2.1).isEmpty)
    }

    @Test func modifierBeforeHoldDiscardsAndCannotRestartUntilRelease() {
        var gesture = OptionKeyGesture()
        _ = gesture.press(at: 0)
        #expect(gesture.interrupt() == [.discardPreparation])
        #expect(gesture.press(at: 0.2).isEmpty)
        #expect(gesture.advance(to: 1).isEmpty)
        #expect(gesture.release(at: 2).isEmpty)
        #expect(gesture.press(at: 3) == [.prepare])
        #expect(gesture.release(at: 3.1) == [.toggle])
    }

    @Test func escapeOrModifierDuringHoldCancelsWithoutPastingOnRelease() {
        var gesture = OptionKeyGesture()
        _ = gesture.press(at: 0)
        _ = gesture.advance(to: 1)
        #expect(gesture.interrupt() == [.cancelHold])
        #expect(gesture.interrupt().isEmpty)
        #expect(gesture.release(at: 5).isEmpty)
    }
}

@Suite("configurable hotkey")
struct HotkeyKeyTests {
    @Test func distinguishesLeftAndRightModifiersByDeviceBit() {
        // Generic Option flag (0x80000) plus the left-Option device bit only.
        let leftOptionHeld: UInt64 = 0x0008_0000 | 0x20
        #expect(HotkeyKey.leftOption.isDown(flags: leftOptionHeld))
        #expect(!HotkeyKey.rightOption.isDown(flags: leftOptionHeld))
        let bothOptions: UInt64 = 0x0008_0000 | 0x20 | 0x40
        #expect(HotkeyKey.rightOption.isDown(flags: bothOptions))
        #expect(HotkeyKey.rightCommand.isDown(flags: 0x0010_0000 | 0x10))
        #expect(!HotkeyKey.rightCommand.isDown(flags: 0x0010_0000 | 0x08))
        #expect(HotkeyKey.function.isDown(flags: 0x0080_0000))
        #expect(HotkeyKey.rightControl.isDown(flags: 0x0004_0000 | 0x2000))
        #expect(HotkeyKey.rightShift.isDown(flags: 0x0002_0000 | 0x04))
    }

    @Test func keyCodesMatchCarbonVirtualKeys() {
        #expect(HotkeyKey.allCases.map(\.keyCode) == [61, 58, 54, 62, 60, 63])
        #expect(Set(HotkeyKey.allCases.map(\.deviceFlagMask)).count == HotkeyKey.allCases.count)
    }

    @Test func unknownStoredValueFallsBackToRightOption() {
        #expect(HotkeyKey(storedValue: nil) == .rightOption)
        #expect(HotkeyKey(storedValue: "capsLock") == .rightOption)
        #expect(HotkeyKey(storedValue: "function") == .function)
    }
}
