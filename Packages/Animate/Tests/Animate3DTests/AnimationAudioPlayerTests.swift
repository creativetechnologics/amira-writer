import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class AnimationAudioPlayerTests: XCTestCase {

    @MainActor
    func testInitialState() {
        let player = AnimationAudioPlayer(fps: 24)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoaded)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertNil(player.loadError)
    }

    @MainActor
    func testFrameCalculation() {
        let player = AnimationAudioPlayer(fps: 30)
        // At 30fps, frame 0 = 0.0s, frame 30 = 1.0s, frame 60 = 2.0s
        XCTAssertEqual(player.currentFrame, 0)
    }

    @MainActor
    func testLoadNonexistentFile() {
        let player = AnimationAudioPlayer(fps: 24)
        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent-audio-file-\(UUID()).wav")
        player.load(url: fakeURL)
        XCTAssertFalse(player.isLoaded)
        XCTAssertNotNil(player.loadError)
    }

    @MainActor
    func testUnloadResetsState() {
        let player = AnimationAudioPlayer(fps: 24)
        player.unload()
        XCTAssertFalse(player.isLoaded)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.duration, 0)
    }

    @MainActor
    func testTimeFormatting() {
        let player = AnimationAudioPlayer(fps: 24)
        // Duration is 0, so formatted should be "0:00"
        XCTAssertEqual(player.formattedDuration, "0:00")
        XCTAssertEqual(player.formattedCurrentTime, "0:00")
    }

    @MainActor
    func testTotalFramesCalculation() {
        let player = AnimationAudioPlayer(fps: 24)
        // With no audio loaded, totalFrames should be 0
        XCTAssertEqual(player.totalFrames, 0)
    }
}
