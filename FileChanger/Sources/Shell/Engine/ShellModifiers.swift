import AppKit

/// Modifier combination of a wheel (SHL-10): bit0 Command, bit1 Option, bit2 Control, bit3 Shift.
struct ShellModifierMask: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let command = ShellModifierMask(rawValue: 1)
    static let option = ShellModifierMask(rawValue: 2)
    static let control = ShellModifierMask(rawValue: 4)
    static let shift = ShellModifierMask(rawValue: 8)

    var isValid: Bool { (1...15).contains(rawValue) }

    init(rawValue: Int) { self.rawValue = rawValue }

    init(flags: NSEvent.ModifierFlags) {
        var m = ShellModifierMask()
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        self = m
    }

    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.command) { f.insert(.command) }
        if contains(.option) { f.insert(.option) }
        if contains(.control) { f.insert(.control) }
        if contains(.shift) { f.insert(.shift) }
        return f
    }

    /// Glyphs in the order Control, Option, Shift, Command (SHL-11); empty shows "Unset".
    var glyphs: [String] {
        var g: [String] = []
        if contains(.control) { g.append("⌃") }
        if contains(.option) { g.append("⌥") }
        if contains(.shift) { g.append("⇧") }
        if contains(.command) { g.append("⌘") }
        return g
    }

    var display: String { isEmpty ? "Unset" : glyphs.joined() }
}

/// The three wheels (SHL-09, SHL-14).
enum ShellWheel: String, CaseIterable, Identifiable, Sendable {
    case conversion, tools, actions
    var id: String { rawValue }

    var defaultsKey: String { rawValue + "WheelDragModifierMask" }
    var defaultMask: ShellModifierMask {
        switch self {
        case .conversion: return .shift
        case .tools: return .command
        case .actions: return .control
        }
    }
    var settingsLabel: String {
        switch self {
        case .conversion: return "Conversion wheel"
        case .tools: return "Tools wheel"
        case .actions: return "Actions wheel"
        }
    }
    var title: String {
        switch self {
        case .conversion: return "File Converter"
        case .tools: return "File Tools"
        case .actions: return "File Actions"
        }
    }
    var prompt: String { self == .conversion ? "Drop it on a format" : "Drop it on an option" }
}

/// Reads, validates and migrates the three wheel masks in UserDefaults.
enum ShellModifierStore {
    static let migrationKey = "didMigrateToolsWheelToCommand"

    /// Old Tools default was Shift+Option (10); a one-time migration rewrites it to Command (1), SHL-09.
    static func migrate(_ d: UserDefaults = .standard) {
        guard !d.bool(forKey: migrationKey) else { return }
        d.set(ShellWheel.tools.defaultMask.rawValue, forKey: ShellWheel.tools.defaultsKey)
        d.set(true, forKey: migrationKey)
    }

    /// Validated masks: out of range or colliding with an earlier wheel falls back to that wheel's default.
    static func masks(_ d: UserDefaults = .standard) -> [ShellWheel: ShellModifierMask] {
        var out: [ShellWheel: ShellModifierMask] = [:]
        for wheel in ShellWheel.allCases {
            let stored = d.object(forKey: wheel.defaultsKey) as? Int
            var mask = stored.map(ShellModifierMask.init(rawValue:)) ?? wheel.defaultMask
            if !mask.isValid || out.values.contains(mask) { mask = wheel.defaultMask }
            out[wheel] = mask
        }
        return out
    }

    static func mask(for wheel: ShellWheel, _ d: UserDefaults = .standard) -> ShellModifierMask {
        masks(d)[wheel] ?? wheel.defaultMask
    }

    /// Which other wheel already uses `mask`, if any.
    static func conflict(for mask: ShellModifierMask, assigning wheel: ShellWheel, _ d: UserDefaults = .standard) -> ShellWheel? {
        masks(d).first { $0.key != wheel && $0.value == mask }?.key
    }

    /// Stores `mask` for `wheel`; false when invalid or used by another wheel.
    @discardableResult
    static func set(_ mask: ShellModifierMask, for wheel: ShellWheel, _ d: UserDefaults = .standard) -> Bool {
        guard mask.isValid, conflict(for: mask, assigning: wheel, d) == nil else { return false }
        d.set(mask.rawValue, forKey: wheel.defaultsKey)
        return true
    }
}

/// Detects a modifier TAP: the combination is pressed and released with no other key in between,
/// quickly enough to be a tap (SHL-08). The peak combination reached while held is what counts, so
/// Shift+Command (pressed one after the other) taps Shift+Command, not Shift.
struct ShellTapDetector {
    var maxDuration: TimeInterval = 0.75
    private var peak: ShellModifierMask = []
    private var pressedAt: TimeInterval = 0
    private var dirty = false

    /// Feed every flagsChanged event. Returns the tapped combination on release, else nil.
    mutating func flagsChanged(_ current: ShellModifierMask, at time: TimeInterval) -> ShellModifierMask? {
        if current.isEmpty {
            defer { reset() }
            guard !peak.isEmpty, !dirty, time - pressedAt <= maxDuration else { return nil }
            return peak
        }
        if peak.isEmpty { pressedAt = time }
        // Letting go of one key of a combination before the rest is fine; adding keys grows the peak.
        if current.isSuperset(of: peak) { peak = current }
        return nil
    }

    /// Any non-modifier key (or click) while modifiers are down cancels the tap.
    mutating func otherInput() { if !peak.isEmpty { dirty = true } }

    mutating func reset() { peak = []; dirty = false }
}
