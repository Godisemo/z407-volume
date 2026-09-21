import AppKit

/// Volume popup in the style of the system one. The system HUD can't be used: the private
/// OSDManager calls still exist on macOS 26+, but OSDUIHelper no longer shows anything for them.
@MainActor
enum VolumeHUD {
    private static let panel = HUDPanel()

    static func show(level: Int, steps: Int, muted: Bool = false) {
        panel.show(fraction: muted ? 0 : Double(level) / Double(max(steps, 1)), muted: muted)
    }
}

@MainActor
private final class HUDPanel {
    private let size = NSSize(width: 240, height: 52)
    private let margin: CGFloat = 12
    private let visibleFor: TimeInterval = 1.5

    private let window: NSPanel
    private let icon = NSImageView()
    private let bar = LevelBar()
    private var hideTimer: Timer?

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .init(Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: size.height / 2)
        window.contentView = background

        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentTintColor = .labelColor
        let row = NSStackView(views: [icon, bar])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            bar.heightAnchor.constraint(equalToConstant: 6),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }

    func show(fraction: Double, muted: Bool) {
        icon.image = NSImage(systemSymbolName: Self.symbol(fraction: fraction, muted: muted),
                             accessibilityDescription: muted ? "Muted" : "Volume")
        bar.fraction = fraction

        // Top-right of the screen under the pointer, below the menu bar.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.maxX - size.width - margin, y: area.maxY - size.height - margin))
        }
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: visibleFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; window.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window.alphaValue == 0 else { return }
                self.window.orderOut(nil)
            }
        }
    }

    private static func symbol(fraction: Double, muted: Bool) -> String {
        switch fraction {
        case _ where muted: "speaker.slash.fill"
        case 0: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class LevelBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * min(fraction, 1))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
