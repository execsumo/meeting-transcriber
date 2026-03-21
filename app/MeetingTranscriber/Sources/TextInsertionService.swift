import ApplicationServices
import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "TextInsertion")

/// Inserts transcribed text into the currently focused application.
/// Uses clipboard paste as the primary method (most reliable across apps),
/// with CGEvent unicode insertion as a fallback.
enum TextInsertionService {
    /// Maximum UTF-16 code units per CGEvent unicode insertion.
    private static let cgEventUnicodeLimit = 200

    /// Insert text into the currently focused app via clipboard paste.
    /// Snapshots and restores the previous clipboard contents.
    static func insertText(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        // Snapshot current clipboard
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Send Cmd+V
        sendPasteKeystroke()

        // Restore clipboard after a brief delay to let paste complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Only restore if no one else changed the clipboard
            if pasteboard.changeCount == previousChangeCount + 1 {
                pasteboard.clearContents()
                if let previous = previousContents {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }

        logger.info("Inserted \(text.count) characters via clipboard paste")
    }

    /// Insert text using CGEvent unicode insertion targeted at a specific PID.
    /// Falls back to clipboard paste if CGEvent fails.
    static func insertTextDirect(_ text: String, targetPID: pid_t? = nil) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        for chunkStart in stride(from: 0, to: utf16.count, by: cgEventUnicodeLimit) {
            let end = min(chunkStart + cgEventUnicodeLimit, utf16.count)
            var chunk = Array(utf16[chunkStart ..< end])

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                // CGEvent creation failed — fall back to clipboard
                logger.warning("CGEvent creation failed, falling back to clipboard paste")
                insertText(text)
                return
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)

            if let pid {
                keyDown.postToPid(pid)
                keyUp.postToPid(pid)
            } else {
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        logger.info("Inserted \(text.count) characters via CGEvent unicode")
    }

    /// Capture the PID of the currently focused application.
    static func captureFocusedPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Activate the application with the given PID (bring to front).
    static func activateApp(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    // MARK: - Private

    /// Simulate Cmd+V keystroke via CGEvent.
    private static func sendPasteKeystroke() {
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
