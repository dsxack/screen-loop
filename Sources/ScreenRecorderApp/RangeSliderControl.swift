import AppKit

@MainActor
final class RangeSliderControl: NSControl {
    enum Handle {
        case lower
        case upper
    }

    var minimumValue: Double = 0 {
        didSet {
            normalizeRange()
        }
    }

    var maximumValue: Double = 1 {
        didSet {
            normalizeRange()
        }
    }

    var minimumRange: Double = 0 {
        didSet {
            normalizeRange()
        }
    }

    private(set) var lowerValue: Double = 0
    private(set) var upperValue: Double = 1
    private(set) var activeHandle: Handle?

    private let handleRadius: CGFloat = 8
    private let trackHeight: CGFloat = 4

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
        }
    }

    func setRange(lower: Double, upper: Double, notify: Bool = false) {
        let oldLower = lowerValue
        let oldUpper = upperValue
        let normalized = normalizedRange(lower: lower, upper: upper)

        lowerValue = normalized.lower
        upperValue = normalized.upper
        needsDisplay = true

        guard notify, oldLower != lowerValue || oldUpper != upperValue else {
            return
        }

        _ = sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let track = trackRect
        let lowerX = xPosition(for: lowerValue)
        let upperX = xPosition(for: upperValue)
        let baseColor = isEnabled ? NSColor.quaternaryLabelColor : NSColor.separatorColor
        let selectedColor = isEnabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor

        baseColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let selectedRect = NSRect(
            x: min(lowerX, upperX),
            y: track.minY,
            width: max(0, abs(upperX - lowerX)),
            height: track.height
        )
        selectedColor.withAlphaComponent(isEnabled ? 0.85 : 0.45).setFill()
        NSBezierPath(roundedRect: selectedRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        drawHandle(at: lowerX, active: activeHandle == .lower)
        drawHandle(at: upperX, active: activeHandle == .upper)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        activeHandle = nearestHandle(to: location.x)
        updateActiveHandle(at: location.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        if activeHandle == nil {
            activeHandle = nearestHandle(to: location.x)
        }
        updateActiveHandle(at: location.x)
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func normalizeRange() {
        setRange(lower: lowerValue, upper: upperValue)
    }

    private func normalizedRange(lower: Double, upper: Double) -> (lower: Double, upper: Double) {
        let lowerBound = min(minimumValue, maximumValue)
        let upperBound = max(minimumValue, maximumValue)
        let gap = min(max(0, minimumRange), max(0, upperBound - lowerBound))
        var normalizedLower = min(max(lower, lowerBound), upperBound)
        var normalizedUpper = min(max(upper, lowerBound), upperBound)

        if normalizedLower > normalizedUpper {
            swap(&normalizedLower, &normalizedUpper)
        }

        if normalizedUpper - normalizedLower < gap {
            let midpoint = (normalizedLower + normalizedUpper) / 2
            normalizedLower = midpoint - gap / 2
            normalizedUpper = midpoint + gap / 2

            if normalizedLower < lowerBound {
                normalizedLower = lowerBound
                normalizedUpper = min(upperBound, normalizedLower + gap)
            }

            if normalizedUpper > upperBound {
                normalizedUpper = upperBound
                normalizedLower = max(lowerBound, normalizedUpper - gap)
            }
        }

        return (normalizedLower, normalizedUpper)
    }

    private func updateActiveHandle(at xPosition: CGFloat) {
        let value = value(for: xPosition)
        let gap = min(max(0, minimumRange), max(0, maximumValue - minimumValue))

        switch activeHandle {
        case .lower:
            setRange(lower: min(value, upperValue - gap), upper: upperValue, notify: true)
        case .upper:
            setRange(lower: lowerValue, upper: max(value, lowerValue + gap), notify: true)
        case nil:
            break
        }
    }

    private func nearestHandle(to xPosition: CGFloat) -> Handle {
        let lowerDistance = abs(xPosition - self.xPosition(for: lowerValue))
        let upperDistance = abs(xPosition - self.xPosition(for: upperValue))
        return lowerDistance <= upperDistance ? .lower : .upper
    }

    private var trackRect: NSRect {
        let horizontalInset = handleRadius + 2
        return NSRect(
            x: horizontalInset,
            y: bounds.midY - trackHeight / 2,
            width: max(1, bounds.width - horizontalInset * 2),
            height: trackHeight
        )
    }

    private func xPosition(for value: Double) -> CGFloat {
        let valueRange = maximumValue - minimumValue
        guard valueRange > 0 else {
            return trackRect.minX
        }

        let fraction = min(max((value - minimumValue) / valueRange, 0), 1)
        return trackRect.minX + CGFloat(fraction) * trackRect.width
    }

    private func value(for xPosition: CGFloat) -> Double {
        let track = trackRect
        guard track.width > 0 else {
            return minimumValue
        }

        let fraction = min(max((xPosition - track.minX) / track.width, 0), 1)
        return minimumValue + Double(fraction) * (maximumValue - minimumValue)
    }

    private func drawHandle(at xPosition: CGFloat, active: Bool) {
        let rect = NSRect(
            x: xPosition - handleRadius,
            y: bounds.midY - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        )
        let path = NSBezierPath(ovalIn: rect)

        (isEnabled ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor).setFill()
        path.fill()

        let strokeColor: NSColor
        if !isEnabled {
            strokeColor = .disabledControlTextColor
        } else if active {
            strokeColor = .controlAccentColor
        } else {
            strokeColor = .tertiaryLabelColor
        }

        strokeColor.setStroke()
        path.lineWidth = active ? 2.5 : 1.5
        path.stroke()
    }
}
