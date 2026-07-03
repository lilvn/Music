import XCTest

/// Drives the tvOS app with the virtual Siri Remote and captures screenshots into the result bundle.
/// All waits pump the run loop (XCTWaiter) — a bare `sleep()` blocks the runner's main thread and
/// FrontBoard watchdog-kills it (0x8BADF00D).
final class MusicTVUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [expectation(description: "hold")], timeout: seconds)
    }

    @MainActor
    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testOpenNowPlayingAndHold() throws {
        let app = XCUIApplication()
        app.launch()
        hold(14)   // login, shelves, session restore
        snap("1-home")

        let remote = XCUIRemote.shared
        remote.press(.up); hold(1)      // focus up to the tab bar
        remote.press(.up); hold(1)
        for _ in 0..<3 {                // Home → Albums → Playlists → Now Playing
            remote.press(.right); hold(1)
        }
        hold(6)                         // NP appears; video mode engages if a video matches
        snap("2-nowplaying")
        hold(10)                        // video buffering / carousel settle
        snap("3-nowplaying-later")
    }
}
