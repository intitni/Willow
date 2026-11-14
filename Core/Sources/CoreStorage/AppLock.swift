import Foundation
import LocalAuthentication
import Observation

@MainActor
@Observable
package final class AppLock {
    private static let preferenceKey = "willow.biometricLockEnabled"

    package private(set) var isEnabled: Bool
    package private(set) var isLocked: Bool
    package private(set) var errorMessage: String?
    package private(set) var isAuthenticating = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var authenticationContext: LAContext?

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    package var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return L10n.text("Biometrics.FaceID")
        case .touchID: return L10n.text("Biometrics.TouchID")
        case .opticID: return L10n.text("Biometrics.OpticID")
        default: return L10n.text("Biometrics.GenericName")
        }
    }

    package func lock() {
        authenticationContext?.invalidate()
        authenticationContext = nil
        if isEnabled {
            isLocked = true
            errorMessage = nil
        }
    }

    package func unlock() async {
        guard isLocked else { return }
        await authenticate(
            policy: .deviceOwnerAuthentication,
            reason: L10n.text("AppLock.UnlockReason")
        ) {
            isLocked = false
        }
    }

    package func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isLocked else { return }
        let policy: LAPolicy = enabled ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        let reason = enabled
            ? L10n.text("AppLock.EnableReason")
            : L10n.text("AppLock.DisableReason")
        await authenticate(policy: policy, reason: reason) {
            defaults.set(enabled, forKey: Self.preferenceKey)
            isEnabled = enabled
        }
    }

    private func authenticate(policy: LAPolicy, reason: String, onSuccess: () -> Void) async {
        guard !isAuthenticating else { return }
        let context = LAContext()
        authenticationContext = context
        errorMessage = nil
        isAuthenticating = true
        defer {
            authenticationContext = nil
            isAuthenticating = false
        }

        do {
            let authenticated = try await context.evaluatePolicy(policy, localizedReason: reason)
            if authenticated && authenticationContext === context && !Task.isCancelled {
                onSuccess()
            }
        } catch let error as LAError where [.appCancel, .systemCancel, .userCancel].contains(error.code) {
            return
        } catch {
            if authenticationContext === context && !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}
