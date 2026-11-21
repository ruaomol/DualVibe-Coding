import CoreGraphics
import IOKit.hidsystem

@MainActor
extension ControllerStore {
    func requestOutputAuthorization() {
        if !CGPreflightPostEventAccess(), !CGRequestPostEventAccess() {
            openAccessibilitySettings()
        }
        refreshPermissions()
    }

    func requestInputAuthorization() {
        let service = kIOHIDRequestTypeListenEvent
        if IOHIDCheckAccess(service) != kIOHIDAccessTypeGranted, !IOHIDRequestAccess(service) {
            openInputMonitoringSettings()
        }
        refreshPermissions()
    }
}
