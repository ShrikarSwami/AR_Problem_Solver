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

/// User-facing failures across the glasses pipeline. Each maps a specific DAT
/// SDK error state to a message and, where relevant, a recovery action the UI
/// can offer.
enum GlassesError: LocalizedError, Equatable {
    /// Registration is not `.registered` — the app isn't authorized for the glasses yet.
    case notAuthorized
    /// No display/camera-capable device is currently connected.
    case notConnected
    /// The Meta AI companion app isn't installed.
    case metaAINotInstalled
    /// The DAT app *on the glasses* is too old for this SDK — needs an update in Meta AI.
    case glassesAppUpdateRequired
    /// Glasses firmware is too old.
    case firmwareUpdateRequired
    /// Camera permission hasn't been granted; the next attempt will open Meta AI to request it.
    case cameraPermissionNeeded
    /// Camera permission was explicitly denied.
    case cameraPermissionDenied
    /// A permission request is already in flight (usually a stuck Meta AI round-trip).
    case permissionRequestInProgress
    case sessionFailed(String)
    case captureFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "The glasses aren't connected to this app yet. Open Settings and tap Connect glasses."
        case .notConnected:
            return "No Meta glasses are connected. Put them on and make sure they're paired in the Meta AI app."
        case .metaAINotInstalled:
            return "The Meta AI app isn't installed. Install it and pair your glasses first."
        case .glassesAppUpdateRequired:
            return "Your glasses need a software update before this app can use them. Open the Meta AI app to update."
        case .firmwareUpdateRequired:
            return "Your glasses need a firmware update. Open the Meta AI app to install it."
        case .cameraPermissionNeeded:
            return "Camera access for the glasses needs to be granted in the Meta AI app. Tap Capture again to open it."
        case .cameraPermissionDenied:
            return "Camera access was denied. Enable it for this app in the Meta AI app, then try again."
        case .permissionRequestInProgress:
            return "A permission request is still open in the Meta AI app. Finish it there, then try again."
        case .sessionFailed(let detail):
            return "Couldn't start a glasses session: \(detail)"
        case .captureFailed(let detail):
            return "Photo capture failed: \(detail)"
        case .timedOut(let phase):
            return "Timed out waiting for \(phase)."
        }
    }

    /// A recovery the UI can trigger via `WearablesService`.
    var recovery: Recovery? {
        switch self {
        case .notAuthorized: return .connect
        case .glassesAppUpdateRequired: return .openGlassesAppUpdate
        case .firmwareUpdateRequired: return .openFirmwareUpdate
        default: return nil
        }
    }

    enum Recovery: Equatable {
        case connect
        case openGlassesAppUpdate
        case openFirmwareUpdate
    }
}
