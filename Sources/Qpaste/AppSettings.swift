import Foundation
import Combine
import Carbon

enum ShortcutChoice: Int, CaseIterable, Identifiable {
    case commandShiftV, commandOptionV, controlOptionV, doubleCommand
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .commandShiftV: return "⇧⌘V"
        case .commandOptionV: return "⌥⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .doubleCommand: return "双击 ⌘"
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .commandShiftV: return UInt32(cmdKey | shiftKey)
        case .commandOptionV: return UInt32(cmdKey | optionKey)
        case .controlOptionV: return UInt32(controlKey | optionKey)
        case .doubleCommand: return 0
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var maximumCount: Int { didSet { defaults.set(maximumCount, forKey: "maximumCount") } }
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var isPaused: Bool { didSet { defaults.set(isPaused, forKey: "isPaused") } }
    @Published var shortcut: ShortcutChoice { didSet { defaults.set(shortcut.rawValue, forKey: "shortcut") } }
    @Published var isCompact: Bool { didSet { defaults.set(isCompact, forKey: "compactMode") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["maximumCount": 300, "retentionDays": 30, "isPaused": false, "shortcut": 0, "compactMode": false])
        maximumCount = defaults.integer(forKey: "maximumCount")
        retentionDays = defaults.integer(forKey: "retentionDays")
        isPaused = defaults.bool(forKey: "isPaused")
        shortcut = ShortcutChoice(rawValue: defaults.integer(forKey: "shortcut")) ?? .commandShiftV
        isCompact = defaults.bool(forKey: "compactMode")
    }
}
