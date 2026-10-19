import AppKit
import ConverterCore
import XCTest
@testable import ConverterApp

@MainActor
final class WelcomeWindowTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ConverterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testShowsOnlyOnTheFirstLaunch() {
        let settings = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        let welcome = WelcomeWindowController(settings: settings, registry: .standard, defaults: defaults, showSettings: {})
        defer { welcome.close() }
        XCTAssertTrue(welcome.showIfFirstLaunch())
        XCTAssertFalse(welcome.showIfFirstLaunch())
        let later = WelcomeWindowController(settings: settings, registry: .standard, defaults: defaults, showSettings: {})
        XCTAssertFalse(later.showIfFirstLaunch(), "remembered across launches")
    }

    func testPracticeWheelHasAllThreeRings() throws {
        let model = RadialMenuModel(registry: .standard)
        model.load([try XCTUnwrap(PracticeWheel.samplePhoto())])
        XCTAssertEqual(model.phase, .ready)
        for mode in RingMode.allCases {
            model.setMode(mode)
            XCTAssertFalse(model.slices.isEmpty, "\(mode) ring is empty")
        }
        model.setMode(.formats)
        XCTAssertTrue(model.slices.contains { $0.title == "JPEG" })
    }
}
