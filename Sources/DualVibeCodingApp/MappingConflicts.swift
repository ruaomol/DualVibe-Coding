struct MappingConflicts {
    private struct Slot: Hashable {
        let mappingID: String
        let gesture: GestureKind
    }

    private struct Chord {
        let slot: Slot
        let control: String
        let modifier: String
        let name: String
    }

    private enum Issue {
        case invalid(reason: String)
        case reciprocal(mappingIDs: [String], reason: String)

        var reason: String {
            switch self {
            case let .invalid(reason), let .reciprocal(_, reason): return reason
            }
        }
    }

    private static let oppositeDirections = [
        "dpadUp": "dpadDown", "dpadDown": "dpadUp",
        "dpadLeft": "dpadRight", "dpadRight": "dpadLeft"
    ]
    private static let unpressedTouchInputs: Set<String> = [
        "touchMove", "touchScroll", "touchTap", "touchSecondaryTap"
    ]

    private let issues: [Slot: Issue]
    private let conflictedIDs: Set<String>

    init(_ mappings: [ButtonMapping]) {
        let modifierIDs = Set(mappings.map(\.id)).intersection(ButtonMapping.physicalButtonIDs)
        var issues: [Slot: Issue] = [:]
        var chords: [Chord] = []

        for row in mappings {
            let control = ButtonMapping.touchPressIDs.contains(row.id) ? "touchpad" : row.id
            for gesture in row.editableGestures {
                let binding = row[gesture]
                guard binding.isConfigured, let modifier = binding.modifierID else { continue }
                let slot = Slot(mappingID: row.id, gesture: gesture)
                if !modifierIDs.contains(modifier) {
                    issues[slot] = .invalid(reason: "用于组合的按键不可用")
                } else if control == modifier {
                    issues[slot] = .invalid(reason: "组合键重复使用了同一个实体键")
                } else if Self.oppositeDirections[control] == modifier {
                    issues[slot] = .invalid(reason: "方向键的相反方向无法同时按下")
                } else if modifier == "touchpad", Self.unpressedTouchInputs.contains(row.id) {
                    issues[slot] = .invalid(reason: "此手势需要松开触控板实体键")
                } else if ButtonMapping.physicalButtonIDs.contains(control) {
                    chords.append(Chord(slot: slot, control: control, modifier: modifier, name: row.name))
                }
            }
        }

        let byControl = Dictionary(grouping: chords, by: \.control)
        for chord in chords {
            let opposite = byControl[chord.modifier, default: []]
                .filter { $0.modifier == chord.control && $0.slot.gesture == chord.slot.gesture }
            let counterpartNames = Array(Set(opposite.map(\.name))).sorted()
            if !counterpartNames.isEmpty {
                issues[chord.slot] = .reciprocal(
                    mappingIDs: opposite.map(\.slot.mappingID),
                    reason: "同时按下时与\(counterpartNames.joined(separator: "、"))的组合重叠"
                )
            }
        }

        self.issues = issues
        conflictedIDs = Set(issues.keys.map(\.mappingID))
    }

    func reason(for mappingID: String, gesture: GestureKind) -> String? {
        issues[Slot(mappingID: mappingID, gesture: gesture)]?.reason
    }

    func hasConflict(for mappingID: String) -> Bool {
        conflictedIDs.contains(mappingID)
    }

    func isInvalid(for mappingID: String, gesture: GestureKind) -> Bool {
        if case .invalid? = issues[Slot(mappingID: mappingID, gesture: gesture)] { return true }
        return false
    }

    func reciprocalMappings(for mappingID: String, gesture: GestureKind) -> [String] {
        if case let .reciprocal(mappingIDs, _)? = issues[Slot(mappingID: mappingID, gesture: gesture)] {
            return mappingIDs
        }
        return []
    }
}
