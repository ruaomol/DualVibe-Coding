enum DiagnosticLog {
    // Some upstream diagnostic strings include captured frame bytes. This app
    // keeps microphone data in memory and does not persist those diagnostics.
    static func write(_ message: @autoclosure () -> String) {}
}
