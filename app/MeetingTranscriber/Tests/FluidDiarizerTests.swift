import XCTest

@testable import MeetingTranscriber

final class FluidDiarizerTests: XCTestCase {
    func testIsAlwaysAvailable() {
        let diarizer = FluidDiarizer()
        XCTAssertTrue(diarizer.isAvailable)
    }
}
