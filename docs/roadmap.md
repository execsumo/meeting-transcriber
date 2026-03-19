# Roadmap

## High Priority

### Push-to-talk dictation

**Status:** Not started
**Priority:** High
**Inspiration:** [Handy](https://github.com/cjpais/Handy) — local push-to-talk dictation app (Rust/Tauri)

Add Handy-style dictation to the menu bar app: hold a configurable hotkey → speak → release → transcribed text is pasted into the focused app. Leverages existing mic recording and Parakeet transcription infrastructure.

#### Core dictation flow

**Hold hotkey → record mic → release → transcribe → (optional) post-process → paste into focused app**

1. **Global hotkey manager** (~200-300 lines, new `HotkeyManager.swift`)
   - `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for modifier keys, or `CGEventTap` for arbitrary keys
   - Accessibility permission already granted — prerequisite satisfied
   - Key-down → start recording, key-up → stop + transcribe
   - Debounce rapid key repeats (~30ms threshold, same as Handy)
   - Hotkey picker UI in Settings (custom key recorder view)

2. **Dictation controller** (~150-200 lines, new `DictationController.swift`)
   - Thin wrapper around existing `MicRecorder` / `AVAudioEngine` — no dual-source, no mixing
   - Single-mic capture to temp WAV, reuse existing mic device selection from `AppSettings.micDeviceUID`
   - On release: feed WAV to `FluidTranscriptionEngine.transcribe()` → extract plain text
   - No diarization, no protocol generation, no VAD — direct path only
   - Model already loaded if app is running (shared `FluidTranscriptionEngine` instance) — near-zero cold start

3. **Text insertion** (~50-80 lines, part of `DictationController`)
   - Save current clipboard contents (`NSPasteboard.general`)
   - Copy transcribed text to clipboard
   - Synthesize Cmd+V via `CGEvent` to paste into focused app
   - Restore original clipboard contents after paste
   - App Store variant: verify `CGEvent` keyboard synthesis works within sandbox, may need alternative approach

4. **Settings UI** (~100-150 lines, edit `SettingsView.swift` + `AppSettings.swift`)
   - Enable/disable dictation toggle
   - Hotkey picker (record a key combination)
   - Post-processing toggle + prompt selection (see below)
   - Custom words list (see below)

5. **Menu bar integration** (~30-50 lines, edit `MenuBarView.swift`)
   - Visual indicator when dictation is active (recording state)
   - Toggle dictation on/off from menu

#### Post-processing via LLM

Optional LLM cleanup of the raw transcript before pasting, matching Handy's approach.

**How Handy does it:** Sends the raw transcript to a configurable OpenAI-compatible API endpoint with a user-selected prompt. Supports structured JSON output. Two separate hotkeys: one for raw transcription, one for transcribe-then-post-process.

**Implementation approach:**
- Reuse existing `OpenAIProtocolGenerator` HTTP client infrastructure (already supports any OpenAI-compatible API)
- Add `DictationPostProcessor` that sends transcript + system prompt to the configured LLM endpoint
- Multiple named prompts (like Handy's `post_process_prompts: Vec<LLMPrompt>`) — user can create/select prompts for different use cases (e.g., "clean up filler words", "format as bullet points", "translate to English")
- Settings: enable/disable, select prompt, configure provider (reuse existing OpenAI-compatible provider settings or add dictation-specific ones)
- Strip filler words list: configurable `custom_filler_words` that are removed before/after LLM processing
- Consider two hotkey bindings: one for raw dictation, one for dictation + post-processing (Handy's `--toggle-transcription` vs `--toggle-post-process` pattern)

#### Custom vocabulary (FluidAudio native)

Guide transcription toward domain-specific terminology (project names, technical terms, proper nouns). Shared between dictation and meeting transcription.

**FluidAudio's built-in approach** ([CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)):
Uses acoustic-level vocabulary boosting — a second CTC encoder (Parakeet 110M) runs alongside the primary TDT encoder and scores custom terms directly against the audio signal. Three-pass pipeline: keyword spotting → alignment → evaluation with guards. Only replaces when acoustic evidence supports it. Supports aliases for common misrecognition variants. Already in our dependency via FluidAudio.

```swift
let vocabulary = CustomVocabularyContext(terms: [
    CustomVocabularyTerm(text: "FluidAudio"),
    CustomVocabularyTerm(text: "macOS", aliases: ["Mac OS", "Macos"]),
])
let result = try await asrManager.transcribe(audioSamples, customVocabulary: vocabulary)
```

**Implementation:**
- Store custom vocabulary terms in `AppSettings` (persisted to UserDefaults)
- Build `CustomVocabularyContext` from stored terms and pass to `FluidTranscriptionEngine.transcribe()` / `transcribeSegments()`
- Shared between dictation and meeting transcription — same word list feeds both paths
- Also pass custom vocabulary terms to the protocol generation prompt for additional LLM context
- Alias support: allow users to add aliases per term for known misrecognition variants (stretch goal)
- Filler word removal: separate configurable list + built-in defaults (um, uh, like, you know, etc.), applied as simple string filtering after transcription (~30 lines)
- Guidelines: 1-50 terms recommended, up to 230 tested without latency impact, minimum 4 characters per term
- Memory: +~64 MB peak RAM for the CTC encoder (total ~130 MB vs ~66 MB TDT-only)

**Settings UI** (tag/chip pattern, inspired by Handy):
- Text field with Enter key or Add button to submit new terms
- Entered terms display as tag chips in a flex-wrap flow layout
- Each tag shows the term text + an × button to remove
- Input validation: trim whitespace, reject duplicates (show alert), enforce 4+ character minimum
- Tags stored as `[String]` in `AppSettings`, serialized to UserDefaults
- **Effort:** ~50-80 lines for `FluidTranscriptionEngine` integration, ~80-120 lines for tag chip UI in `SettingsView`

#### Effort estimate

| Component | Lines | Files |
|---|---|---|
| Global hotkey manager | ~200-300 | 1 new (`HotkeyManager.swift`) |
| Dictation controller + text insertion | ~200-280 | 1 new (`DictationController.swift`) |
| Post-processing via LLM | ~150-200 | 1 new (`DictationPostProcessor.swift`) |
| Custom vocabulary (FluidAudio integration) | ~50-80 | Edit `FluidTranscriptionEngine.swift` |
| Custom vocabulary tag UI + filler words | ~110-150 | Edit `SettingsView.swift` + `AppSettings.swift` |
| Settings UI (dictation controls) | ~100-150 | Edit `SettingsView.swift` + `AppSettings.swift` |
| Menu bar integration | ~30-50 | Edit `MenuBarView.swift` |
| Tests | ~250-350 | 2-3 new test files |
| **Total** | **~1100-1600** | **3 new + edits to 5-6 existing** |

## Code Health — Flagged Issues

Issues identified during code review. Labeled by severity and area.

### [BUG-MEMORY] DualSourceRecorder loads entire raw audio into memory

**File:** `DualSourceRecorder.swift:141`
**Severity:** Medium
**Priority:** High

`let raw = try Data(contentsOf: tempURL)` loads the full raw app audio file into memory. At 48kHz stereo float32, a 4-hour meeting produces ~5.5 GB, causing OOM on most machines.

**Fix:** Stream-convert the raw PCM to WAV in chunks instead of loading everything into `Data`. Options:
- Memory-map via `Data(contentsOf:options:.mappedIfSafe)` (avoids copy, OS pages in on demand)
- Stream through a fixed-size buffer: read N frames from the temp file, convert stereo→mono, write to output WAV
- The stereo→mono loop at line 161 and resample at line 170 both need to work on chunks

### [BUG-THREAD] MicCaptureHandler tap callback accesses shared state unsynchronized

**File:** `MicCaptureHandler.swift:114-154`
**Severity:** Medium
**Priority:** High

The audio tap callback runs on AVAudioEngine's realtime thread but reads/writes `self.firstFrameTime`, `self.converter`, `self.outputFile`, and `self.fileSampleRate` without synchronization. `handleDefaultInputDeviceChanged()` runs on the main thread and nulls `converter`, recreates the engine concurrently.

**Fix:** Protect shared state with `os_unfair_lock` or an atomic flag. The tap callback must not block, so a try-lock pattern is appropriate: if lock is held (restart in progress), drop the buffer.

### [BUG-THREAD] AppAudioCapture IOProc reads main-thread state from writeQueue

**File:** `AppAudioCapture.swift:160-176`
**Severity:** Low-Medium
**Priority:** Medium

The IOProc block runs on `writeQueue` but reads `self.isRunning` and writes `self.didLogFormat`/`self.appFirstFrameTime`, which are also modified from the main thread in `stopCapture()`/`handleOutputDeviceChanged()`. CoreAudio may fire the IOProc after `AudioDeviceStop()` returns.

**Fix:** Use `os_unfair_lock` or Swift `Atomic<Bool>` for `isRunning`. For `appFirstFrameTime`, a single atomic store from the IOProc + read from main thread is sufficient.

### [BUG-THREAD] AppAudioCapture rapid device changes can overlap restart logic

**File:** `AppAudioCapture.swift:238-268`
**Severity:** Medium
**Priority:** Medium

`handleOutputDeviceChanged()` stops capture, then schedules async restart at 0.5s with one retry at 1.5s. The `isRestarting` guard prevents re-entry during the initial block, but a second device change after 0.5s can stop the newly-started capture before `isRestarting` is reset.

**Fix:** Use a serial `DispatchQueue` for all device-change handling. Cancel any pending restart before starting a new one (store the `DispatchWorkItem` and call `.cancel()`).

### [SUBOPTIMAL] Transcript and protocol files get different timestamps

**File:** `PipelineQueue.swift:494, 510`
**Severity:** Low
**Priority:** Low

`saveTranscript` and `saveProtocol` both call `ProtocolGenerator.filename()` which uses `Date()`. Protocol generation runs between them (could be minutes), so files for the same meeting have mismatched timestamp prefixes (e.g., `20260319_1430_standup.txt` vs `20260319_1435_standup.md`).

**Fix:** Capture the timestamp once at the start of `processNext()` and pass it to both save calls. Add a `filename(title:ext:date:)` overload or extract the date string early.

### [SUBOPTIMAL] OpenAI error body read can throw, masking HTTP status

**File:** `OpenAIProtocolGenerator.swift:65-69`
**Severity:** Low
**Priority:** Low

When HTTP status is non-2xx, `for try await line in bytes.lines` reads the error body but can itself throw (e.g., connection reset). The thrown error propagates up, masking the original HTTP status code.

**Fix:** Wrap the error body read in `do { ... } catch { }` so the HTTP error is always thrown:
```swift
guard (200...299).contains(httpResponse.statusCode) else {
    var errorBody = ""
    do {
        for try await line in bytes.lines {
            errorBody += line
            if errorBody.count > 500 { break }
        }
    } catch { }
    throw ProtocolError.httpError(httpResponse.statusCode, errorBody)
}
```

### [SUBOPTIMAL] PipelineQueue slug derivation is fragile

**File:** `PipelineQueue.swift:602`
**Severity:** Low
**Priority:** Low

`ProtocolGenerator.filename(title: title, ext: "").dropLast()` relies on `filename()` producing a trailing `.` when ext is empty. If the format ever changes, this breaks.

**Fix:** Add a `slug(title:)` or `filenamePrefix(title:)` helper to `ProtocolGenerator` that returns the `date_slug` portion without the extension dot.

### [SUBOPTIMAL] NotificationManager uses print() instead of Logger

**File:** `NotificationManager.swift:19, 29, 31`
**Severity:** Low
**Priority:** Low

Three `print()` calls for permission errors. Rest of codebase uses `os.log` `Logger`. Makes these errors invisible in Console.app.

**Fix:** Replace `print(...)` with `Logger(subsystem:category:).error(...)` or `.warning(...)`.

### [SUBOPTIMAL] Security-scoped access ends before Finder opens folder (sandbox)

**File:** `MeetingTranscriberApp.swift:407-413`
**Severity:** Low
**Priority:** Low

`startAccessingSecurityScopedResource()` is paired with `defer { stop... }`, but `NSWorkspace.shared.open()` is asynchronous. In the App Store sandbox, the scoped access may end before Finder reads the directory. Non-sandboxed (Homebrew) variant unaffected.

**Fix:** Remove the `stopAccessingSecurityScopedResource()` call for `open()` — the bookmark retains access. Or delay the stop via `DispatchQueue.main.asyncAfter`.

### [SUBOPTIMAL] SettingsView .onAppear may re-trigger testConnection()

**File:** `SettingsView.swift` (OpenAI provider section)
**Severity:** Low-Medium
**Priority:** Low

`.onAppear` fires when SwiftUI re-creates the view (tab switch, provider change), calling `testConnection()` even if models are already loaded from the same endpoint.

**Fix:** Replace `.onAppear` with `.task(id: settings.openAIEndpoint)` so it only re-runs when the endpoint actually changes.

### [SUBOPTIMAL] testConnection() lacks deduplication

**File:** `SettingsView.swift`
**Severity:** Low
**Priority:** Low

Rapid clicks on "Fetch Models" spawn multiple concurrent tasks racing to update `availableModels`. Unlike `UpdateChecker.checkNow()` which guards with `checkTask == nil`, this function has no guard.

**Fix:** Store the task in a `@State var testConnectionTask: Task<Void, Never>?` and guard with `guard testConnectionTask == nil else { return }`.

### [SUBOPTIMAL] AppSettings.customOutputDir docstring is wrong

**File:** `AppSettings.swift:153`
**Severity:** Low
**Priority:** Low

Comment says "Calls `startAccessingSecurityScopedResource()`" but the computed property doesn't call it. Callers (`saveTranscript`, `saveProtocol`, `copyAudioToOutput`) do call it, so behavior is correct.

**Fix:** Update the docstring to remove the incorrect claim.

### [SUBOPTIMAL] MicCaptureHandler buffer capacity truncation

**File:** `MicCaptureHandler.swift:124-127`
**Severity:** Low
**Priority:** Low

`AVAudioFrameCount(Double(buffer.frameLength) * ratio)` truncates fractional frames when upsampling (e.g., 44.1kHz→48kHz). Over a long recording, this accumulates ~0.02% timing drift.

**Fix:** Use `AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))` to round up instead of truncating.

## Low Priority

### Replace Screen Recording with Accessibility API for meeting detection

**Status:** Not started
**Priority:** Low

Currently `MeetingDetector` uses `CGWindowListCopyWindowInfo` (requires Screen Recording permission) to enumerate all windows. Since we only need to detect MS Teams meetings, we could use Accessibility APIs instead (`AXUIElementCreateApplication` + `kAXTitleAttribute`), which the app already has permission for.

**Motivation:** Reduce actual data access scope — current code polls all app windows, targeted AX approach would only touch Teams.

**Note:** This is _not_ a strict security improvement. Accessibility permission is equally (or more) powerful than Screen Recording. The benefit is narrower code-level scope, not a reduced permission ceiling.

**Implementation approach:**
- Use `NSRunningApplication.runningApplications(withBundleIdentifier:)` to find Teams PID
- Read window titles via `AXUIElementCreateApplication(pid)` + `kAXWindowRole` + `kAXTitleAttribute`
- Match against existing patterns in `MeetingPatterns.swift`
- `ParticipantReader.swift` already demonstrates this exact pattern
- Would allow removing Screen Recording permission requirement

## Medium Priority

### Surface silent pipeline failures to the user

**Status:** Not started
**Priority:** Medium

Several pipeline failures are logged but not surfaced to the user:
- **Diarization failure** (`PipelineQueue.swift:483-486`): falls back to undiarized transcript silently. User gets result without speaker labels but no explanation.
- **Speaker naming timeout** (`PipelineQueue.swift:397-399`): auto-skips after 120s with no notification. Easy to miss during back-to-back meetings.
- **Empty audio capture**: only detected after transcription produces empty text.

**Implementation approach:**
- Send macOS notifications on diarization fallback and speaker naming timeout
- Show a warning badge on completed jobs that had degraded results
- Add a "warnings" field to `PipelineJob` to track what was skipped/degraded

### Protocol generation fallback

**Status:** Not started
**Priority:** Medium

If the configured protocol provider (Claude CLI or OpenAI API) fails, the entire job fails with no recovery. Both providers implement the same `ProtocolGenerating` protocol.

**Implementation approach:**
- Allow configuring a secondary/fallback provider in Settings
- Wrap `protocolGeneratorFactory()` call in `PipelineQueue.processNext()` with a try/catch that attempts the fallback provider
- Log which provider succeeded so the user knows

### Pipeline progress for long meetings

**Status:** Not started
**Priority:** Medium

Long meetings can take minutes to process with no segment-level feedback. `activeJobElapsed` tracks wall time but not completion percentage.

**Implementation approach:**
- Transcription: add a progress callback to `FluidTranscriptionEngine` reporting segment N of M
- Diarization: estimate progress based on audio duration vs elapsed time
- Protocol generation: stream partial output to show the protocol being written
- Surface progress in `MenuBarView` and job detail UI

### Detect back-to-back meeting transitions

**Status:** Not started
**Priority:** Medium

`waitForMeetingEnd` only checks whether *any* Teams meeting window exists, not whether the *same* meeting is still active. When one meeting ends and another starts immediately, the window title changes but the detector treats it as one continuous session — recording everything under the first meeting's name.

**Impact:** Back-to-back meetings are merged into a single recording and transcript with the wrong title.

**Implementation approach:**
- In `waitForMeetingEnd`, compare current window title against the original `meeting.windowTitle`
- If the title changes to a different meeting (not an idle pattern), treat it as: meeting A ended, meeting B started
- Stop recording for meeting A, enqueue it, then start a new recording for meeting B
- Need to handle brief title flickers (e.g., Teams UI transitions) — possibly require consecutive title-change detections before splitting
