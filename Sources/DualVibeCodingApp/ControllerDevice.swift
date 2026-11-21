struct ControllerDevice: Identifiable, Hashable {
    enum Transport: Hashable {
        case bluetooth, usb, system

        var title: String {
            switch self {
            case .bluetooth: return "Bluetooth"
            case .usb: return "USB"
            case .system: return "系统连接"
            }
        }
    }

    enum BatteryState: Hashable {
        case unknown, discharging, charging, full
    }

    let id: String
    let name: String
    let transport: Transport
    var battery: Double?
    var batteryState: BatteryState = .unknown

    var batteryText: String { battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    static func activeID(in list: [Self], preferred: String?, current: String?) -> String? {
        for id in [preferred, current].compactMap({ $0 }) where list.contains(where: { $0.id == id }) {
            return id
        }
        return list.first?.id
    }
}
