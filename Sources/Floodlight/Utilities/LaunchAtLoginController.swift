import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginService: AnyObject {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginService {}

enum LaunchAtLoginError: LocalizedError {
    case requiresApproval
    case unavailable

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Allow Floodlight in System Settings → General → Login Items & Extensions."
        case .unavailable:
            "macOS did not enable Floodlight as a login item. Try again after moving Floodlight to Applications."
        }
    }
}

@MainActor
final class LaunchAtLoginController {
    static let configuredKey = "launch-at-login-configured"

    private let service: any LaunchAtLoginService
    private let defaults: UserDefaults
    private let logError: (String) -> Void

    init(
        service: any LaunchAtLoginService = SMAppService.mainApp,
        defaults: UserDefaults = .standard,
        logError: @escaping (String) -> Void = { message in
            NSLog("Floodlight could not enable launch at login: %@", message)
        }
    ) {
        self.service = service
        self.defaults = defaults
        self.logError = logError
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    /// Opts in on the first successful registration attempt.
    ///
    /// A failed attempt deliberately leaves the preference unset so a later
    /// launch can retry. A user-denied item is considered configured and is
    /// never re-enabled behind the user's back.
    func enableOnFirstRun() {
        guard !defaults.bool(forKey: Self.configuredKey) else { return }

        switch service.status {
        case .enabled, .requiresApproval:
            markConfigured()
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        do {
            try service.register()
            try requireEnabledStatus()
            markConfigured()
        } catch {
            logError(error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            switch service.status {
            case .enabled:
                break
            case .requiresApproval:
                throw LaunchAtLoginError.requiresApproval
            case .notRegistered, .notFound:
                try service.register()
                try requireEnabledStatus()
            @unknown default:
                throw LaunchAtLoginError.unavailable
            }
        } else {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }

        markConfigured()
    }

    private func requireEnabledStatus() throws {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw LaunchAtLoginError.requiresApproval
        case .notRegistered, .notFound:
            throw LaunchAtLoginError.unavailable
        @unknown default:
            throw LaunchAtLoginError.unavailable
        }
    }

    private func markConfigured() {
        defaults.set(true, forKey: Self.configuredKey)
    }
}
