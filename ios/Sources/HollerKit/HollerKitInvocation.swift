import Foundation

/// Destinations opened when a HollerKit invocation trigger fires.
public enum HollerKitInvocationAction: String, Sendable, Hashable, Equatable, CaseIterable {
    case bugReport = "bugReport"
    case quests = "quests"
}

/// Directions for drawn stroke gesture triggers.
public enum StrokeDirection: String, Sendable, Hashable, CaseIterable {
    case leftToCenter = "leftToCenter"
    case rightToCenter = "rightToCenter"

    public var wireValue: String { rawValue }
}

/// Identifies an individual trigger mechanism that can invoke HollerKit.
public struct HollerKitTrigger: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case shake
        case screenshot
        case stroke(StrokeDirection)
        case twoFingerLongPress
        case threeFingerLongPress
        case threeFingerDoubleTap
        case floatingButton
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public static let shake = HollerKitTrigger(.shake)
    public static let screenshot = HollerKitTrigger(.screenshot)
    public static func stroke(_ direction: StrokeDirection) -> HollerKitTrigger {
        HollerKitTrigger(.stroke(direction))
    }
    public static let twoFingerLongPress = HollerKitTrigger(.twoFingerLongPress)
    public static let threeFingerLongPress = HollerKitTrigger(.threeFingerLongPress)
    public static let threeFingerDoubleTap = HollerKitTrigger(.threeFingerDoubleTap)
    public static let floatingButton = HollerKitTrigger(.floatingButton)

    public var description: String {
        switch kind {
        case .shake:
            return "shake"
        case .screenshot:
            return "screenshot"
        case .stroke(let direction):
            return "stroke.\(direction.wireValue)"
        case .twoFingerLongPress:
            return "twoFingerLongPress"
        case .threeFingerLongPress:
            return "threeFingerLongPress"
        case .threeFingerDoubleTap:
            return "threeFingerDoubleTap"
        case .floatingButton:
            return "floatingButton"
        }
    }
}

/// Configures invocation triggers and their associated destination actions.
///
/// Backwards-compatible with the OptionSet `[.shake, .screenshot]` syntax while supporting
/// dictionary literal syntax `[.stroke(.leftToCenter): .bugReport, .stroke(.rightToCenter): .quests]`.
public struct HollerKitInvocation: OptionSet, Sendable, ExpressibleByDictionaryLiteral, Equatable {
    public var actions: [HollerKitTrigger: HollerKitInvocationAction]

    public var rawValue: Int {
        var bits = 0
        for trigger in actions.keys {
            bits |= Self.bit(for: trigger)
        }
        return bits
    }

    public init(rawValue: Int) {
        var map: [HollerKitTrigger: HollerKitInvocationAction] = [:]
        if rawValue & (1 << 0) != 0 {
            map[.shake] = .bugReport
        }
        if rawValue & (1 << 1) != 0 {
            map[.screenshot] = .bugReport
        }
        if rawValue & (1 << 2) != 0 {
            map[.stroke(.leftToCenter)] = .bugReport
        }
        if rawValue & (1 << 3) != 0 {
            map[.stroke(.rightToCenter)] = .quests
        }
        if rawValue & (1 << 4) != 0 {
            map[.twoFingerLongPress] = .bugReport
        }
        if rawValue & (1 << 5) != 0 {
            map[.threeFingerLongPress] = .bugReport
        }
        if rawValue & (1 << 6) != 0 {
            map[.threeFingerDoubleTap] = .bugReport
        }
        if rawValue & (1 << 7) != 0 {
            map[.floatingButton] = .bugReport
        }
        self.actions = map
    }

    public init(_ actions: [HollerKitTrigger: HollerKitInvocationAction]) {
        self.actions = actions
    }

    public init(dictionaryLiteral elements: (HollerKitTrigger, HollerKitInvocationAction)...) {
        var map: [HollerKitTrigger: HollerKitInvocationAction] = [:]
        for (trigger, action) in elements {
            map[trigger] = action
        }
        self.init(map)
    }

    private static func bit(for trigger: HollerKitTrigger) -> Int {
        switch trigger.kind {
        case .shake: return 1 << 0
        case .screenshot: return 1 << 1
        case .stroke(.leftToCenter): return 1 << 2
        case .stroke(.rightToCenter): return 1 << 3
        case .twoFingerLongPress: return 1 << 4
        case .threeFingerLongPress: return 1 << 5
        case .threeFingerDoubleTap: return 1 << 6
        case .floatingButton: return 1 << 7
        }
    }

    // Static OptionSet members for backwards compatibility
    public static let shake = HollerKitInvocation(rawValue: 1 << 0)
    public static let screenshot = HollerKitInvocation(rawValue: 1 << 1)

    // Convenient factories for stroke and additional triggers
    public static func stroke(
        _ direction: StrokeDirection,
        action: HollerKitInvocationAction = .bugReport
    ) -> HollerKitInvocation {
        HollerKitInvocation([.stroke(direction): action])
    }

    public static func twoFingerLongPress(
        action: HollerKitInvocationAction = .bugReport
    ) -> HollerKitInvocation {
        HollerKitInvocation([.twoFingerLongPress: action])
    }

    public static func threeFingerLongPress(
        action: HollerKitInvocationAction = .bugReport
    ) -> HollerKitInvocation {
        HollerKitInvocation([.threeFingerLongPress: action])
    }

    public static func threeFingerDoubleTap(
        action: HollerKitInvocationAction = .bugReport
    ) -> HollerKitInvocation {
        HollerKitInvocation([.threeFingerDoubleTap: action])
    }

    public static func floatingButton(
        action: HollerKitInvocationAction = .bugReport
    ) -> HollerKitInvocation {
        HollerKitInvocation([.floatingButton: action])
    }

    // SetAlgebra conformance
    public mutating func formUnion(_ other: HollerKitInvocation) {
        for (trigger, action) in other.actions {
            self.actions[trigger] = action
        }
    }

    public mutating func formIntersection(_ other: HollerKitInvocation) {
        for key in Array(self.actions.keys) {
            if other.actions[key] == nil {
                self.actions.removeValue(forKey: key)
            }
        }
    }

    public mutating func formSymmetricDifference(_ other: HollerKitInvocation) {
        for (trigger, action) in other.actions {
            if self.actions[trigger] != nil {
                self.actions.removeValue(forKey: trigger)
            } else {
                self.actions[trigger] = action
            }
        }
    }

    public func action(for trigger: HollerKitTrigger) -> HollerKitInvocationAction? {
        actions[trigger]
    }

    public func contains(_ trigger: HollerKitTrigger) -> Bool {
        actions[trigger] != nil
    }

    public subscript(trigger: HollerKitTrigger) -> HollerKitInvocationAction? {
        get { actions[trigger] }
        set {
            if let newValue {
                actions[trigger] = newValue
            } else {
                actions.removeValue(forKey: trigger)
            }
        }
    }
}
