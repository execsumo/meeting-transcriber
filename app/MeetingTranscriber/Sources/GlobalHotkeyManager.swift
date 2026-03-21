import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "GlobalHotkey")

/// Stores a hotkey shortcut as key code + modifier flags.
struct HotkeyShortcut: Equatable, Codable {
    var keyCode: UInt16
    var modifierFlags: UInt // NSEvent.ModifierFlags.rawValue

    /// Default: Option+D
    static let `default` = HotkeyShortcut(
        keyCode: UInt16(kVK_ANSI_D),
        modifierFlags: NSEvent.ModifierFlags.option.rawValue
    )

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    /// Human-readable label like "Option+D".
    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("\u{2303}") }
        if modifiers.contains(.option) { parts.append("\u{2325}") }
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }
        if let name = Self.keyName(keyCode) {
            parts.append(name)
        }
        return parts.joined()
    }

    /// Map common key codes to display names.
    private static func keyName(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Escape: "Esc"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: nil
        }
    }
}

/// Manages a system-wide CGEvent tap for global hotkey detection.
/// Triggers callbacks on hotkey press/release for dictation toggle or push-to-talk.
final class GlobalHotkeyManager: @unchecked Sendable {
    enum Mode: String, CaseIterable, Codable {
        case toggle
        case pushToTalk
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: HotkeyShortcut
    private var mode: Mode

    private let lock = NSLock()
    private var isPressed = false

    /// Called on the main thread when dictation should start.
    var onStart: (() -> Void)?
    /// Called on the main thread when dictation should stop.
    var onStop: (() -> Void)?

    init(shortcut: HotkeyShortcut = .default, mode: Mode = .toggle) {
        self.shortcut = shortcut
        self.mode = mode
    }

    deinit {
        disable()
    }

    /// Update the hotkey shortcut. Restarts the tap if currently enabled.
    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        let wasEnabled = eventTap != nil
        if wasEnabled { disable() }
        shortcut = newShortcut
        if wasEnabled { enable() }
    }

    /// Update the trigger mode.
    func updateMode(_ newMode: Mode) {
        mode = newMode
    }

    /// Install the CGEvent tap. Requires Accessibility permission.
    func enable() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility not trusted — cannot install event tap")
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // Use Unmanaged to pass self pointer to C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: globalHotkeyCallback,
            userInfo: selfPtr
        ) else {
            logger.error("Failed to create CGEvent tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        logger.info("Global hotkey enabled: \(self.shortcut.displayString) (\(self.mode.rawValue))")
    }

    /// Remove the CGEvent tap.
    func disable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            logger.info("Global hotkey disabled")
        }
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it was disabled by the system (timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection([.command, .option, .shift, .control])

        guard keyCode == shortcut.keyCode,
              nsFlags == shortcut.modifiers else {
            return Unmanaged.passUnretained(event)
        }

        // Matched our hotkey — filter key repeats
        let isKeyDown = type == .keyDown
        var isRepeat = false
        if isKeyDown {
            lock.withLock {
                isRepeat = isPressed
                isPressed = true
            }
        } else {
            lock.withLock { isPressed = false }
        }

        switch mode {
        case .toggle:
            if isKeyDown, !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    self?.onStart?()
                }
            }

        case .pushToTalk:
            if isKeyDown, !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    self?.onStart?()
                }
            } else if !isKeyDown {
                DispatchQueue.main.async { [weak self] in
                    self?.onStop?()
                }
            }
        }

        // Suppress the hotkey event so it doesn't reach the focused app
        return nil
    }
}

// MARK: - CGEvent Tap Callback (C function)

private func globalHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type: type, event: event)
}

