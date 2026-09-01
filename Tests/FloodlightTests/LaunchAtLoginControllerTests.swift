import ServiceManagement
import XCTest
@testable import Floodlight

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testFailedFirstRegistrationIsRetriedOnNextLaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.registrationFailed
        var loggedErrors: [String] = []
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            logError: { loggedErrors.append($0) }
        )

        controller.enableOnFirstRun()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
        XCTAssertEqual(loggedErrors.count, 1)

        service.registerError = nil
        controller.enableOnFirstRun()

        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
        XCTAssertTrue(controller.isEnabled)
    }

    func testAlreadyEnabledServiceCompletesFirstRunWithoutReregistering() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.enableOnFirstRun()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    func testExplicitOptOutPreventsAutomaticReregistration() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        try controller.setEnabled(false)
        controller.enableOnFirstRun()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    func testDeniedServiceReturnsActionableError() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Allow Floodlight in System Settings → General → Login Items & Extensions."
            )
        }
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginController.configuredKey))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FloodlightLaunchAtLoginTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}

private enum TestError: Error {
    case registrationFailed
}
