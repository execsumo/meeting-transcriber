import Foundation

/// Manages the lifecycle of the `transcribe --watch` Python process.
final class PythonProcess {
    private var process: Process?
    let projectRoot: String

    var isRunning: Bool { process?.isRunning == true }

    init() {
        // 1. TRANSCRIBER_ROOT env var (set by run_app.sh)
        // 2. Walk up from executable looking for pyproject.toml
        if let envRoot = ProcessInfo.processInfo.environment["TRANSCRIBER_ROOT"] {
            projectRoot = envRoot
        } else {
            projectRoot = Self.findProjectRoot() ?? FileManager.default.currentDirectoryPath
        }
    }

    func start(arguments: [String] = ["--watch"]) {
        guard process == nil || process?.isRunning == false else { return }

        let venvBin = (projectRoot as NSString).appendingPathComponent(".venv/bin")
        let transcribePath = (venvBin as NSString).appendingPathComponent("transcribe")

        guard FileManager.default.fileExists(atPath: transcribePath) else {
            print("Error: transcribe binary not found at \(transcribePath)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: transcribePath)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)

        // Set up environment so Python finds the venv
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = (projectRoot as NSString).appendingPathComponent(".venv")
        env["PATH"] = "\(venvBin):\(env["PATH"] ?? "/usr/bin")"
        proc.environment = env

        // Pipe stdout/stderr so they don't clutter the app's console
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
        } catch {
            print("Failed to start transcribe process: \(error)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }

        // SIGINT → Python catches KeyboardInterrupt for graceful shutdown
        proc.interrupt()

        // Give it 5 seconds, then force terminate
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let proc = self.process, proc.isRunning else { return }
            proc.terminate()
        }
    }

    // MARK: - Project Root Discovery

    private static func findProjectRoot() -> String? {
        var dir = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()

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
