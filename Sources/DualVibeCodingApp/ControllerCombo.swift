import Foundation

struct ControllerCombo: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var modifierID: String
    var triggerID: String
    var gesture: GestureKind
    var binding: MappingBinding

    var modifierControl: String { Self.control(for: modifierID) }
    var triggerControl: String { Self.control(for: triggerID) }

    static func control(for id: String) -> String {
        ButtonMapping.touchPressIDs.contains(id) ? "touchpad" : id
    }

    static func mayPair(_ modifier: String, _ trigger: String) -> Bool {
        let control = control(for: trigger)
        guard ButtonMapping.physicalButtonIDs.contains(modifier),
              ButtonMapping.physicalButtonIDs.contains(control),
              modifier != control else { return false }
        let opposites: [String: String] = [
            "dpadUp": "dpadDown", "dpadDown": "dpadUp",
            "dpadLeft": "dpadRight", "dpadRight": "dpadLeft"
        ]
        return opposites[modifier] != control
    }

    var actionIsValid: Bool {
        binding.isConfigured && MappingAction.comboOutputActions.contains(binding.action)
    }
}

struct ControllerButtonFrame: Equatable {
    let newlyPressed: [String]
    let held: Set<String>
    let navigationInputs: [String]
    private let occurrence = UUID()
}
