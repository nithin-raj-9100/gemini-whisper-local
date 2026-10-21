import AppKit
import QuartzCore

/// Bottom-center HUD copied from `macos/audio-helper/main.swift` (`FloatingHUDController`).
@MainActor
final class FloatingHUDController: NSObject {
    private var window: NSPanel?
    private var visualEffectView: NSVisualEffectView?
    private var statusDot: NSView?
    private var statusLabel: NSTextField?
    private var levelTrack: NSView?
    private var levelBar: NSView?
    private var scrollView: NSScrollView?
    /// Bumped by every show/hide so a pending error auto-hide cannot hide a newer HUD.
    private var displayToken = 0
    private var textView: NSTextView?
    private var currentText: String = ""
    private(set) var isCurrentlyActive: Bool = false
    private let defaultWidth: CGFloat = 520
    private let baseHeight: CGFloat = 72
    private let maxTextHeight: CGFloat = 180
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        let width = defaultWidth
        let height = baseHeight

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.0
        panel.isReleasedWhenClosed = false

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.appearance = NSAppearance(named: .vibrantDark)
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        visualEffect.autoresizingMask = [.width, .height]

        let dot = NSView(frame: NSRect(x: 16, y: height - 26, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.0
        dot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0).cgColor

        let label = NSTextField(labelWithString: "Listening…")
        label.frame = NSRect(x: 30, y: height - 31, width: 220, height: 18)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(white: 1.0, alpha: 0.65)

        // Microphone level: proves the input is alive while listening.
        let track = NSView(frame: NSRect(x: width - 76, y: height - 25, width: 60, height: 4))
        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        track.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 4))
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.75).cgColor
        track.addSubview(bar)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 12, width: width - 32, height: 28))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        tv.textColor = NSColor(white: 1.0, alpha: 0.5)
        tv.string = "Speak now…"
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: width - 32, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        scroll.documentView = tv

        visualEffect.addSubview(dot)
        visualEffect.addSubview(label)
        visualEffect.addSubview(track)
        visualEffect.addSubview(scroll)

        panel.contentView = visualEffect
        window = panel
        visualEffectView = visualEffect
        statusDot = dot
        statusLabel = label
        levelTrack = track
        levelBar = bar
        scrollView = scroll
        textView = tv
    }

    /// nil only while no display is attached (for example, a closed lid with no monitor).
    private func targetScreen() -> NSScreen? {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updatePositionAndSize(animated: Bool = false) {
        guard let window, let scrollView, let statusDot, let statusLabel, let textView,
              let screen = targetScreen() else { return }

        let screenFrame = screen.visibleFrame
        let width = defaultWidth
        let horizontalPadding: CGFloat = 32.0
        let availableWidth = width - horizontalPadding

        let displayText = currentText.isEmpty ? "Speak now…" : currentText
        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let attrString = NSAttributedString(string: displayText, attributes: [.font: font])
        let bounds = attrString.boundingRect(
            with: NSSize(width: availableWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textHeight = max(24, min(ceil(bounds.height) + 4, maxTextHeight))
        let totalHeight = 32 + textHeight + 14

        let x = screenFrame.origin.x + (screenFrame.width - width) / 2.0
        let y = screenFrame.origin.y + 60.0
        let newFrame = NSRect(x: x, y: y, width: width, height: totalHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }

        statusDot.frame = NSRect(x: 16, y: totalHeight - 26, width: 8, height: 8)
        statusLabel.frame = NSRect(x: 30, y: totalHeight - 31, width: width - 120, height: 18)
        levelTrack?.frame = NSRect(x: width - 76, y: totalHeight - 25, width: 60, height: 4)
        scrollView.frame = NSRect(x: 16, y: 12, width: availableWidth, height: textHeight)
        textView.scrollToEndOfDocument(nil)
    }

    func show() {
        guard let window else { return }
        displayToken += 1
        onShow?()
        currentText = ""
        textView?.string = "Speak now…"
        textView?.textColor = NSColor(white: 1.0, alpha: 0.5)
        setState("listening")
        updatePositionAndSize(animated: false)

        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1.0
        }
        isCurrentlyActive = true
        startPulsing()
    }

    func hide() {
        onHide?()
        displayToken += 1
        guard let window, isCurrentlyActive else { return }
        isCurrentlyActive = false
        setLevel(0)
        stopPulsing()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                if !self.isCurrentlyActive {
                    window.orderOut(nil)
                }
            }
        })
    }

    func updateText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        currentText = trimmed
        if trimmed.isEmpty {
            textView?.string = "Listening…"
            textView?.textColor = NSColor(white: 1.0, alpha: 0.5)
        } else {
            textView?.string = trimmed
            textView?.textColor = NSColor(white: 1.0, alpha: 0.95)
        }
        updatePositionAndSize(animated: true)
    }

    func setState(_ state: String) {
        switch state.lowercased() {
        case "polishing":
            statusLabel?.stringValue = "Polishing with Gemini…"
            statusDot?.layer?.backgroundColor = NSColor(red: 0.65, green: 0.45, blue: 1.0, alpha: 1.0).cgColor
            stopPulsing()
        case "error":
            statusLabel?.stringValue = "Error"
            statusDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopPulsing()
            setLevel(0)
        default:
            statusLabel?.stringValue = "Listening…"
            statusDot?.layer?.backgroundColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0).cgColor
            startPulsing()
        }
    }

    private func startPulsing() {
        guard let layer = statusDot?.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.duration = 0.8
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "pulse")
    }

    private func stopPulsing() {
        statusDot?.layer?.removeAnimation(forKey: "pulse")
        statusDot?.layer?.opacity = 1.0
    }

    /// Shows a failure in the HUD itself, where the user is already looking, then
    /// hides it. Does not claim the Escape hotkey: nothing is in progress.
    func showError(_ message: String) {
        guard let window else { return }
        displayToken += 1
        let token = displayToken
        currentText = message
        textView?.string = message
        textView?.textColor = NSColor(white: 1.0, alpha: 0.95)
        setState("error")
        updatePositionAndSize(animated: false)
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1.0
        }
        isCurrentlyActive = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard self.displayToken == token else { return }
            self.hide()
        }
    }

    /// Input level, as frame RMS (0...1). Speech sits around 0.01-0.2, so the
    /// meter uses a square-root scale to keep quiet speech visible.
    func setLevel(_ rms: Double) {
        guard let levelTrack, let levelBar else { return }
        let scaled = min(1, max(0, (rms / 0.25).squareRoot()))
        levelBar.frame = NSRect(x: 0, y: 0, width: levelTrack.bounds.width * scaled, height: levelTrack.bounds.height)
    }

    /// Status-line-only update: never touches state, dot, or transcript text.
    /// Used for progress feedback while finalizing.
    func updateStatus(_ text: String) {
        guard isCurrentlyActive else { return }
        statusLabel?.stringValue = text
    }

    /// One-shot acknowledgement blip that never changes state or text.
    /// Used when a toggle arrives while finalizing so the keypress feels
    /// received instead of dead.
    func nudge() {
        guard isCurrentlyActive, let layer = statusDot?.layer else { return }
        layer.removeAnimation(forKey: "nudge")
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.duration = 0.12
        pop.fromValue = 1.0
        pop.toValue = 1.7
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pop.autoreverses = true
        pop.repeatCount = 1
        pop.isRemovedOnCompletion = true
        layer.add(pop, forKey: "nudge")
    }
}
