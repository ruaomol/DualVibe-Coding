import Foundation

enum BundledMicrophoneDriverError: LocalizedError {
    case bundledFilesMissing
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledFilesMissing:
            return "The app does not contain its DualSense Bridge Mic driver tools."
        case let .authorizationFailed(message):
            return message
        }
    }
}

final class BundledMicrophoneDriverManager {
    private static let driverName = "DualSenseBridgeMic.driver"

    var canInstall: Bool {
        bundledDriverURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
            && Bundle.main.url(forResource: "install-driver", withExtension: "sh") != nil
    }

    func install() throws {
        guard let driverURL = bundledDriverURL,
              let installerURL = Bundle.main.url(
                forResource: "install-driver",
                withExtension: "sh"
              ) else {
            throw BundledMicrophoneDriverError.bundledFilesMissing
        }

        let script = """
        set installerPath to "\(appleScriptLiteral(installerURL.path))"
        set driverPath to "\(appleScriptLiteral(driverURL.path))"
        set commandText to quoted form of installerPath & " " & quoted form of driverPath
        do shell script commandText with administrator privileges
        """
        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            let message = error?[NSAppleScript.errorMessage] as? String
                ?? "macOS did not install the audio driver."
            throw BundledMicrophoneDriverError.authorizationFailed(message)
        }
    }

    private var bundledDriverURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent(
            Self.driverName,
            isDirectory: true
        )
    }

    private func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
