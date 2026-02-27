import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let onStartStop: () -> Void
    let onOpenLastProtocol: () -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    var body: some View {
        // Status header
        VStack(alignment: .leading, spacing: 2) {
            Label(state.label, systemImage: state.icon)
                .font(.headline)

            if let detail = status?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)

        // Meeting info
        if let meeting = status?.meeting {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(meeting.app) (PID \(meeting.pid))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }

        // Error info
        if let error = status?.error, state == .error {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        }

        Divider()

        // Start/Stop Watching
        Button {
            onStartStop()
        } label: {
            if isWatching {
                Label("Stop Watching", systemImage: "stop.fill")
            } else {
                Label("Start Watching", systemImage: "play.fill")
            }
        }
        .keyboardShortcut("s")

        Divider()

        // Open last protocol
        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }

        Divider()

        Button {
            onOpenSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")

        Divider()

        Button {
            onQuit()
        } label: {
            Text("Quit")
        }
        .keyboardShortcut("q")
    }
}
