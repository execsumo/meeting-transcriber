import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    private let whisperModels = [
        "large-v3-turbo-q5_0",
        "large-v3-turbo",
        "large-v3",
        "medium",
        "small",
        "base",
        "tiny",
    ]

    var body: some View {
        Form {
            Section("Apps to Watch") {
                Toggle("Microsoft Teams", isOn: $settings.watchTeams)
                Toggle("Zoom", isOn: $settings.watchZoom)
                Toggle("Webex", isOn: $settings.watchWebex)
            }

            Section("Recording") {
                HStack {
                    Text("Poll Interval")
                    Spacer()
                    TextField("", value: $settings.pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.pollInterval, in: 1...30, step: 0.5)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Grace Period")
                    Spacer()
                    TextField("", value: $settings.endGrace, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.endGrace, in: 5...120, step: 5)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                Toggle("No Microphone (app audio only)", isOn: $settings.noMic)
            }

            Section("Transcription") {
                Picker("Whisper Model", selection: $settings.whisperModel) {
                    ForEach(whisperModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                Toggle("Speaker Diarization", isOn: $settings.diarize)

                if settings.diarize {
                    HStack {
                        Text("Expected Speakers")
                        Spacer()
                        TextField("", value: $settings.numSpeakers, format: .number)
                            .frame(width: 40)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $settings.numSpeakers, in: 2...10)
                            .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: settings.diarize ? 400 : 360)
    }
}
