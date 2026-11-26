// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import SwiftUI

/// Turns scroll and drag deltas into whole knob steps (positive = clockwise / up).
/// A mouse wheel's notch is one step however fast it spins; trackpad and drag deltas accumulate
/// until they cover a step, and the remainder carries over.
struct KnobStepAccumulator {
    var pointsPerScrollStep: Double = 12
    var pointsPerDragStep: Double = 8
    private var scrollResidue = 0.0
    private var dragResidue = 0.0

    init(pointsPerScrollStep: Double = 12, pointsPerDragStep: Double = 8) {
        self.pointsPerScrollStep = pointsPerScrollStep
        self.pointsPerDragStep = pointsPerDragStep
    }

    /// `precise` is `NSEvent.hasPreciseScrollingDeltas` (trackpad, Magic Mouse).
    mutating func scroll(delta: Double, precise: Bool) -> Int {
        guard precise else {
            scrollResidue = 0
            return delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        }
        return Self.take(&scrollResidue, delta, per: pointsPerScrollStep)
    }

    /// `delta` in points, positive = up.
    mutating func drag(delta: Double) -> Int { Self.take(&dragResidue, delta, per: pointsPerDragStep) }

    mutating func reset() {
        scrollResidue = 0
        dragResidue = 0
    }

    private static func take(_ residue: inout Double, _ delta: Double, per step: Double) -> Int {
        residue += delta
        let steps = Int(residue / step)  // toward zero
        residue -= Double(steps) * step
        return steps
    }
}

/// The scanner level a knob turn asks for.
enum LevelStepper {
    /// Builds on the last value asked for (`pending`, not yet reported back by the scanner), else
    /// the scanner's `current` level; clamped to `range`. Nil when the level is unknown, or when the
    /// result is the value already asked for (nothing to send).
    static func target(current: Int?, pending: Int?, steps: Int, range: ClosedRange<Int>) -> Int? {
        guard let base = pending ?? current else { return nil }
        let next = min(max(base + steps, range.lowerBound), range.upperBound)
        return next == base ? nil : next
    }
}

/// A front-panel knob: scroll or drag turns it (`onSteps`), a click pushes it (`onPush`).
/// `angle` is where its pointer sits, in degrees from straight up.
struct KnobView: View {
    let title: String
    /// The push function's name, shown as a second-function caption.
    let pushCaption: String
    /// Help text in place of the default tooltip, or nil.
    var help: String? = nil
    /// A readout under the knob (the level), or nil.
    let readout: String?
    let angle: Double
    let enabled: Bool
    let onSteps: (Int) -> Void
    let onPush: () -> Void
    var diameter: CGFloat = 58

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.16)],
                                         center: UnitPoint(x: 0.4, y: 0.32), startRadius: 2, endRadius: diameter * 0.7))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
                    .overlay(Circle().inset(by: 4).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                Capsule()
                    .fill(Color.orange.opacity(enabled ? 0.95 : 0.35))
                    .frame(width: 3, height: diameter * 0.22)
                    .offset(y: -diameter * 0.3)
                    .rotationEffect(.degrees(angle))
                    .animation(.easeOut(duration: 0.15), value: angle)
                KnobInput(enabled: enabled, onSteps: onSteps, onPush: onPush)
            }
            .frame(width: diameter, height: diameter)
            .opacity(enabled ? 1 : 0.55)
            .help(help.map { "\(title): scroll or drag to turn, click to push. \($0)" }
                    ?? "\(title): scroll or drag to turn, click to push (\(pushCaption))")

            VStack(spacing: 1) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.88))
                Text(pushCaption).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.orange)
                Text(readout ?? " ").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.7))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(readout ?? "")
        .accessibilityHint("Push: \(pushCaption)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if enabled { onSteps(1) }
            case .decrement: if enabled { onSteps(-1) }
            @unknown default: break
            }
        }
        .accessibilityAction { if enabled { onPush() } }
    }
}

/// The knob's mouse handling: AppKit, because SwiftUI has no scroll-wheel events for plain views.
/// A disabled knob ignores scroll, drag and click and shows the ordinary cursor.
struct KnobInput: NSViewRepresentable {
    let enabled: Bool
    let onSteps: (Int) -> Void
    let onPush: () -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.enabled = enabled
        view.onSteps = onSteps
        view.onPush = onPush
    }

    class InputView: NSView {
        var onSteps: (Int) -> Void = { _ in }
        var onPush: () -> Void = {}
        var enabled = true {
            didSet { if enabled != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        private var steps = KnobStepAccumulator()
        private var dragged = 0.0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            guard enabled else { return super.scrollWheel(with: event) }
            if event.phase == .began { steps.reset() }
            // Physical direction: finger or wheel moving up turns clockwise, natural scrolling or not.
            let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
            let n = steps.scroll(delta: delta, precise: event.hasPreciseScrollingDeltas)
            if n != 0 { onSteps(n) }
        }

        override func mouseDown(with event: NSEvent) {
            steps.reset()
            dragged = 0
        }

        override func mouseDragged(with event: NSEvent) {
            dragged += abs(Double(event.deltaY)) + abs(Double(event.deltaX))
            let n = steps.drag(delta: -Double(event.deltaY))  // deltaY grows downwards
            if n != 0 && enabled { onSteps(n) }
        }

        override func mouseUp(with event: NSEvent) {
            // A click, not a turn: it barely moved.
            if dragged < 4 && enabled { onPush() }
        }

        override func resetCursorRects() {
            if enabled { addCursorRect(bounds, cursor: .pointingHand) }
        }
    }
}
#endif
