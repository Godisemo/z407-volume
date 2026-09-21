import AppKit

/// Active CGEventTap on system-defined (media key) events. Consuming the volume and mute keys
/// here stops macOS from handling them, which also suppresses the "volume locked" HUD.
/// Requires Accessibility permission; `start()` returns false until it is granted.
/// Used only from the main thread; the tap's run loop source is on the main run loop.
final class MediaKeyTap {
    enum Key { case volumeUp, volumeDown, mute }

    var onPress: (@MainActor (Key) -> Void)?
    /// When false, all keys pass through to macOS untouched.
    var isIntercepting = true
    /// When false, the mute key passes through while volume keys are still intercepted.
    var interceptsMute = true
    var isRunning: Bool { tap != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // From IOKit/hidsystem/ev_keymap.h and NSEvent.h
    private let systemDefinedEventType: UInt32 = 14      // NX_SYSDEFINED
    private let auxControlButtonsSubtype: Int16 = 8      // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private let soundUpKeyType = 0                       // NX_KEYTYPE_SOUND_UP
    private let soundDownKeyType = 1                     // NX_KEYTYPE_SOUND_DOWN
    private let muteKeyType = 7                          // NX_KEYTYPE_MUTE
    private let keyDownState = 0x0A

    func start() -> Bool {
        if tap != nil { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << systemDefinedEventType,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        // macOS disables taps that are slow or when secure input toggles; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }
        guard isIntercepting, type.rawValue == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxControlButtonsSubtype else { return passThrough }

        let data1 = nsEvent.data1
        let key: Key
        switch (data1 & 0xFFFF_0000) >> 16 {
        case soundUpKeyType: key = .volumeUp
        case soundDownKeyType: key = .volumeDown
        case muteKeyType where interceptsMute: key = .mute
        default: return passThrough
        }
        // Key-down and auto-repeat both arrive as the down state (repeat flag in bit 0); key-up
        // is swallowed too so macOS never sees half a keypress. Mute is a toggle, so no repeats.
        let isRepeat = data1 & 0x1 != 0
        if (data1 & 0xFF00) >> 8 == keyDownState, !(key == .mute && isRepeat), let onPress {
            MainActor.assumeIsolated { onPress(key) }
        }
        return nil
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
