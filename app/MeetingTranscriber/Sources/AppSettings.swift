import SwiftUI

@Observable
final class AppSettings {
    // MARK: - Apps to Watch

    @ObservationIgnored @AppStorage("watchTeams") var watchTeams = true
    @ObservationIgnored @AppStorage("watchZoom") var watchZoom = true
    @ObservationIgnored @AppStorage("watchWebex") var watchWebex = true

    // MARK: - Recording

    @ObservationIgnored @AppStorage("pollInterval") var pollInterval = 3.0
    @ObservationIgnored @AppStorage("endGrace") var endGrace = 15.0
    @ObservationIgnored @AppStorage("noMic") var noMic = false

    // MARK: - Transcription

    @ObservationIgnored @AppStorage("whisperModel") var whisperModel = "large-v3-turbo-q5_0"
    @ObservationIgnored @AppStorage("diarize") var diarize = false
    @ObservationIgnored @AppStorage("numSpeakers") var numSpeakers = 2

    // MARK: - Computed

    var watchApps: [String] {
        var apps: [String] = []
        if watchTeams { apps.append("Microsoft Teams") }
        if watchZoom { apps.append("Zoom") }
        if watchWebex { apps.append("Webex") }
        return apps
    }

    func buildArguments() -> [String] {
        var args = ["--watch"]

        // Apps
        let apps = watchApps
        if !apps.isEmpty && apps.count < 3 {
            args += ["--watch-apps"] + apps
        }

        // Recording
        if pollInterval != 3.0 {
            args += ["--poll-interval", String(pollInterval)]
        }
        if endGrace != 15.0 {
            args += ["--end-grace", String(endGrace)]
        }
        if noMic {
            args.append("--no-mic")
        }

        // Transcription
        if whisperModel != "large-v3-turbo-q5_0" {
            args += ["--model", whisperModel]
        }
        if diarize {
            args.append("--diarize")
            args += ["--speakers", String(numSpeakers)]
        }

        return args
    }
}
