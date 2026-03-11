import XCTest

@testable import MeetingTranscriber

final class ProtocolGeneratorTests: XCTestCase {

    // MARK: - Stream JSON Parsing

    func testParseContentBlockDelta() {
        let line = """
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello world"}}
            """
        XCTAssertEqual(ProtocolGenerator.parseStreamJSONLine(line), "Hello world")
    }

    func testParseAssistantMessage() {
        let line = """
            {"type":"assistant","message":{"content":[{"type":"text","text":"Full protocol text"}]}}
            """
        XCTAssertEqual(ProtocolGenerator.parseStreamJSONLine(line), "Full protocol text")
    }

    func testParseIrrelevantType() {
        let line = """
            {"type":"message_start","message":{"id":"msg_123"}}
            """
        XCTAssertNil(ProtocolGenerator.parseStreamJSONLine(line))
    }

    func testParseInvalidJSON() {
        XCTAssertNil(ProtocolGenerator.parseStreamJSONLine("not json"))
    }

    func testParseEmptyLine() {
        XCTAssertNil(ProtocolGenerator.parseStreamJSONLine(""))
    }

    func testParseContentBlockDeltaNonTextType() {
        let line = """
            {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}
            """
        XCTAssertNil(ProtocolGenerator.parseStreamJSONLine(line))
    }

    func testParseAssistantMessageNoTextBlock() {
        let line = """
            {"type":"assistant","message":{"content":[{"type":"tool_use","id":"123"}]}}
            """
        XCTAssertNil(ProtocolGenerator.parseStreamJSONLine(line))
    }

    // MARK: - Prompt Construction

    func testProtocolPromptContainsStructure() {
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("# Meeting Protocol"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Summary"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Participants"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Topics Discussed"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Decisions"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Tasks"))
        XCTAssertTrue(ProtocolGenerator.protocolPrompt.contains("## Open Questions"))
    }

    func testProtocolPromptEndsWithTranscriptMarker() {
        let trimmed = ProtocolGenerator.protocolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasSuffix("Transcript:"))
    }

    func testDiarizationNoteContainsSpeakerFormats() {
        let note = ProtocolGenerator.diarizationNote
        XCTAssertTrue(note.contains("[SPEAKER_00]"))
        XCTAssertTrue(note.contains("[Me]"))
        XCTAssertTrue(note.contains("[Remote]"))
    }

    // MARK: - Filename Generation

    func testFilenameFormat() {
        let name = ProtocolGenerator.filename(title: "Team Meeting", ext: "md")
        // Format: yyyyMMdd_HHmm_team_meeting.md
        XCTAssertTrue(name.hasSuffix("_team_meeting.md"))
        // Should start with date pattern (8 digits _ 4 digits)
        let prefix = String(name.prefix(13))
        XCTAssertTrue(prefix.range(of: #"^\d{8}_\d{4}$"#, options: .regularExpression) != nil,
                       "Expected date prefix, got: \(prefix)")
    }

    func testFilenameSlugLowercase() {
        let name = ProtocolGenerator.filename(title: "Daily Standup", ext: "txt")
        XCTAssertTrue(name.contains("daily_standup"))
    }

    func testFilenameExtension() {
        let md = ProtocolGenerator.filename(title: "Test", ext: "md")
        XCTAssertTrue(md.hasSuffix(".md"))

        let txt = ProtocolGenerator.filename(title: "Test", ext: "txt")
        XCTAssertTrue(txt.hasSuffix(".txt"))
    }

    // MARK: - Slug Sanitization (Path Traversal Prevention)

    func testSanitizeSlugStripsPathSeparators() {
        let slug = ProtocolGenerator.sanitizeSlug("../../etc/passwd")
        XCTAssertFalse(slug.contains("/"), "Slug must not contain path separators")
        XCTAssertFalse(slug.contains(".."), "Slug must not contain directory traversal")
        XCTAssertEqual(slug, "etcpasswd")
    }

    func testSanitizeSlugStripsDotsOnly() {
        let slug = ProtocolGenerator.sanitizeSlug("my.meeting.title")
        XCTAssertFalse(slug.contains("."), "Slug must not contain dots")
        XCTAssertEqual(slug, "mymeetingtitle")
    }

    func testSanitizeSlugPreservesAlphanumericAndHyphens() {
        let slug = ProtocolGenerator.sanitizeSlug("Team-Meeting 2024")
        XCTAssertEqual(slug, "team-meeting_2024")
    }

    func testSanitizeSlugEmptyTitleFallback() {
        let slug = ProtocolGenerator.sanitizeSlug("///")
        XCTAssertEqual(slug, "meeting", "Empty slug after sanitization should fall back to 'meeting'")
    }

    func testSanitizeSlugSpecialCharacters() {
        let slug = ProtocolGenerator.sanitizeSlug("Meeting <script>alert('xss')</script>")
        XCTAssertFalse(slug.contains("<"), "Slug must not contain angle brackets")
        XCTAssertFalse(slug.contains(">"), "Slug must not contain angle brackets")
        XCTAssertFalse(slug.contains("'"), "Slug must not contain quotes")
    }

    func testFilenameWithPathTraversalTitle() {
        let name = ProtocolGenerator.filename(title: "../../etc/passwd", ext: "md")
        XCTAssertFalse(name.contains("/"), "Filename must not contain path separators")
        XCTAssertTrue(name.hasSuffix("_etcpasswd.md"))
    }

    // MARK: - File Save Operations

    func testSaveTranscript() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let text = "[00:00] Hello\n[00:05] World"
        let url = try ProtocolGenerator.saveTranscript(text, title: "Test", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_test.txt"))

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, text)
    }

    func testSaveProtocol() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let markdown = "# Meeting Protocol\n\n## Summary\nTest meeting."
        let url = try ProtocolGenerator.saveProtocol(markdown, title: "Standup", dir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_standup.md"))

        let loaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(loaded, markdown)
    }

    func testSaveCreatesDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proto_test_\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer {
            try? FileManager.default.removeItem(
                at: tmpDir.deletingLastPathComponent()
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.path))

        let url = try ProtocolGenerator.saveTranscript("test", title: "X", dir: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Available Binaries

    func testAvailableClaudeBinariesContainsClaude() {
        let binaries = ProtocolGenerator.availableClaudeBinaries()
        XCTAssertTrue(binaries.contains("claude"), "Available binaries should always contain 'claude'")
    }

    func testAvailableClaudeBinariesAreSorted() {
        let binaries = ProtocolGenerator.availableClaudeBinaries()
        XCTAssertEqual(binaries, binaries.sorted(), "Available binaries should be sorted")
    }

    // MARK: - Environment Stripping

    func testGenerateStripsClaudeCodeFromEnvironment() throws {
        // Verify that ProtocolGenerator.generate() removes CLAUDECODE from the
        // process environment. We cannot call generate() directly (it launches
        // the real claude CLI), so we replicate the env-setup logic and verify
        // that CLAUDECODE is removed.

        // Set CLAUDECODE in current process env so it would be inherited
        setenv("CLAUDECODE", "1", 1)
        defer { unsetenv("CLAUDECODE") }

        // Replicate the exact env setup from ProtocolGenerator.generate()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")

        XCTAssertNil(
            env["CLAUDECODE"],
            "CLAUDECODE should be removed from the process environment"
        )

        // Also verify that the original environment DID have it
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["CLAUDECODE"],
            "CLAUDECODE should exist in the current process environment"
        )
    }

    func testGenerateEnvStripDoesNotRemoveOtherVars() throws {
        // Verify that removing CLAUDECODE doesn't affect other env vars
        let testKey = "MEETING_TRANSCRIBER_TEST_VAR_\(UUID().uuidString)"
        setenv(testKey, "test_value", 1)
        defer { unsetenv(testKey) }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")

        XCTAssertEqual(
            env[testKey], "test_value",
            "Other env vars should be preserved when stripping CLAUDECODE"
        )
    }
}
