import ApplicationServices
import AVFoundation
import Foundation

enum Permissions {
    static func ensureMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return false
    }

    private static var hasPromptedAccessibility = false
    static func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !hasPromptedAccessibility else { return false }
        hasPromptedAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Walk up from executable to find the project root (directory containing pyproject.toml).
    static func findProjectRoot(from startURL: URL? = nil) -> String? {
        let start = startURL ?? URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        var dir = start.deletingLastPathComponent()

        for _ in 0..<10 {
            let pyproject = dir.appendingPathComponent("pyproject.toml")
            if FileManager.default.fileExists(atPath: pyproject.path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
