import Foundation
import MWDATDisplay

/// Seams that isolate `SolverCoordinator` / `TeleprompterController` from the
/// live DAT SDK so they can be unit-tested with fakes (and the camera path can
/// run against MockDeviceKit).

@MainActor
protocol PhotoCapturing: AnyObject {
    /// Runs the full glasses-camera capture lifecycle and returns JPEG bytes.
    func capturePhoto() async throws -> Data
}

@MainActor
protocol DisplaySending: AnyObject {
    /// Whether a display session is currently connected.
    var isConnected: Bool { get }
    /// Sends one root layout to the glasses display, replacing whatever is shown.
    /// Auto-attaches if not yet connected.
    func send(_ page: FlexBox) async throws
    /// Tears down the display session.
    func end()
}

enum GlassesError: LocalizedError {
    case noDevice
    case cameraPermissionNeeded
    case cameraPermissionDenied
    case sessionFailed(String)
    case captureFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Meta glasses available. Put them on and pair in the Meta AI app."
        case .cameraPermissionNeeded:
            return "Camera access for the glasses needs to be granted in the Meta AI app. Tap Capture again to open it."
        case .cameraPermissionDenied:
            return "Camera access was denied. Enable it for this app in the Meta AI app, then try again."
        case .sessionFailed(let detail):
            return "Couldn't start a glasses session: \(detail)"
        case .captureFailed(let detail):
            return "Photo capture failed: \(detail)"
        case .timedOut(let phase):
            return "Timed out waiting for \(phase)."
        }
    }
}
