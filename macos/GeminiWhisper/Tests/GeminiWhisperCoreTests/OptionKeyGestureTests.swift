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
