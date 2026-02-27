import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @State private var monitor = StatusMonitor()
    @State private var settings = AppSettings()
    @Environment(\.openWindow) private var openWindow
    private let pythonProcess = PythonProcess()
    private let notifications = NotificationManager.shared

    init() {
        // LSUIElement in Info.plist hides Dock icon.
        // Defer notification setup to after bundle is available.
        notifications.setUp()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: monitor.status,
                isWatching: pythonProcess.isRunning,
                onStartStop: toggleWatching,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: { openWindow(id: "settings") },
                onQuit: quit
            )
        } label: {
            Label(
                monitor.status?.state.label ?? "Idle",
                systemImage: monitor.status?.state.icon ?? "waveform.circle"
            )
        }
        .onChange(of: monitor.status?.state) { oldValue, newValue in
            guard let newValue, let status = monitor.status else { return }
            notifications.handleTransition(from: oldValue, to: newValue, status: status)
        }

        Window("Settings", id: "settings") {
            SettingsView(settings: settings)
        }
        .windowResizability(.contentSize)
    }

    private func toggleWatching() {
        if pythonProcess.isRunning {
            pythonProcess.stop()
        } else {
            monitor.start()
            pythonProcess.start(arguments: settings.buildArguments())
        }
    }

    private func openLastProtocol() {
        guard let path = monitor.status?.protocolPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openProtocolsFolder() {
        let protocols = URL(fileURLWithPath: pythonProcess.projectRoot)
            .appendingPathComponent("protocols")

        // Create if needed, then open
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func quit() {
        pythonProcess.stop()
        // Give Python a moment to clean up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}
