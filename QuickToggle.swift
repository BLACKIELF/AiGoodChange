import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

// MARK: - Persisted model

private struct TargetApplication: Codable, Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String
}

private struct AppBinding: Codable, Equatable {
    let id: UUID
    var target: TargetApplication
    var shortcut: Shortcut?
    var launchIfNeeded: Bool
}

private func shortcutIsUsed(_ shortcut: Shortcut, in bindings: [AppBinding], excluding id: UUID) -> Bool {
    bindings.contains { $0.id != id && $0.shortcut == shortcut }
}

private let fnModifierMask = UInt32(NSEvent.ModifierFlags.function.rawValue)

private enum SystemKeyboardOverlap {
    enum GlobePressAction: Equatable {
        case none
        case switchInputSource
        case emojiAndSymbols
        case dictation
        case unknown(Int)

        var conflictDescription: String? {
            switch self {
            case .none: return nil
            case .switchInputSource: return "切换输入法"
            case .emojiAndSymbols: return "显示表情与符号"
            case .dictation: return "开始听写"
            case .unknown(let value): return "未知动作（值 \(value)）"
            }
        }
    }

    static func globePressAction(from value: Any?) -> GlobePressAction {
        guard let number = value as? NSNumber else { return .none }
        switch number.intValue {
        case 0: return .none
        case 1: return .switchInputSource
        case 2: return .emojiAndSymbols
        case 3: return .dictation
        default: return .unknown(number.intValue)
        }
    }

    static var globePressAction: GlobePressAction {
        globePressAction(
            from: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType")
        )
    }

    static func standardFunctionKeyModeDescription(from value: Any?) -> String {
        guard let number = value as? NSNumber else {
            return "未显式设置（通常由顶部功能图标优先）"
        }
        return number.boolValue
            ? "已开启“将 F1、F2 等键用作标准功能键”"
            : "已关闭“将 F1、F2 等键用作标准功能键”"
    }

    static var standardFunctionKeyModeDescription: String {
        standardFunctionKeyModeDescription(
            from: UserDefaults.standard.object(forKey: "com.apple.keyboard.fnState")
        )
    }

    static func warning(for shortcut: Shortcut) -> String? {
        guard shortcut.isFunctionDigit else { return nil }
        let base = "fn/🌐 + 数字通过事件 tap 监听；macOS 无法检测所有系统、应用或键盘固件冲突。"
        guard let action = globePressAction.conflictDescription else { return base }
        return "系统已把单按 fn/🌐 配置为“\(action)”，组合键可能不可达或同时触发系统行为。\(base)"
    }
}

private struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    var displayName: String {
        var result = ""
        if modifiers & fnModifierMask != 0 { result += "fn" }
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + label
    }

    var validationError: String? {
        let count = modifierCount
        if count <= 1 { return settingsValidationError }
        return validationError(minimumModifierCount: 2)
    }

    var settingsValidationError: String? {
        if usesFunctionModifier { return validationError(minimumModifierCount: 1) }
        let count = modifierCount
        if count == 1,
           !(modifiers == UInt32(cmdKey) && Self.numberKeyCodes.contains(keyCode)),
           !isFunctionDigit {
            return "单修饰键仅支持 Command + 数字或 fn/🌐 + 数字；其他组合请至少使用两个修饰键。"
        }
        return validationError(minimumModifierCount: 1)
    }

    private func validationError(minimumModifierCount: Int) -> String? {
        let count = modifierCount
        guard count >= minimumModifierCount else {
            return minimumModifierCount == 1
                ? "快捷键至少需要一个修饰键。"
                : "快捷键至少需要两个修饰键。"
        }
        guard Self.supportedKeyCodes.contains(keyCode) else {
            return "请选择字母、数字、方向键或 F1–F12。"
        }
        if usesFunctionModifier {
            guard modifiers == fnModifierMask else {
                return "fn/🌐 目前仅支持单独搭配数字，不与其他修饰键叠加。"
            }
            if isReserved { return "该 fn/🌐 组合由 macOS 保留，请选择 fn/🌐 + 数字。" }
            if isFunctionDigit { return nil }
            if Self.functionKeyCodes.contains(keyCode) {
                return "暂不支持 fn/🌐 + F1–F12；该键受“将 F1、F2 等键用作标准功能键”影响，当前：\(SystemKeyboardOverlap.standardFunctionKeyModeDescription)。"
            }
            return "fn/🌐 单修饰键仅支持数字 0–9。"
        }
        guard modifiers & UInt32(cmdKey | controlKey) != 0 else {
            return "快捷键必须包含 Command 或 Control。"
        }
        guard !isReserved else { return "该组合由 macOS 保留，请选择其他快捷键。" }
        return nil
    }

    var riskWarning: String? {
        if let warning = SystemKeyboardOverlap.warning(for: self) { return warning }
        if modifiers == UInt32(cmdKey), Self.numberKeyCodes.contains(keyCode) {
            return "⌘ + 数字在部分应用中用于切换标签页；已保存，但 macOS 无法检测所有非独占冲突。"
        }
        let commonKeys = Set([kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_A,
                              kVK_ANSI_Z, kVK_ANSI_S, kVK_ANSI_W, kVK_ANSI_Q]
            .map(UInt32.init))
        guard modifiers & UInt32(cmdKey) != 0, commonKeys.contains(keyCode) else { return nil }
        return "这个组合常被应用使用，可能覆盖剪切、复制、保存、关闭或退出等操作。"
    }

    private var isReserved: Bool {
        let hasFunction = usesFunctionModifier
        let hasCommand = modifiers & UInt32(cmdKey) != 0
        let hasControl = modifiers & UInt32(controlKey) != 0
        let hasOption = modifiers & UInt32(optionKey) != 0
        let hasShift = modifiers & UInt32(shiftKey) != 0

        if hasFunction && [kVK_ANSI_Q, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
            .map(UInt32.init).contains(keyCode) { return true }
        if hasControl && hasOption { return true }
        if hasCommand && (keyCode == UInt32(kVK_Tab) || keyCode == UInt32(kVK_Space)) { return true }
        if hasCommand && hasShift && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
            .map(UInt32.init).contains(keyCode) { return true }
        if hasCommand && hasOption && keyCode == UInt32(kVK_Escape) { return true }
        if hasCommand && hasControl && keyCode == UInt32(kVK_ANSI_Q) { return true }
        if hasCommand && hasShift && keyCode == UInt32(kVK_ANSI_Q) { return true }
        return false
    }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.function) { modifiers |= fnModifierMask }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }

        let keyCode = UInt32(event.keyCode)
        guard supportedKeyCodes.contains(keyCode) else { return nil }
        let label = keyLabels[keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
        guard let label, !label.isEmpty else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    private static let supportedKeyCodes = Set([
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
        kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
        kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
        kVK_ANSI_Z, kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
        kVK_ANSI_9, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow,
        kVK_DownArrow, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
        kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
    ].map(UInt32.init))

    private static let numberKeyCodes = Set([
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ].map(UInt32.init))

    private static let functionKeyCodes = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
    ].map(UInt32.init))

    var usesFunctionModifier: Bool { modifiers & fnModifierMask != 0 }
    var isFunctionDigit: Bool {
        modifiers == fnModifierMask && Self.numberKeyCodes.contains(keyCode)
    }

    private var modifierCount: Int {
        var count = [cmdKey, controlKey, optionKey, shiftKey]
            .filter { modifiers & UInt32($0) != 0 }
            .count
        if usesFunctionModifier { count += 1 }
        return count
    }

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]
}

private struct ShortcutConflictRecord: Codable, Equatable {
    let application: String
    let command: String
    let applicationVersion: String
    let macOSVersion: String
    let verifiedAt: Date
    let result: String
}

private typealias ShortcutConflictKnowledge = [String: [ShortcutConflictRecord]]

private enum ShortcutConflictKnowledgeBase {
    static func key(for shortcut: Shortcut) -> String {
        "v1:\(shortcut.modifiers):\(shortcut.keyCode)"
    }

    static func records(
        for shortcut: Shortcut,
        in knowledge: ShortcutConflictKnowledge
    ) -> [ShortcutConflictRecord] {
        knowledge[key(for: shortcut)] ?? []
    }

    static func warning(
        for shortcut: Shortcut,
        in knowledge: ShortcutConflictKnowledge
    ) -> String? {
        let messages = records(for: shortcut, in: knowledge).map {
            "此组合在 \($0.application) 中是 \($0.command) 功能"
        }
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "；") + "。"
    }
}

private final class PreferenceStore {
    private enum Key {
        static let bindings = "quickToggle.bindings"
        static let target = "quickToggle.target"
        static let shortcut = "quickToggle.shortcut"
        static let settingsShortcut = "quickToggle.settingsShortcut"
        static let enabled = "quickToggle.enabled"
        static let launchIfNeeded = "quickToggle.launchIfNeeded"
        static let importedVerifiedLaunchIDs = "quickToggle.importedVerifiedLaunchIDs"
        static let importedSuggestedAppIDs = "quickToggle.importedSuggestedAppIDs"
        static let occupiedHotKeys = "quickToggle.occupiedHotKeys"
        static let shortcutConflictKnowledge = "quickToggle.shortcutConflictKnowledge"
        static let dailyUpdateCheckEnabled = "quickToggle.dailyUpdateCheckEnabled"
        static let lastUpdateCheckDate = "quickToggle.lastUpdateCheckDate"
        static let knownAvailableUpdate = "quickToggle.knownAvailableUpdate"
        static let knownAvailableUpdateNotes = "quickToggle.knownAvailableUpdateNotes"
        static let themeIdentifier = "quickToggle.themeIdentifier"
        static let applicationLayout = "quickToggle.applicationLayout"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadBindings() -> [AppBinding] {
        defer { defaults.removeObject(forKey: Key.shortcut) }
        if let saved = decode([AppBinding].self, forKey: Key.bindings) { return saved }
        guard let target else { return [] }
        let migrated = [AppBinding(
            id: UUID(),
            target: target,
            shortcut: shortcut,
            launchIfNeeded: launchIfNeeded
        )]
        saveBindings(migrated)
        return migrated
    }

    func saveBindings(_ bindings: [AppBinding]) {
        encode(bindings, forKey: Key.bindings)
    }

    var themeIdentifier: String {
        get { defaults.string(forKey: Key.themeIdentifier) ?? "codexu.default" }
        set { defaults.set(newValue, forKey: Key.themeIdentifier) }
    }

    var applicationLayout: ApplicationLayout {
        get { ApplicationLayout(rawValue: defaults.string(forKey: Key.applicationLayout) ?? "") ?? .list }
        set { defaults.set(newValue.rawValue, forKey: Key.applicationLayout) }
    }

    var target: TargetApplication? {
        get { decode(TargetApplication.self, forKey: Key.target) }
        set { encode(newValue, forKey: Key.target) }
    }

    var shortcut: Shortcut? {
        get { decode(Shortcut.self, forKey: Key.shortcut) }
        set { encode(newValue, forKey: Key.shortcut) }
    }

    var settingsShortcut: Shortcut? {
        get { decode(Shortcut.self, forKey: Key.settingsShortcut) }
        set { encode(newValue, forKey: Key.settingsShortcut) }
    }

    var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) == nil ? true : defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var launchIfNeeded: Bool {
        get { defaults.object(forKey: Key.launchIfNeeded) == nil ? true : defaults.bool(forKey: Key.launchIfNeeded) }
        set { defaults.set(newValue, forKey: Key.launchIfNeeded) }
    }

    var importedVerifiedLaunchIDs: [String] {
        get { defaults.stringArray(forKey: Key.importedVerifiedLaunchIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.importedVerifiedLaunchIDs) }
    }

    var importedSuggestedAppIDs: [String] {
        get { defaults.stringArray(forKey: Key.importedSuggestedAppIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.importedSuggestedAppIDs) }
    }

    func loadOccupiedHotKeys() -> [OccupiedHotKeyEntry] {
        if let saved = decode([OccupiedHotKeyEntry].self, forKey: Key.occupiedHotKeys) { return saved }
        let legacyInstall = defaults.object(forKey: Key.bindings) != nil
            || defaults.object(forKey: Key.target) != nil
        let initial: [OccupiedHotKeyEntry] = legacyInstall ? OccupiedHotKeys.seed : []
        encode(initial, forKey: Key.occupiedHotKeys)
        return initial
    }

    func saveOccupiedHotKeys(_ entries: [OccupiedHotKeyEntry]) {
        encode(entries, forKey: Key.occupiedHotKeys)
    }

    func loadShortcutConflictKnowledge() -> ShortcutConflictKnowledge {
        decode(ShortcutConflictKnowledge.self, forKey: Key.shortcutConflictKnowledge) ?? [:]
    }

    func saveShortcutConflictKnowledge(_ knowledge: ShortcutConflictKnowledge) {
        encode(knowledge, forKey: Key.shortcutConflictKnowledge)
    }

    var dailyUpdateCheckEnabled: Bool {
        get {
            defaults.object(forKey: Key.dailyUpdateCheckEnabled) == nil
                ? true
                : defaults.bool(forKey: Key.dailyUpdateCheckEnabled)
        }
        set { defaults.set(newValue, forKey: Key.dailyUpdateCheckEnabled) }
    }

    var lastUpdateCheckDate: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheckDate) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastUpdateCheckDate)
            } else {
                defaults.removeObject(forKey: Key.lastUpdateCheckDate)
            }
        }
    }

    var knownAvailableUpdate: String? {
        get { defaults.string(forKey: Key.knownAvailableUpdate) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.knownAvailableUpdate)
            } else {
                defaults.removeObject(forKey: Key.knownAvailableUpdate)
            }
        }
    }

    var knownAvailableUpdateNotes: String? {
        get { defaults.string(forKey: Key.knownAvailableUpdateNotes) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.knownAvailableUpdateNotes)
            } else {
                defaults.removeObject(forKey: Key.knownAvailableUpdateNotes)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

private enum StatusTone: Equatable {
    case info
    case warning
    case error

    var color: NSColor {
        switch self {
        case .info: return VisualPalette.secondaryText
        case .warning: return VisualPalette.statusWarningForeground
        case .error: return VisualPalette.statusDangerForeground
        }
    }
}

private struct ThemeVariant: Decodable {
    struct Accent: Decodable {
        let primary: String
        let primaryLight: String
        let secondary: String
        let highlight: String
    }
    struct Selection: Decodable {
        let foreground: String
        let fill: String
        let stroke: String
        let focusRing: String
    }
    struct Tint: Decodable {
        let color: String
        let maximumOpacity: CGFloat
    }
    let accent: Accent
    let selection: Selection
    let surfaceTint: Tint
    var isValid: Bool {
        [accent.primary, accent.primaryLight, accent.secondary, accent.highlight,
         selection.foreground, selection.fill, selection.stroke, selection.focusRing,
         surfaceTint.color].allSatisfy { VisualPalette.parseColor($0) != nil }
            && (0...1).contains(surfaceTint.maximumOpacity)
    }
}

private struct ThemeDefinition: Decodable {
    let id: String
    let name: String
    let light: ThemeVariant
    let dark: ThemeVariant
}

private enum ThemeCatalog {
    static let didChange = Notification.Name("QuickToggleThemeDidChange")
    static let bundled: [ThemeDefinition] = {
        guard let url = Bundle.main.url(forResource: "AiGoodBroThemes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([ThemeDefinition].self, from: data) else { return [] }
        var seen = Set<String>()
        return themes.filter { !$0.name.isEmpty && $0.light.isValid && $0.dark.isValid && seen.insert($0.id).inserted }
    }()
    static let byID = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0) })
    private(set) static var selectedID = "codexu.default"
    static var isDefault: Bool { selectedID == "codexu.default" }
    static func variant(dark: Bool) -> ThemeVariant? {
        let theme = byID[selectedID] ?? byID["codexu.default"]
        return dark ? theme?.dark : theme?.light
    }
    static func select(_ id: String) {
        let resolved = byID[id] != nil ? id : "codexu.default"
        guard selectedID != resolved else { return }
        selectedID = resolved
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// AppKit adaptation of AiGoodBro's FixedVisualPalette, WorkspaceGlass and
/// WorkspaceInteraction. The foregrounds, gradients and selection tokens come
/// from its bundled stable palettes; no AiGoodBro settings are written or linked.
private enum VisualPalette {
    static let statusWarning = NSColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1)          // #FF9F0A
    static let statusDanger = NSColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1)           // #FF453A
    static let statusWarningLightText = NSColor(red: 0.502, green: 0.294, blue: 0.000, alpha: 1) // #804B00
    static let statusDangerLightText = NSColor(red: 0.66, green: 0.10, blue: 0.075, alpha: 1)
    static let glassOpacity: CGFloat = 0.74
    static let lineOpacity: CGFloat = 0.19
    static let controlOpacity: CGFloat = 0.075

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static func parseColor(_ text: String) -> NSColor? {
        guard text.hasPrefix("#"), text.count == 7 || text.count == 9,
              let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return text.count == 9 ? color(value >> 8, alpha: CGFloat(value & 0xff) / 255) : color(value)
    }
    /// Immutable and bounded to the bundled palettes. Repaints never parse hex strings.
    private struct Colors {
        let primary, primaryLight, secondary, highlight: NSColor
        let selectionFill, selectionStroke, selectedText, surfaceTint: NSColor
        let surfaceOpacity: CGFloat
        init(_ variant: ThemeVariant?) {
            primary = variant.flatMap { parseColor($0.accent.primary) } ?? color(0x2866F7)
            primaryLight = variant.flatMap { parseColor($0.accent.primaryLight) } ?? color(0x7BA0FF)
            secondary = variant.flatMap { parseColor($0.accent.secondary) } ?? color(0x8B6DFF)
            highlight = variant.flatMap { parseColor($0.accent.highlight) } ?? color(0xDAA3FA)
            selectionFill = variant.flatMap { parseColor($0.selection.fill) } ?? primary.withAlphaComponent(0.12)
            selectionStroke = variant.flatMap { parseColor($0.selection.stroke) } ?? primary.withAlphaComponent(0.34)
            selectedText = variant.flatMap { parseColor($0.selection.foreground) } ?? primary
            surfaceTint = variant.flatMap { parseColor($0.surfaceTint.color) } ?? primary
            surfaceOpacity = variant?.surfaceTint.maximumOpacity ?? 0.05
        }
    }
    private static let palettes = Dictionary(uniqueKeysWithValues: ThemeCatalog.bundled.map {
        ($0.id, (light: Colors($0.light), dark: Colors($0.dark)))
    })
    private static let fallback = Colors(nil)
    private static func colors(_ dark: Bool) -> Colors {
        guard let palette = palettes[ThemeCatalog.selectedID] ?? palettes["codexu.default"] else { return fallback }
        return dark ? palette.dark : palette.light
    }
    static func primary(_ dark: Bool) -> NSColor { colors(dark).primary }
    static func primaryLight(_ dark: Bool) -> NSColor { colors(dark).primaryLight }
    static func secondary(_ dark: Bool) -> NSColor { colors(dark).secondary }
    static func highlight(_ dark: Bool) -> NSColor { colors(dark).highlight }
    static func selectionFill(_ dark: Bool) -> NSColor { colors(dark).selectionFill }
    static func selectionStroke(_ dark: Bool) -> NSColor { colors(dark).selectionStroke }
    static func foreground(_ dark: Bool) -> NSColor { dark ? .white : .black }
    static func opaqueSurface() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || increasedContrast()
    }
    static let accent = NSColor(name: nil) { primary(isDark($0)) }
    static let selectedText = NSColor(name: nil) { appearance in
        let dark = isDark(appearance)
        return colors(dark).selectedText
    }
    static let secondaryText = NSColor(name: nil) { foreground(isDark($0)).withAlphaComponent(isDark($0) ? 0.72 : 0.66) }
    static let tertiaryText = NSColor(name: nil) { foreground(isDark($0)).withAlphaComponent(0.56) }

    static func drawSurface(in rect: NSRect, radius: CGFloat, dark: Bool, elevated: Bool = false) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if opaqueSurface() {
            NSColor.controlBackgroundColor.setFill()
            shape.fill()
            foreground(dark).withAlphaComponent(0.35).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.controlBackgroundColor.withAlphaComponent(dark ? 0.24 : 0.36).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(controlOpacity * (dark ? 0.4 : 1.4)).setFill()
        shape.fill()
        let palette = colors(dark)
        palette.surfaceTint.withAlphaComponent(palette.surfaceOpacity * (ThemeCatalog.isDefault ? 0.22 : 0.75)).setFill()
        shape.fill()
        NSGradient(colors: [.white.withAlphaComponent(dark ? 0.13 : 0.36),
                            primaryLight(dark).withAlphaComponent(dark ? 0.065 : 0.035), .clear])?
            .draw(in: rect, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        // The source uses a restrained edge over one system blur layer.
        foreground(dark).withAlphaComponent(elevated ? lineOpacity : lineOpacity * (dark ? 0.78 : 0.47)).setStroke()
        shape.lineWidth = 0.7
        shape.stroke()
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static let statusWarningForeground = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(red: 1, green: 0.93, blue: 0.76, alpha: 1) : statusWarningLightText
    }

    static let statusDangerForeground = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(red: 1, green: 0.93, blue: 0.91, alpha: 1) : statusDangerLightText
    }

    static func increasedContrast() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// Fires when reduce-transparency / increase-contrast toggles change, so views
/// with custom colors can re-read them live. NSWorkspace notifications must be
/// observed on NSWorkspace.shared.notificationCenter.
private func observeAccessibilityDisplayOptions(onUpdate: @escaping () -> Void) -> NSObjectProtocol {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil,
        queue: .main
    ) { _ in onUpdate() }
}

/// One material below the content, with AiGoodBro's palette gradients above it.
/// Opaque accessibility modes omit every ornamental gradient.
private final class WindowScrimView: NSView {
    private var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateColors()
        displayOptionsObserver = observeAccessibilityDisplayOptions { [weak self] in
            self?.updateColors()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = VisualPalette.isDark(effectiveAppearance)
        if VisualPalette.opaqueSurface() {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        // FixedVisualPalette.windowScrim is the contrast anchor for a content-
        // heavy window; gradients retain the original palette relationships.
        VisualPalette.color(dark ? 0x13141A : 0xF4F5F9, alpha: dark ? 0.96 : 0.98).setFill()
        bounds.fill()
        let strength = 0.7 + VisualPalette.glassOpacity * 0.3
        let span = max(bounds.width, bounds.height, 1)
        let primary = VisualPalette.primary(dark)
        let secondary = VisualPalette.secondary(dark)
        let highlight = VisualPalette.highlight(dark)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        if ThemeCatalog.isDefault {
            for (color, center, radius) in [
                (primary.withAlphaComponent(dark ? 0.14 : 0.10), NSPoint(x: 0, y: bounds.height), bounds.width * 0.8),
                (secondary.withAlphaComponent(dark ? 0.075 : 0.055), NSPoint(x: bounds.width, y: 0), bounds.width * 0.65)
            ] {
                NSGradient(starting: color, ending: .clear)?.draw(fromCenter: center, radius: 0, toCenter: center, radius: max(radius, 1), options: .drawsAfterEndingLocation)
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGradient(colors: [primary.withAlphaComponent((dark ? 0.20 : 0.12) * strength),
                            secondary.withAlphaComponent((dark ? 0.13 : 0.08) * strength),
                            highlight.withAlphaComponent((dark ? 0.10 : 0.07) * strength)])?.draw(in: bounds, angle: -45)
        let topLeft = NSPoint(x: bounds.width * 0.08, y: bounds.height * 0.92)
        NSGradient(colorsAndLocations:
            (primary.withAlphaComponent((dark ? 0.45 : 0.34) * strength), 0),
            (VisualPalette.primaryLight(dark).withAlphaComponent((dark ? 0.23 : 0.16) * strength), 0.47),
            (.clear, 1))?.draw(fromCenter: topLeft, radius: 0, toCenter: topLeft, radius: span * 0.88, options: .drawsAfterEndingLocation)
        for (color, center, radius) in [
            (secondary.withAlphaComponent((dark ? 0.38 : 0.25) * strength), NSPoint(x: bounds.width, y: 0), span * 0.76),
            (highlight.withAlphaComponent((dark ? 0.22 : 0.17) * strength), NSPoint(x: bounds.width * 0.88, y: bounds.height * 0.88), span * 0.54)
        ] {
            NSGradient(starting: color, ending: .clear)?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: .drawsAfterEndingLocation)
        }
        NSGradient(colorsAndLocations: (.white.withAlphaComponent(dark ? 0.08 : 0.20), 0),
                   (.clear, 0.42), (.white.withAlphaComponent(dark ? 0.015 : 0.055), 1))?.draw(in: bounds, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Native NSButton behavior with the same quiet hover/press treatment used by
/// AiGoodBro. There are no layout animations, timers or secondary blur layers.
private class GlassActionButton: NSButton {
    var emphasized = false { didSet { needsDisplay = true } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var displayObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .exterior
        displayObserver = observeAccessibilityDisplayOptions { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
    override var intrinsicContentSize: NSSize {
        let label = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
        return NSSize(width: label.width + 24 + (image == nil ? 0 : 20), height: controlSize == .small ? 28 : 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = VisualPalette.isDark(effectiveAppearance)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        VisualPalette.drawSurface(in: rect, radius: 7, dark: dark, elevated: emphasized)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if emphasized && isEnabled {
            VisualPalette.selectionFill(dark).setFill()
            shape.fill()
            VisualPalette.selectionStroke(dark).setStroke()
            shape.lineWidth = 0.7
            shape.stroke()
        }
        if isEnabled && (isHighlighted || hovering) {
            VisualPalette.foreground(dark).withAlphaComponent(isHighlighted ? 0.13 : 0.07).setFill()
            shape.fill()
        }
        let foreground: NSColor
        if !isEnabled { foreground = VisualPalette.foreground(dark).withAlphaComponent(0.45) }
        else if emphasized { foreground = dark ? .white : VisualPalette.selectedText }
        else { foreground = VisualPalette.foreground(dark) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        let available = bounds.insetBy(dx: 10, dy: 0)
        let iconWidth: CGFloat = image == nil ? 0 : 18
        let labelWidth = min((title as NSString).size(withAttributes: attributes).width, max(0, available.width - iconWidth))
        let contentX = bounds.midX - (labelWidth + iconWidth) / 2
        if let image, let tinted = image.copy() as? NSImage {
            tinted.isTemplate = false
            tinted.lockFocus()
            foreground.setFill()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: contentX, y: bounds.midY - 7, width: 14, height: 14),
                        from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.45)
        }
        (title as NSString).draw(in: NSRect(x: contentX + iconWidth, y: bounds.midY - textHeight / 2,
                                          width: labelWidth, height: textHeight), withAttributes: attributes)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

private enum StatusPolicy {
    static let stickyDuration: TimeInterval = 12

    static func shouldKeepCurrent(
        current: StatusTone,
        incoming: StatusTone,
        stickyUntil: Date,
        now: Date = Date()
    ) -> Bool {
        incoming == .info && current != .info && now < stickyUntil
    }
}

private enum LoginItemStatus: Equatable {
    case off
    case on
    case needsApproval
    case unavailable

    var isOn: Bool { self == .on }

    var helpText: String {
        switch self {
        case .on:
            return "登录后自动运行 AiGoodChange，快捷键才会在开机后可用。"
        case .needsApproval:
            return "请在“系统设置 > 通用 > 登录项与扩展”中允许 AiGoodChange。"
        case .unavailable:
            return "当前环境无法使用系统登录项。"
        case .off:
            return "默认关闭。打开后由 macOS 在登录时启动，不会新增后台进程。"
        }
    }
}

private enum LoginAtLaunch {
    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        default: return .off
        }
    }

    static func setEnabled(_ enabled: Bool) -> (LoginItemStatus, String?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return (status, "无法更改登录时启动。")
        }
        let next = status
        switch next {
        case .on:
            return (next, nil)
        case .needsApproval, .unavailable:
            return (next, next.helpText)
        case .off:
            return (next, enabled ? "登录时启动未生效。" : nil)
        }
    }
}

// MARK: - Visible app scan and confirmed shortcut help

private struct ScannedApplication: Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String

    var url: URL { URL(fileURLWithPath: path) }
}

private enum ApplicationScanner {
    static func visibleApplications(excluding excludedBundleIDs: Set<String>) -> [ScannedApplication] {
        var seen = excludedBundleIDs
        var results: [ScannedApplication] = []
        for url in candidateAppURLs() {
            guard shouldInclude(url: url),
                  let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  !identifier.isEmpty,
                  !seen.contains(identifier) else { continue }
            seen.insert(identifier)
            results.append(
                ScannedApplication(
                    bundleIdentifier: identifier,
                    name: displayName(for: url),
                    path: url.path
                )
            )
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func shouldInclude(url: URL) -> Bool {
        guard url.pathExtension == "app",
              !isExcludedPath(url.path),
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              !identifier.isEmpty else { return false }
        if identifier == Bundle.main.bundleIdentifier { return false }
        if isInvisibleInfo(bundle.infoDictionary ?? [:]) { return false }
        return !displayName(for: url).isEmpty
    }

    static func isExcludedPath(_ path: String) -> Bool {
        let markers = [
            "/Contents/Frameworks/",
            "/Contents/PlugIns/",
            "/XPCServices/",
            "/Helpers/",
            "/Library/LoginItems/"
        ]
        return markers.contains { path.contains($0) }
    }

    static func isInvisibleInfo(_ info: [String: Any]) -> Bool {
        isTruthy(info["LSBackgroundOnly"]) || isTruthy(info["LSUIElement"])
    }

    static func displayName(for url: URL) -> String {
        if Bundle(url: url)?.bundleIdentifier == "com.apple.finder" { return "访达" }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func candidateAppURLs() -> [URL] {
        let fileManager = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true)
        ]
        if let local = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first {
            roots.append(local)
        }
        var urls: [URL] = []
        var seenPaths = Set<String>()
        // Finder lives outside the normal Applications folders. Include only
        // this visible app, rather than exposing unrelated CoreServices helpers.
        appendApp(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), into: &urls, seen: &seenPaths)
        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    appendApp(item, into: &urls, seen: &seenPaths)
                    continue
                }
                guard let nested = try? fileManager.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in nested where child.pathExtension == "app" {
                    appendApp(child, into: &urls, seen: &seenPaths)
                }
            }
        }
        return urls
    }

    private static func appendApp(_ url: URL, into urls: inout [URL], seen: inout Set<String>) {
        let resolved = url.resolvingSymlinksInPath()
        guard seen.insert(resolved.path).inserted else { return }
        urls.append(resolved)
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        default: return false
        }
    }
}

private struct OccupiedHotKeyEntry: Codable, Equatable {
    let name: String
    let shortcut: Shortcut
}

private enum OccupiedHotKeys {
    static let seed: [OccupiedHotKeyEntry] = [
        OccupiedHotKeyEntry(
            name: "Aident",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), label: "1")
        ),
        OccupiedHotKeyEntry(
            name: "Wi‑Fi 菜单",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey), label: "2")
        ),
        OccupiedHotKeyEntry(
            name: "微信",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), label: "W")
        )
    ]

    static func summary(of entries: [OccupiedHotKeyEntry]) -> String {
        guard !entries.isEmpty else {
            return "本机已占用：暂无记录。把其他软件占用的组合加进来，AiGoodChange 录制时会自动避开。"
        }
        let body = entries.map { "\($0.name) \($0.shortcut.displayName)" }.joined(separator: "，")
        return "本机已占用：\(body)。不要再录进 AiGoodChange。"
    }

    static func owner(of shortcut: Shortcut, in entries: [OccupiedHotKeyEntry]) -> String? {
        entries.first { $0.shortcut == shortcut }?.name
    }
}

private enum QuickToggleRow {
    case binding(AppBinding)
    case occupied(OccupiedHotKeyEntry)
}

private enum BindingOrder {
    static let digitKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_0), UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    struct SortKey: Comparable {
        let rank: Int
        let number: Int
        let label: String
        let name: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            if lhs.label != rhs.label { return lhs.label < rhs.label }
            return lhs.name < rhs.name
        }
    }

    static func sortKey(_ binding: AppBinding) -> SortKey {
        sortKey(shortcut: binding.shortcut, name: binding.target.name)
    }

    static func sortKey(_ entry: OccupiedHotKeyEntry) -> SortKey {
        sortKey(shortcut: entry.shortcut, name: entry.name)
    }

    static func sortKey(_ row: QuickToggleRow) -> SortKey {
        switch row {
        case .binding(let binding): return sortKey(binding)
        case .occupied(let entry): return sortKey(entry)
        }
    }

    private static func sortKey(shortcut: Shortcut?, name: String) -> SortKey {
        guard let shortcut else {
            return SortKey(rank: 3, number: Int.max, label: "", name: name)
        }
        if shortcut.modifiers == UInt32(cmdKey),
           let digit = digitKeyCodes.firstIndex(of: shortcut.keyCode) {
            return SortKey(rank: 0, number: digit, label: "", name: name)
        }
        if shortcut.isFunctionDigit,
           let digit = digitKeyCodes.firstIndex(of: shortcut.keyCode) {
            return SortKey(rank: 1, number: digit, label: "", name: name)
        }
        return SortKey(rank: 2, number: Int.max, label: shortcut.label, name: name)
    }

    static func sorted(_ bindings: [AppBinding]) -> [AppBinding] {
        bindings.sorted { sortKey($0) < sortKey($1) }
    }

    static func sorted(_ rows: [QuickToggleRow]) -> [QuickToggleRow] {
        rows.sorted { sortKey($0) < sortKey($1) }
    }
}

private enum ShortcutSuggester {
    static let commandDigits: [(keyCode: UInt32, label: String)] = [
        (UInt32(kVK_ANSI_1), "1"), (UInt32(kVK_ANSI_2), "2"), (UInt32(kVK_ANSI_3), "3"),
        (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"), (UInt32(kVK_ANSI_6), "6"),
        (UInt32(kVK_ANSI_7), "7"), (UInt32(kVK_ANSI_8), "8"), (UInt32(kVK_ANSI_9), "9")
    ]

    static let functionDigits: [(keyCode: UInt32, label: String)] = commandDigits + [
        (UInt32(kVK_ANSI_0), "0")
    ]

    static func nextFreeCommandDigit(
        bindings: [AppBinding],
        occupied: [OccupiedHotKeyEntry],
        settingsShortcut: Shortcut?
    ) -> Shortcut? {
        for (keyCode, label) in commandDigits {
            let candidate = Shortcut(keyCode: keyCode, modifiers: UInt32(cmdKey), label: label)
            if OccupiedHotKeys.owner(of: candidate, in: occupied) != nil { continue }
            if bindings.contains(where: { $0.shortcut == candidate }) { continue }
            if settingsShortcut == candidate { continue }
            return candidate
        }
        return nil
    }

    static func nextFreeFunctionDigit(
        bindings: [AppBinding],
        occupied: [OccupiedHotKeyEntry],
        settingsShortcut: Shortcut?
    ) -> Shortcut? {
        for (keyCode, label) in functionDigits {
            let candidate = Shortcut(keyCode: keyCode, modifiers: fnModifierMask, label: label)
            if OccupiedHotKeys.owner(of: candidate, in: occupied) != nil { continue }
            if bindings.contains(where: { $0.shortcut == candidate }) { continue }
            if settingsShortcut == candidate { continue }
            return candidate
        }
        return nil
    }

    static func nextFreeRecommendedDigit(
        bindings: [AppBinding],
        occupied: [OccupiedHotKeyEntry],
        settingsShortcut: Shortcut?
    ) -> Shortcut? {
        nextFreeCommandDigit(
            bindings: bindings,
            occupied: occupied,
            settingsShortcut: settingsShortcut
        ) ?? nextFreeFunctionDigit(
            bindings: bindings,
            occupied: occupied,
            settingsShortcut: settingsShortcut
        )
    }
}

private enum ShortcutProbe {
    enum Verdict: Equatable {
        case ready
        case invalid(String)
        case missingApp(String)
        case usedByQuickToggle
        case occupiedLocally(String)
    }

    static func appIsPresent(bundleIdentifier: String, path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func inspect(
        _ shortcut: Shortcut,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        path: String? = nil,
        bindings: [AppBinding],
        excluding: UUID,
        asSettings: Bool,
        occupied: [OccupiedHotKeyEntry]
    ) -> Verdict {
        if !asSettings, let bundleIdentifier, let path,
           !appIsPresent(bundleIdentifier: bundleIdentifier, path: path) {
            return .missingApp(appName ?? "目标应用")
        }
        if asSettings {
            if let error = shortcut.settingsValidationError { return .invalid(error) }
        } else if let error = shortcut.validationError {
            return .invalid(error)
        }
        if shortcutIsUsed(shortcut, in: bindings, excluding: excluding) {
            return .usedByQuickToggle
        }
        if let owner = OccupiedHotKeys.owner(of: shortcut, in: occupied) {
            return .occupiedLocally(owner)
        }
        return .ready
    }
}

private enum ConfigurationExchange {
    static let formatVersion = 1

    struct Payload: Codable, Equatable {
        var formatVersion: Int
        var appVersion: String
        var exportedAt: Date
        var bindings: [AppBinding]
        var settingsShortcut: Shortcut?
        var enabled: Bool
        var launchIfNeeded: Bool
        var importedVerifiedLaunchIDs: [String]
        var importedSuggestedAppIDs: [String]
        var occupiedHotKeys: [OccupiedHotKeyEntry]
    }

    static func makePayload(
        bindings: [AppBinding],
        settingsShortcut: Shortcut?,
        enabled: Bool,
        launchIfNeeded: Bool,
        importedVerifiedLaunchIDs: [String],
        importedSuggestedAppIDs: [String],
        occupiedHotKeys: [OccupiedHotKeyEntry],
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        now: Date = Date()
    ) -> Payload {
        Payload(
            formatVersion: formatVersion,
            appVersion: appVersion,
            exportedAt: now,
            bindings: bindings,
            settingsShortcut: settingsShortcut,
            enabled: enabled,
            launchIfNeeded: launchIfNeeded,
            importedVerifiedLaunchIDs: importedVerifiedLaunchIDs,
            importedSuggestedAppIDs: importedSuggestedAppIDs,
            occupiedHotKeys: occupiedHotKeys
        )
    }

    static func encode(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data) -> Payload? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.formatVersion == formatVersion else { return nil }
        return payload
    }

    static func partitionImportable(_ bindings: [AppBinding]) -> (importable: [AppBinding], missing: [String]) {
        var importable: [AppBinding] = []
        var missing: [String] = []
        for binding in bindings {
            if ShortcutProbe.appIsPresent(
                bundleIdentifier: binding.target.bundleIdentifier,
                path: binding.target.path
            ) {
                importable.append(binding)
            } else {
                missing.append(binding.target.name)
            }
        }
        return (importable, missing)
    }
}

private enum ConfirmedAppShortcuts {
    static let catalog: [(bundleIdentifier: String, name: String)] = [
        ("com.tencent.xinWeChat", "微信"),
        ("com.openai.codex", "Codex"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.Terminal", "终端")
    ]

    static func entries(for bundleIdentifier: String) -> [(String, String)] {
        switch bundleIdentifier {
        case "com.tencent.xinWeChat":
            return [("打开微信（本机已验证）", "⇧⌘W")]
        case "com.openai.codex":
            return [("命令菜单", "⌘ K"), ("新建对话", "⌘ N")]
        case "com.google.Chrome":
            return [("定位地址栏", "⌘ L"), ("重开关闭标签", "⇧⌘ T")]
        case "com.apple.Safari":
            return [("打开位置", "⌘ L"), ("新建标签页", "⌘ T")]
        case "com.apple.Terminal":
            return [("新建窗口", "⌘ N"), ("新建标签页", "⌘ T")]
        default:
            return []
        }
    }
}

private struct VerifiedLaunchHotKey {
    let bundleIdentifier: String
    let name: String
    let shortcut: Shortcut
}

private enum VerifiedLaunchHotKeys {
    static let all: [VerifiedLaunchHotKey] = [
        VerifiedLaunchHotKey(
            bundleIdentifier: "com.tencent.xinWeChat",
            name: "微信",
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "W"
            )
        )
    ]

    static func shortcut(for bundleIdentifier: String) -> Shortcut? {
        all.first { $0.bundleIdentifier == bundleIdentifier }?.shortcut
    }
}

private struct SuggestedToggleApp {
    let bundleIdentifier: String
    let name: String
    let shortcut: Shortcut
}

private enum SuggestedToggleApps {
    static let all: [SuggestedToggleApp] = [
        SuggestedToggleApp(
            bundleIdentifier: "com.apple.ActivityMonitor",
            name: "活动监视器",
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "A"
            )
        ),
        SuggestedToggleApp(
            bundleIdentifier: "com.apple.Terminal",
            name: "终端",
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_T),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "T"
            )
        ),
        SuggestedToggleApp(
            bundleIdentifier: "nl.syncfactory.Hedge.Mac",
            name: "OffShoot",
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_O),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "O"
            )
        ),
        SuggestedToggleApp(
            bundleIdentifier: "com.bytedance.macos.feishu",
            name: "飞书",
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_F),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "F"
            )
        )
    ]

    static func shortcut(for bundleIdentifier: String) -> Shortcut? {
        all.first { $0.bundleIdentifier == bundleIdentifier }?.shortcut
    }
}

private enum IconNormalizer {
    static let contentInsetRatio: CGFloat = 0.04

    static func drawingRect(content: NSSize, canvas: NSSize) -> NSRect {
        let side = min(canvas.width, canvas.height)
        let inset = max(side * contentInsetRatio, 0.5)
        let target = NSRect(
            x: inset,
            y: inset,
            width: canvas.width - inset * 2,
            height: canvas.height - inset * 2
        )
        let scale = min(
            target.width / max(content.width, 1),
            target.height / max(content.height, 1)
        )
        let draw = NSSize(width: content.width * scale, height: content.height * scale)
        return NSRect(
            x: target.midX - draw.width / 2,
            y: target.midY - draw.height / 2,
            width: draw.width,
            height: draw.height
        )
    }

    static func image(at path: String, pointSize: CGFloat) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let canvas = NSSize(width: pointSize, height: pointSize)
        let samplePixels = 128
        source.size = NSSize(width: samplePixels, height: samplePixels)
        guard let raster = rasterized(source, pixels: samplePixels),
              let bounds = opaqueBounds(in: raster),
              let cgImage = raster.cgImage,
              let cropped = cgImage.cropping(to: bounds) else {
            return draw(source, into: canvas, content: NSSize(width: samplePixels, height: samplePixels))
        }
        let croppedImage = NSImage(
            cgImage: cropped,
            size: NSSize(width: bounds.width, height: bounds.height)
        )
        return draw(croppedImage, into: canvas, content: croppedImage.size)
    }

    private static func rasterized(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        return rep
    }

    private static func opaqueBounds(in rep: NSBitmapImageRep, alphaLimit: CGFloat = 0.18) -> CGRect? {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var found = false
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent >= alphaLimit else {
                    continue
                }
                found = true
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
        guard found else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func draw(_ image: NSImage, into canvas: NSSize, content: NSSize) -> NSImage {
        let dest = drawingRect(content: content, canvas: canvas)
        let pixelsWide = max(Int((canvas.width * 2).rounded()), 1)
        let pixelsHigh = max(Int((canvas.height * 2).rounded()), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return drawLegacy(image, into: canvas, dest: dest)
        }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: canvas).fill()
            image.draw(
                in: dest,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: canvas)
        output.addRepresentation(rep)
        output.isTemplate = false
        return output
    }

    private static func drawLegacy(_ image: NSImage, into canvas: NSSize, dest: NSRect) -> NSImage {
        let output = NSImage(size: canvas)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: dest,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        output.unlockFocus()
        output.isTemplate = false
        return output
    }
}

private func sizedApplicationIcon(at path: String, pointSize: CGFloat) -> NSImage {
    IconNormalizer.image(at: path, pointSize: pointSize)
}

private enum BindingHelpContent {
    static func view(for binding: AppBinding) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(section(
            title: "AiGoodChange 热键",
            body: binding.shortcut?.displayName ?? "尚未为这个应用录制 AiGoodChange 热键。"
        ))

        let confirmed = ConfirmedAppShortcuts.entries(for: binding.target.bundleIdentifier)
        if confirmed.isEmpty {
            stack.addArrangedSubview(section(
                title: "已确认的应用快捷键",
                body: "未能确认该应用的原生快捷键。请查看菜单栏命令或应用设置。"
            ))
        } else {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 4
            confirmed.forEach { rows.addArrangedSubview(keyRow(action: $0.0, keys: $0.1)) }
            let block = NSStackView(views: [heading("已确认的应用快捷键"), rows])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            stack.addArrangedSubview(block)
        }

        if let native = VerifiedLaunchHotKeys.shortcut(for: binding.target.bundleIdentifier) {
            stack.addArrangedSubview(section(
                title: "应用自带快速启动",
                body: "本机已验证为 \(native.displayName)。AiGoodChange 改不了微信设置里的那一项；若该组合正被微信占用，点本行录制按钮改成其他组合，保存后立即由 AiGoodChange 接管。"
            ))
        }

        stack.addArrangedSubview(section(
            title: "如何修改 AiGoodChange 热键",
            body: "点本行右侧的录制按钮，按下新组合即可。Esc 取消，Delete 清除。改完马上生效，不必退出 AiGoodChange。"
        ))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 10))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalToConstant: 252)
        ])
        container.frame.size = container.fittingSize
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("\(binding.target.name) 的快捷键说明")
        return container
    }

    private static func section(title: String, body: String) -> NSView {
        let stack = NSStackView(views: [heading(title), paragraph(body)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private static func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private static func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.preferredMaxLayoutWidth = 252
        return field
    }

    private static func keyRow(action: String, keys: String) -> NSView {
        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 12)
        actionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let keyLabel = NSTextField(labelWithString: keys)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [actionLabel, spacer, keyLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 252).isActive = true
        row.setAccessibilityLabel("\(action)，\(keys)")
        return row
    }
}

private final class PendingApplicationPickerController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onPick: ((URL) -> Void)?
    var onChooseFromDisk: (() -> Void)?

    private var applications: [ScannedApplication] = []
    private var filtered: [ScannedApplication] = []
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let selectionHint = NSTextField(labelWithString: "")
    private let selectButton = NSButton()
    private var isReplacing = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 336))
        view = root

        searchField.placeholderString = "搜索已安装的应用"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("搜索待添加应用")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(addSelected)
        tableView.setAccessibilityLabel("待添加应用列表")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = "没有可添加的可视应用。"
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = selectionHint
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let diskButton = NSButton(title: "从磁盘选择…", target: self, action: #selector(chooseFromDisk))
        diskButton.bezelStyle = .rounded
        diskButton.setAccessibilityLabel("从磁盘选择应用")
        diskButton.translatesAutoresizingMaskIntoConstraints = false

        let addButton = selectButton
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityLabel("添加选中的应用")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        root.addSubview(countLabel)
        root.addSubview(hint)
        root.addSubview(diskButton)
        root.addSubview(addButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
            hint.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),
            countLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            countLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            diskButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            diskButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            hint.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func reload(excluding excludedBundleIDs: Set<String>, replacing binding: AppBinding? = nil) {
        _ = view // NSViewController.loadViewIfNeeded requires macOS 14; support macOS 13.
        isReplacing = binding != nil
        searchField.stringValue = ""
        searchField.setAccessibilityLabel(isReplacing ? "搜索替换应用" : "搜索待添加应用")
        tableView.setAccessibilityLabel(isReplacing ? "可替换应用列表" : "待添加应用列表")
        selectButton.title = isReplacing ? "更换" : "添加"
        selectButton.setAccessibilityLabel(isReplacing ? "更换为选中的应用" : "添加选中的应用")
        if let binding {
            selectionHint.stringValue = binding.shortcut.map { "更换 \(binding.target.name)，保留 \($0.displayName)。" }
                ?? "更换 \(binding.target.name)，保持未设置快捷键。"
        } else {
            selectionHint.stringValue = "双击或回车添加，按 ↓ 进入列表；快捷键可在添加后修改。"
        }
        selectionHint.lineBreakMode = .byTruncatingTail
        selectionHint.toolTip = selectionHint.stringValue
        applications = ApplicationScanner.visibleApplications(excluding: excludedBundleIDs)
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
        guard !filtered.isEmpty else { return false }
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(tableView)
        tableView.scrollRowToVisible(max(tableView.selectedRow, 0))
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row]
        let identifier = NSUserInterfaceItemIdentifier("PendingAppCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.imageView?.image = sizedApplicationIcon(at: item.path, pointSize: 20)
        cell.textField?.stringValue = item.name
        cell.setAccessibilityLabel(item.name)
        return cell
    }

    @objc private func addSelected() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        onPick?(filtered[row].url)
    }

    @objc private func chooseFromDisk() {
        onChooseFromDisk?()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = applications
        } else {
            filtered = applications.filter { $0.name.localizedStandardContains(query) }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        emptyLabel.isHidden = !filtered.isEmpty
        if applications.isEmpty {
            emptyLabel.stringValue = isReplacing ? "没有可替换的应用，可从磁盘选择。" : "没有可添加的可视应用。"
            countLabel.stringValue = isReplacing ? "0 个可选" : "0 个待添加"
        } else if filtered.isEmpty {
            emptyLabel.stringValue = "没有匹配的应用。"
            countLabel.stringValue = "0 / \(applications.count)"
        } else {
            countLabel.stringValue = "\(filtered.count) 个\(isReplacing ? "可选" : "待添加")"
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// MARK: - Transactional Carbon hot key

private enum HotKeyFailure: Error, Equatable {
    case occupied
    case permissionDenied
    case failed
}

private enum FunctionEventTapState: Equatable {
    case idle
    case active
    case permissionDenied
    case unavailable
    case disabled
}

private func functionEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userData: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userData else { return Unmanaged.passUnretained(event) }
    let center = Unmanaged<FunctionHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    return center.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

private final class FunctionHotKeyCenter {
    struct Entry {
        let shortcut: Shortcut
        let onKeyDown: () -> Void
        let onKeyUp: () -> Void
    }

    static let shared = FunctionHotKeyCenter()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var entries: [UUID: Entry] = [:]
    private var pressedTokensByKeyCode: [UInt32: Set<UUID>] = [:]
    private(set) var state: FunctionEventTapState = .idle

    var activeRegistrationCount: Int { entries.count }

    static func hasExactFunctionModifier(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskSecondaryFn) else { return false }
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return flags.intersection(otherModifiers).isEmpty
    }

    func register(
        _ shortcut: Shortcut,
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) -> Result<UUID, HotKeyFailure> {
        guard shortcut.isFunctionDigit else { return .failure(.failed) }
        if entries.values.contains(where: { $0.shortcut == shortcut }) {
            return .failure(.occupied)
        }
        switch ensureTap(requestPermission: true) {
        case .failure(let error): return .failure(error)
        case .success: break
        }
        let token = UUID()
        entries[token] = Entry(shortcut: shortcut, onKeyDown: onKeyDown, onKeyUp: onKeyUp)
        return .success(token)
    }

    func probe(_ shortcut: Shortcut) -> Result<Void, HotKeyFailure> {
        guard shortcut.isFunctionDigit else { return .failure(.failed) }
        if entries.values.contains(where: { $0.shortcut == shortcut }) {
            return .failure(.occupied)
        }
        let result = ensureTap(requestPermission: true)
        if entries.isEmpty, case .success = result { stopTap(nextState: .idle) }
        return result
    }

    func unregister(_ token: UUID) -> Result<Void, HotKeyFailure> {
        guard entries.removeValue(forKey: token) != nil else { return .success(()) }
        for keyCode in Array(pressedTokensByKeyCode.keys) {
            pressedTokensByKeyCode[keyCode]?.remove(token)
            if pressedTokensByKeyCode[keyCode]?.isEmpty == true {
                pressedTokensByKeyCode.removeValue(forKey: keyCode)
            }
        }
        if entries.isEmpty { stopTap(nextState: .idle) }
        return .success(())
    }

    func diagnosticDescription(configuredCount: Int) -> String {
        if configuredCount == 0 {
            switch state {
            case .permissionDenied: return "Fn 通道失败：辅助功能未授权"
            case .unavailable: return "Fn 通道失败：事件监听不可用"
            case .disabled: return "Fn 通道失败：事件监听已停用"
            case .idle, .active: return "Fn 通道未使用"
            }
        }
        switch state {
        case .active:
            return "Fn 通道 \(activeRegistrationCount)/\(configuredCount) 已监听"
        case .permissionDenied:
            return "Fn 通道失败：辅助功能未授权"
        case .unavailable:
            return "Fn 通道失败：事件监听不可用"
        case .disabled:
            return "Fn 通道失败：事件监听已停用"
        case .idle:
            return "Fn 通道待启用"
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseAllPressedKeys()
            state = .disabled
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                state = CGEvent.tapIsEnabled(tap: eventTap) ? .active : .disabled
            }
            return false
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            if let tokens = pressedTokensByKeyCode[keyCode], !tokens.isEmpty {
                for token in tokens { entries[token]?.onKeyDown() }
                return true
            }
            guard Self.hasExactFunctionModifier(event.flags) else { return false }
            let matches = entries.filter { $0.value.shortcut.keyCode == keyCode }
            guard !matches.isEmpty else { return false }
            for (token, entry) in matches {
                pressedTokensByKeyCode[keyCode, default: []].insert(token)
                entry.onKeyDown()
            }
            return true
        case .keyUp:
            guard let tokens = pressedTokensByKeyCode.removeValue(forKey: keyCode), !tokens.isEmpty else {
                return false
            }
            for token in tokens { entries[token]?.onKeyUp() }
            return true
        default:
            return false
        }
    }

    private func ensureTap(requestPermission: Bool) -> Result<Void, HotKeyFailure> {
        if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            state = .active
            return .success(())
        }
        if eventTap != nil { stopTap(nextState: .disabled) }
        guard Accessibility.isTrusted else {
            if requestPermission { Accessibility.request() }
            state = .permissionDenied
            return .failure(.permissionDenied)
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: functionEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            state = .unavailable
            return .failure(.failed)
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stopTap(nextState: .disabled)
            return .failure(.failed)
        }
        state = .active
        return .success(())
    }

    private func releaseAllPressedKeys() {
        let tokens = Set(pressedTokensByKeyCode.values.flatMap { $0 })
        pressedTokensByKeyCode.removeAll()
        for token in tokens { entries[token]?.onKeyUp() }
    }

    private func stopTap(nextState: FunctionEventTapState) {
        releaseAllPressedKeys()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        state = nextState
    }
}

private enum RegistrationTransaction {
    static func replace<Reference>(
        current: Reference?,
        registerCandidate: () -> Result<Reference, HotKeyFailure>,
        unregister: (Reference) -> Result<Void, HotKeyFailure>,
        rollbackCandidate: (Reference) -> Void
    ) -> Result<Reference, HotKeyFailure> {
        switch registerCandidate() {
        case .failure(let error):
            return .failure(error)
        case .success(let candidate):
            if let current {
                switch unregister(current) {
                case .success: break
                case .failure(let error):
                    rollbackCandidate(candidate)
                    return .failure(error)
                }
            }
            return .success(candidate)
        }
    }
}

private func carbonHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handle(event)
}

private struct HotKeyPressState {
    private(set) var isPressed = false

    mutating func acceptPress() -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        return true
    }

    mutating func release() {
        isPressed = false
    }

    mutating func reset() {
        isPressed = false
    }
}

private struct HotKeyGenerationState {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    var nextGeneration: UInt64 { generation &+ 1 }

    mutating func activate(_ candidate: UInt64) {
        generation = candidate
        isActive = true
    }

    mutating func invalidate() {
        generation &+= 1
        isActive = false
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isActive && generation == candidate
    }
}

private final class HotKeyManager {
    private enum Reference {
        case carbon(EventHotKeyRef)
        case function(UUID)
    }

    private static var signatureSeed: OSType = 0x51540000
    var onPress: (() -> Void)?
    private var reference: Reference?
    private var handler: EventHandlerRef?
    private var activeShortcut: Shortcut?
    private var nextIdentifier: UInt32 = 1
    private var pressState = HotKeyPressState()
    private var generationState = HotKeyGenerationState()
    private let signature: OSType

    init() {
        Self.signatureSeed &+= 1
        signature = Self.signatureSeed
        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let status = eventTypes.withUnsafeBufferPointer { events in
            InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotKeyCallback,
                events.count,
                events.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &handler
            )
        }
        if status != noErr { handler = nil }
    }

    deinit {
        close()
    }

    var isActive: Bool { reference != nil && generationState.isActive }
    var routingSignature: OSType { signature }

    static func routes(eventSignature: OSType, to managerSignature: OSType) -> Bool {
        eventSignature == managerSignature
    }

    func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, Self.routes(eventSignature: identifier.signature, to: signature) else {
            return OSStatus(eventNotHandledErr)
        }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard pressState.acceptPress() else { return noErr }
            let generation = generationState.generation
            DispatchQueue.main.async { [weak self] in self?.deliverPress(generation: generation) }
            return noErr
        case UInt32(kEventHotKeyReleased):
            pressState.release()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    func replace(with shortcut: Shortcut) -> Result<Void, HotKeyFailure> {
        guard shortcut.isFunctionDigit || handler != nil else { return .failure(.failed) }
        if activeShortcut == shortcut, reference != nil { return .success(()) }

        let candidateGeneration = generationState.nextGeneration

        let result: Result<Reference, HotKeyFailure> = RegistrationTransaction.replace(
            current: reference,
            registerCandidate: { [weak self] in
                guard let self else { return .failure(.failed) }
                return self.register(shortcut, generation: candidateGeneration)
            },
            unregister: { [weak self] reference in
                self?.unregister(reference) ?? .failure(.failed)
            },
            rollbackCandidate: { [weak self] reference in _ = self?.unregister(reference) }
        )

        switch result {
        case .failure(let error): return .failure(error)
        case .success(let newReference):
            reference = newReference
            activeShortcut = shortcut
            pressState.reset()
            generationState.activate(candidateGeneration)
            return .success(())
        }
    }

    func probe(_ shortcut: Shortcut) -> Result<Void, HotKeyFailure> {
        if shortcut.usesFunctionModifier {
            guard shortcut.isFunctionDigit else { return .failure(.failed) }
            return FunctionHotKeyCenter.shared.probe(shortcut)
        }
        switch registerCarbon(shortcut) {
        case .failure(let error): return .failure(error)
        case .success(let candidate):
            return UnregisterEventHotKey(candidate) == noErr ? .success(()) : .failure(.failed)
        }
    }

    func disable() -> Result<Void, HotKeyFailure> {
        guard let reference else {
            pressState.reset()
            generationState.invalidate()
            return .success(())
        }
        guard case .success = unregister(reference) else { return .failure(.failed) }
        self.reference = nil
        activeShortcut = nil
        pressState.reset()
        generationState.invalidate()
        return .success(())
    }

    func rebind(_ shortcut: Shortcut) -> Result<Void, HotKeyFailure> {
        if let reference {
            _ = unregister(reference)
            self.reference = nil
        }
        activeShortcut = nil
        pressState.reset()
        generationState.invalidate()
        return replace(with: shortcut)
    }

    func close() {
        _ = disable()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ shortcut: Shortcut, generation: UInt64) -> Result<Reference, HotKeyFailure> {
        if shortcut.usesFunctionModifier {
            guard shortcut.isFunctionDigit else { return .failure(.failed) }
            return FunctionHotKeyCenter.shared.register(
                shortcut,
                onKeyDown: { [weak self] in self?.handleFunctionKeyDown(generation: generation) },
                onKeyUp: { [weak self] in self?.handleFunctionKeyUp(generation: generation) }
            ).map(Reference.function)
        }
        return registerCarbon(shortcut).map(Reference.carbon)
    }

    private func registerCarbon(_ shortcut: Shortcut) -> Result<EventHotKeyRef, HotKeyFailure> {
        nextIdentifier &+= 1
        var candidate: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: nextIdentifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &candidate
        )
        guard status == noErr, let candidate else {
            return .failure(status == eventHotKeyExistsErr ? .occupied : .failed)
        }
        return .success(candidate)
    }

    private func unregister(_ reference: Reference) -> Result<Void, HotKeyFailure> {
        switch reference {
        case .carbon(let carbonReference):
            return UnregisterEventHotKey(carbonReference) == noErr ? .success(()) : .failure(.failed)
        case .function(let token):
            return FunctionHotKeyCenter.shared.unregister(token)
        }
    }

    private func handleFunctionKeyDown(generation: UInt64) {
        guard generationState.accepts(generation), pressState.acceptPress() else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverPress(generation: generation) }
    }

    private func handleFunctionKeyUp(generation: UInt64) {
        guard generationState.accepts(generation) else { return }
        pressState.release()
    }

    private func deliverPress(generation: UInt64) {
        guard generationState.accepts(generation) else { return }
        onPress?()
    }
}

// MARK: - Conservative two-press state machine

private enum OriginalStateKind: Equatable {
    case hidden
    case minimized
    case visible
    case degraded
    case launched
}

private enum RestoreDecision: Equatable {
    case hideTarget
    case minimizeExactWindow
    case activatePrevious
    case none
}

private enum RestorePlanner {
    static let freshSessionLimit: TimeInterval = 0.8

    static func decide(
        original: OriginalStateKind,
        sameProcess: Bool,
        targetIsFrontmost: Bool,
        targetIsActive: Bool,
        targetIsHidden: Bool,
        foreignAppIsFrontmost: Bool,
        sessionIsFresh: Bool,
        restoredWindowIsMinimized: Bool?
    ) -> RestoreDecision {
        guard sameProcess else { return .none }
        let stillOurs = targetIsFrontmost || targetIsActive || sessionIsFresh || !foreignAppIsFrontmost
        switch original {
        case .hidden, .degraded, .launched, .visible:
            if targetIsHidden { return .none }
            // Second press must hide when this session still owns the toggle.
            // Requiring frontmost alone drops Electron / menu-bar apps and
            // double-presses that arrive before activate() has settled.
            return stillOurs ? .hideTarget : .none
        case .minimized:
            if restoredWindowIsMinimized != false { return .none }
            return stillOurs ? .minimizeExactWindow : .none
        }
    }

    static func shouldRevealAfter(_ decision: RestoreDecision) -> Bool {
        decision == .none
    }
}

private enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 自动路径（fn 探测/注册）每次启动最多弹一次系统授权框，避免疯狂弹窗；
    /// 用户主动点「申请辅助功能权限」走 requestExplicitly()，不受此限。
    private static var didAutoPrompt = false

    static func request() {
        guard !didAutoPrompt else { return }
        didAutoPrompt = true
        requestExplicitly()
    }

    static func requestExplicitly() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windows(for processIdentifier: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func isMinimized(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? Bool
    }

    static func setMinimized(_ minimized: Bool, window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }

    static func raise(_ window: AXUIElement) {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

private enum CapturedState {
    case hidden
    case minimized(AXUIElement)
    case visible
    case degraded
    case launched

    var kind: OriginalStateKind {
        switch self {
        case .hidden: return .hidden
        case .minimized: return .minimized
        case .visible: return .visible
        case .degraded: return .degraded
        case .launched: return .launched
        }
    }
}

private struct ToggleSession {
    let targetProcessIdentifier: pid_t
    let previousProcessIdentifier: pid_t?
    let state: CapturedState
    let createdAt: Date
}

private enum LaunchPolicy {
    static func allowsReveal(isRunning: Bool, launchIfNeeded: Bool) -> Bool {
        isRunning || launchIfNeeded
    }
}

private enum RevealPolicy {
    static func shouldHideImmediately(targetIsFrontmost: Bool, onScreenWindowCount: Int) -> Bool {
        targetIsFrontmost && onScreenWindowCount > 0
    }

    static func shouldReopen(windowCount: Int) -> Bool {
        windowCount == 0
    }
}

private enum WindowPresence {
    static func isUsableWindow(_ info: [String: Any], pid: pid_t) -> Bool {
        let owner: pid_t?
        if let value = info[kCGWindowOwnerPID as String] as? pid_t {
            owner = value
        } else if let number = info[kCGWindowOwnerPID as String] as? NSNumber {
            owner = pid_t(truncating: number)
        } else {
            owner = nil
        }
        guard owner == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return (bounds["Width"] ?? 0) > 64 && (bounds["Height"] ?? 0) > 64
    }

    static func onScreenCount(for pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.filter { isUsableWindow($0, pid: pid) }.count
    }
}

private struct LaunchAttemptState {
    private(set) var isLaunching = false
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        isLaunching = true
        return generation
    }

    mutating func complete(_ candidate: Int) -> Bool {
        guard isLaunching, generation == candidate else { return false }
        isLaunching = false
        return true
    }

    mutating func invalidate(_ candidate: Int? = nil) -> Bool {
        if let candidate, (!isLaunching || generation != candidate) { return false }
        generation &+= 1
        isLaunching = false
        return true
    }
}

private final class ToggleEngine {
    var onStatus: ((String, StatusTone) -> Void)?
    private var session: ToggleSession?
    private var launchAttempt = LaunchAttemptState()
    private var visibilityAttempt = LaunchAttemptState()

    func cancelSession() {
        session = nil
        _ = launchAttempt.invalidate()
        _ = visibilityAttempt.invalidate()
    }

    private func say(_ message: String, _ tone: StatusTone = .info) {
        onStatus?(message, tone)
    }

    func toggle(_ target: TargetApplication, launchIfNeeded: Bool) {
        _ = visibilityAttempt.invalidate()
        guard !launchAttempt.isLaunching else {
            say("目标应用正在启动，请稍候。", .warning)
            return
        }
        if let session {
            self.session = nil
            let decision = restore(target, session: session)
            if !RestorePlanner.shouldRevealAfter(decision) { return }
        }
        reveal(target, launchIfNeeded: launchIfNeeded)
    }

    private func reveal(_ target: TargetApplication, launchIfNeeded: Bool) {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.first {
            $0.bundleIdentifier == target.bundleIdentifier
        }
        guard LaunchPolicy.allowsReveal(isRunning: running != nil, launchIfNeeded: launchIfNeeded) else {
            say("\(target.name) 尚未运行，自动打开已关闭。", .warning)
            return
        }
        guard let running else {
            let resolvedURL = workspace.urlForApplication(withBundleIdentifier: target.bundleIdentifier)
                ?? URL(fileURLWithPath: target.path)
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                say("找不到目标应用，请重新选择。", .error)
                return
            }
            let previous = previousFrontmostProcessIdentifier(excluding: nil)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            let generation = beginLaunch()
            workspace.openApplication(at: resolvedURL, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self, self.launchAttempt.complete(generation) else { return }
                    guard let app, error == nil else {
                        self.say("目标应用启动失败。", .error)
                        return
                    }
                    self.session = ToggleSession(
                        targetProcessIdentifier: app.processIdentifier,
                        previousProcessIdentifier: previous,
                        state: .launched,
                        createdAt: Date()
                    )
                    _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                    self.say("已启动并呼出 \(target.name)。")
                }
            }
            return
        }

        let current = refreshed(running)
        let previous = previousFrontmostProcessIdentifier(excluding: current.processIdentifier)
        let onScreenWindows = WindowPresence.onScreenCount(for: current.processIdentifier)
        if current.isHidden {
            requestVerifiedReveal(current, previous: previous, target: target)
            return
        }

        if RevealPolicy.shouldHideImmediately(
            targetIsFrontmost: appearsFront(current),
            onScreenWindowCount: onScreenWindows
        ) {
            requestVerifiedHide(
                current,
                previous: previous,
                target: target,
                failureMessage: "无法隐藏目标应用。",
                successMessage: "\(target.name) 已在前台，现已安全隐藏；没有关闭窗口。"
            )
            return
        }

        if Accessibility.isTrusted {
            let windows = Accessibility.windows(for: current.processIdentifier)
            if RevealPolicy.shouldReopen(windowCount: windows.count) {
                reopenRunningApplication(current, previous: previous, target: target)
                return
            }
            let minimizedWindows = windows.filter { Accessibility.isMinimized($0) == true }
            let visibleWindowExists = windows.contains { Accessibility.isMinimized($0) == false }
            if !visibleWindowExists, let restoredWindow = minimizedWindows.first {
                guard Accessibility.setMinimized(false, window: restoredWindow) else {
                    reopenRunningApplication(current, previous: previous, target: target)
                    return
                }
                Accessibility.raise(restoredWindow)
                _ = current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                if RevealPolicy.shouldReopen(windowCount: WindowPresence.onScreenCount(for: current.processIdentifier)) {
                    reopenRunningApplication(current, previous: previous, target: target)
                    return
                }
                session = ToggleSession(
                    targetProcessIdentifier: current.processIdentifier,
                    previousProcessIdentifier: previous,
                    state: .minimized(restoredWindow),
                    createdAt: Date()
                )
                say("已恢复一个最小化窗口；再次按键只会重新最小化这个窗口。")
                return
            }
        }

        if RevealPolicy.shouldReopen(windowCount: onScreenWindows) {
            reopenRunningApplication(current, previous: previous, target: target)
            return
        }
        guard current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows]) else {
            say("无法激活目标应用。", .error)
            return
        }
        if RevealPolicy.shouldReopen(windowCount: WindowPresence.onScreenCount(for: current.processIdentifier)) {
            reopenRunningApplication(current, previous: previous, target: target)
            return
        }
        session = ToggleSession(
            targetProcessIdentifier: current.processIdentifier,
            previousProcessIdentifier: previous,
            state: .visible,
            createdAt: Date()
        )
        say("已呼出 \(target.name)；再次按键会安全隐藏。")
    }

    private func requestVerifiedReveal(
        _ running: NSRunningApplication,
        previous: pid_t?,
        target: TargetApplication
    ) {
        let generation = visibilityAttempt.begin()
        _ = running.unhide()
        _ = running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        verifyReveal(
            processIdentifier: running.processIdentifier,
            previous: previous,
            target: target,
            generation: generation,
            retriesRemaining: 1,
            delay: 0.2
        )
    }

    private func verifyReveal(
        processIdentifier: pid_t,
        previous: pid_t?,
        target: TargetApplication,
        generation: Int,
        retriesRemaining: Int,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.visibilityAttempt.isLaunching,
                  self.visibilityAttempt.generation == generation else { return }
            let refreshed = self.verifiedRunningApplication(
                processIdentifier,
                matching: target.bundleIdentifier
            )
            if let refreshed, !refreshed.isHidden, refreshed.isActive {
                guard self.visibilityAttempt.complete(generation) else { return }
                if RevealPolicy.shouldReopen(
                    windowCount: WindowPresence.onScreenCount(for: refreshed.processIdentifier)
                ) {
                    self.reopenRunningApplication(refreshed, previous: previous, target: target)
                    return
                }
                self.session = ToggleSession(
                    targetProcessIdentifier: refreshed.processIdentifier,
                    previousProcessIdentifier: previous,
                    state: .hidden,
                    createdAt: Date()
                )
                self.say("已呼出 \(target.name)；再次按键会恢复隐藏状态。")
                return
            }
            guard retriesRemaining > 0 else {
                guard self.visibilityAttempt.complete(generation) else { return }
                self.say("无法激活目标应用。", .error)
                return
            }
            self.verifyReveal(
                processIdentifier: processIdentifier,
                previous: previous,
                target: target,
                generation: generation,
                retriesRemaining: retriesRemaining - 1,
                delay: 0.6
            )
        }
    }

    private func requestVerifiedHide(
        _ running: NSRunningApplication,
        previous: pid_t?,
        target: TargetApplication,
        failureMessage: String,
        successMessage: String
    ) {
        let generation = visibilityAttempt.begin()
        _ = running.hide()
        verifyHide(
            processIdentifier: running.processIdentifier,
            previous: previous,
            target: target,
            generation: generation,
            retriesRemaining: 1,
            delay: 0.2,
            failureMessage: failureMessage,
            successMessage: successMessage
        )
    }

    private func verifyHide(
        processIdentifier: pid_t,
        previous: pid_t?,
        target: TargetApplication,
        generation: Int,
        retriesRemaining: Int,
        delay: TimeInterval,
        failureMessage: String,
        successMessage: String
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.visibilityAttempt.isLaunching,
                  self.visibilityAttempt.generation == generation else { return }
            let refreshed = self.verifiedRunningApplication(
                processIdentifier,
                matching: target.bundleIdentifier
            )
            if let refreshed, refreshed.isHidden {
                guard self.visibilityAttempt.complete(generation) else { return }
                self.activatePrevious(previous)
                self.say(successMessage)
                return
            }
            guard retriesRemaining > 0 else {
                guard self.visibilityAttempt.complete(generation) else { return }
                self.say(failureMessage, .error)
                return
            }
            self.verifyHide(
                processIdentifier: processIdentifier,
                previous: previous,
                target: target,
                generation: generation,
                retriesRemaining: retriesRemaining - 1,
                delay: 0.6,
                failureMessage: failureMessage,
                successMessage: successMessage
            )
        }
    }

    private func verifiedRunningApplication(
        _ processIdentifier: pid_t,
        matching bundleIdentifier: String
    ) -> NSRunningApplication? {
        guard let refreshed = NSRunningApplication(processIdentifier: processIdentifier),
              !refreshed.isTerminated,
              refreshed.bundleIdentifier == bundleIdentifier else { return nil }
        return refreshed
    }

    private func reopenRunningApplication(
        _ running: NSRunningApplication,
        previous: pid_t?,
        target: TargetApplication
    ) {
        let workspace = NSWorkspace.shared
        let resolvedURL = workspace.urlForApplication(withBundleIdentifier: target.bundleIdentifier)
            ?? URL(fileURLWithPath: target.path)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            say("找不到目标应用，请重新选择。", .error)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let generation = beginLaunch()
        workspace.openApplication(at: resolvedURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self, self.launchAttempt.complete(generation) else { return }
                let reopened = app ?? running
                guard error == nil,
                      reopened.activate(options: [.activateIgnoringOtherApps, .activateAllWindows]) else {
                    self.say("无法重新打开目标应用窗口。", .error)
                    return
                }
                self.session = ToggleSession(
                    targetProcessIdentifier: reopened.processIdentifier,
                    previousProcessIdentifier: previous,
                    state: .degraded,
                    createdAt: Date()
                )
                self.say("已重新打开并呼出 \(target.name)；再次按键将安全隐藏。")
            }
        }
    }

    private func restore(_ target: TargetApplication, session: ToggleSession) -> RestoreDecision {
        let workspace = NSWorkspace.shared
        guard let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == target.bundleIdentifier
        }) else {
            return .none
        }

        let current = refreshed(running)
        let sameProcess = current.processIdentifier == session.targetProcessIdentifier
        let windowMinimized: Bool?
        if case .minimized(let window) = session.state {
            windowMinimized = Accessibility.isMinimized(window)
        } else {
            windowMinimized = nil
        }

        let decision = RestorePlanner.decide(
            original: session.state.kind,
            sameProcess: sameProcess,
            targetIsFrontmost: workspace.frontmostApplication?.processIdentifier == current.processIdentifier,
            targetIsActive: current.isActive,
            targetIsHidden: current.isHidden,
            foreignAppIsFrontmost: foreignRegularAppIsFrontmost(excluding: current.processIdentifier),
            sessionIsFresh: Date().timeIntervalSince(session.createdAt) < RestorePlanner.freshSessionLimit,
            restoredWindowIsMinimized: windowMinimized
        )

        switch decision {
        case .hideTarget:
            requestVerifiedHide(
                current,
                previous: session.previousProcessIdentifier,
                target: target,
                failureMessage: "系统暂时无法隐藏目标应用；没有关闭任何窗口。",
                successMessage: "已恢复按键前状态；没有关闭任何窗口。"
            )
        case .minimizeExactWindow:
            guard case .minimized(let window) = session.state,
                  Accessibility.isTrusted,
                  Accessibility.setMinimized(true, window: window) else {
                say("窗口状态已变化，本次未自动最小化。", .warning)
                return decision
            }
            activatePrevious(session.previousProcessIdentifier)
            say("已只重新最小化本次恢复的窗口。")
        case .activatePrevious:
            activatePrevious(session.previousProcessIdentifier)
            say("目标窗口保持显示，已恢复之前的前台应用。")
        case .none:
            return .none
        }
        return decision
    }

    private func previousFrontmostProcessIdentifier(excluding targetPID: pid_t?) -> pid_t? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              frontmost.processIdentifier != targetPID else { return nil }
        return frontmost.processIdentifier
    }

    private func runningApplication(_ processIdentifier: pid_t) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == processIdentifier }
    }

    private func activatePrevious(_ processIdentifier: pid_t?) {
        guard let processIdentifier, let previous = runningApplication(processIdentifier) else { return }
        _ = previous.activate(options: .activateIgnoringOtherApps)
    }

    private func refreshed(_ running: NSRunningApplication) -> NSRunningApplication {
        NSRunningApplication(processIdentifier: running.processIdentifier) ?? running
    }

    private func appearsFront(_ running: NSRunningApplication) -> Bool {
        running.isActive
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
    }

    private func foreignRegularAppIsFrontmost(excluding targetPID: pid_t) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmost.processIdentifier
        if pid == targetPID { return false }
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        if frontmost.isHidden { return false }
        if frontmost.activationPolicy != .regular { return false }
        return true
    }

    @discardableResult
    private func beginLaunch() -> Int {
        let generation = launchAttempt.begin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.launchAttempt.invalidate(generation) else { return }
            self.say("目标应用启动超时，可再试一次。", .error)
        }
        return generation
    }
}

// MARK: - Update check

private enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(latest: String)
    case failed(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Parses plain release tags like "v1.2.3" or "1.2". Tags with any suffix
/// (windows preview, beta, build metadata) fail closed instead of comparing loosely.
private struct ReleaseVersion: Equatable {
    let components: [Int]

    static func parse(_ raw: String) -> ReleaseVersion? {
        let trimmed = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        return ReleaseVersion(components: numbers)
    }

    /// nil when either side is not a plain version tag and cannot be compared.
    static func isCurrent(_ current: String, behind latestTag: String) -> Bool? {
        guard let currentVersion = parse(current), let latest = parse(latestTag) else { return nil }
        for index in 0..<3 where latest.components[index] != currentVersion.components[index] {
            return latest.components[index] > currentVersion.components[index]
        }
        return false
    }
}

private enum UpdateCheckEndpoints {
    static let latestRelease = URL(string: "https://api.github.com/repos/BLACKIELF/AiGoodChange/releases/latest")!
    static let releasePage = URL(string: "https://github.com/BLACKIELF/AiGoodChange/releases/latest")!
}

private enum UpdateCheckService {
    enum Failure: Error, Equatable {
        case transport(String)
        case status(Int)
        case unreadableTag(String)

        var userDescription: String {
            switch self {
            case .transport(let detail): return detail
            case .status(let code): return "GitHub 返回 HTTP \(code)"
            case .unreadableTag(let tag): return "无法识别版本号 “\(tag)”"
            }
        }
    }

    /// Fetches the newest non-prerelease tag via /releases/latest (which skips
    /// drafts and prereleases). Never called in preview or diagnostic mode;
    /// completion always lands on the main queue.
    struct LatestRelease: Equatable {
        let tag: String
        let notes: String?
    }

    static func fetchLatestTag(completion: @escaping (Result<LatestRelease, Failure>) -> Void) {
        var request = URLRequest(url: UpdateCheckEndpoints.latestRelease, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<LatestRelease, Failure>
            if let urlError = error as? URLError {
                result = .failure(.transport(Self.transportDescription(for: urlError)))
            } else if error != nil {
                result = .failure(.transport("网络错误"))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(.status(http.statusCode))
            } else if let data,
                      let payload = try? JSONDecoder().decode(LatestReleasePayload.self, from: data),
                      !payload.tagName.isEmpty {
                result = .success(LatestRelease(tag: payload.tagName, notes: payload.body))
            } else {
                result = .failure(.transport("响应无法解析"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func transportDescription(for error: URLError) -> String {
        switch error.code {
        case .timedOut: return "请求超时"
        case .notConnectedToInternet, .networkConnectionLost: return "当前没有可用的网络连接"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接 api.github.com"
        default: return "网络错误（\(error.code.rawValue)）"
        }
    }

    private struct LatestReleasePayload: Decodable {
        let tagName: String
        let body: String?

        enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case body }
    }
}

// MARK: - Application model

private final class QuickToggleModel {
    let previewMode: Bool
    var onChange: (() -> Void)?
    var onSettingsHotKey: (() -> Void)?
    private(set) var bindings: [AppBinding]
    private(set) var occupiedHotKeys: [OccupiedHotKeyEntry] = []
    private(set) var shortcutConflictKnowledge: ShortcutConflictKnowledge = [:]
    private(set) var isEnabled: Bool
    private(set) var settingsShortcut: Shortcut
    private(set) var themeIdentifier = "codexu.default"
    private(set) var applicationLayout: ApplicationLayout = .list
    private(set) var statusMessage = "添加应用后，AiGoodChange 会自动分配快捷键。"
    private(set) var statusTone: StatusTone = .info
    private(set) var updateCheckState: UpdateCheckState = .idle
    private(set) var updateCheckNotes: String?
    private var isCheckingForUpdate = false
    private var statusStickyUntil = Date.distantPast
    private var hotKeyRecoveryFailed = false

    private let preferences: PreferenceStore?
    private var hotKeys: [UUID: HotKeyManager] = [:]
    private var engines: [UUID: ToggleEngine] = [:]
    private let settingsHotKey = HotKeyManager()
    private static let defaultSettingsShortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_3),
        modifiers: UInt32(cmdKey),
        label: "3"
    )

    init(diagnosticMode: Bool, previewMode: Bool = false, previewBindings: [AppBinding]? = nil) {
        self.previewMode = previewMode
        if diagnosticMode {
            preferences = nil
            bindings = []
            isEnabled = false
            settingsShortcut = Self.defaultSettingsShortcut
            statusMessage = "诊断模式：未读取或写入用户设置。"
            if previewMode, previewBindings == nil {
                // Read an in-memory copy directly; the migration loader writes defaults.
                let defaults = UserDefaults(suiteName: "com.quicktoggle.app")
                themeIdentifier = defaults?.string(forKey: "quickToggle.themeIdentifier") ?? "codexu.default"
                applicationLayout = ApplicationLayout(rawValue: defaults?.string(forKey: "quickToggle.applicationLayout") ?? "") ?? .list
                if let data = defaults?.data(forKey: "quickToggle.bindings"),
                   let saved = try? JSONDecoder().decode([AppBinding].self, from: data) {
                    bindings = saved
                }
                if let data = defaults?.data(forKey: "quickToggle.occupiedHotKeys"),
                   let saved = try? JSONDecoder().decode([OccupiedHotKeyEntry].self, from: data) {
                    occupiedHotKeys = saved
                }
                if let data = defaults?.data(forKey: "quickToggle.settingsShortcut"),
                   let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
                    settingsShortcut = saved
                }
                statusMessage = "界面预览：使用当前配置的副本，修改仅保留在本次预览。"
            }
            if previewMode, let previewBindings { bindings = previewBindings }
        } else {
            let store = PreferenceStore()
            preferences = store
            themeIdentifier = store.themeIdentifier
            applicationLayout = store.applicationLayout
            bindings = store.loadBindings()
            occupiedHotKeys = store.loadOccupiedHotKeys()
            shortcutConflictKnowledge = store.loadShortcutConflictKnowledge()
            isEnabled = store.enabled
            settingsShortcut = store.settingsShortcut ?? Self.defaultSettingsShortcut
            // Restore a previously found update so the menu keeps showing it
            // even when the next automatic check is still outside its 24h window.
            if let known = store.knownAvailableUpdate {
                updateCheckState = Self.restoredUpdateState(knownTag: known, currentVersion: appVersion)
                if updateCheckState.isAvailable {
                    updateCheckNotes = store.knownAvailableUpdateNotes
                } else {
                    store.knownAvailableUpdate = nil
                    store.knownAvailableUpdateNotes = nil
                }
            }
            importVerifiedLaunchApps()
            importSuggestedToggleApps()
        }

        if !ThemeCatalog.bundled.contains(where: { $0.id == themeIdentifier }) { themeIdentifier = "codexu.default" }
        ThemeCatalog.select(themeIdentifier)
        settingsHotKey.onPress = { [weak self] in self?.onSettingsHotKey?() }

        if isEnabled {
            let result = registerAll()
            if result.failed > 0 {
                applyStatus("已启用 \(result.active) 个快捷键；\(result.failed) 个发生冲突。", tone: .warning)
            } else if result.active > 0 {
                applyStatus("已启用 \(result.active) 个应用快捷键。", tone: .info)
            }
        }

        if !diagnosticMode {
            switch settingsHotKey.replace(with: settingsShortcut) {
            case .success: break
            case .failure(.occupied):
                applyStatus("设置快捷键 \(settingsShortcut.displayName) 已被其他应用占用。", tone: .error)
            case .failure(.permissionDenied):
                applyStatus("设置快捷键 \(settingsShortcut.displayName) 需要辅助功能授权才能监听 fn/🌐。", tone: .error)
            case .failure(.failed):
                applyStatus("系统无法注册设置快捷键 \(settingsShortcut.displayName)。", tone: .error)
            }
        }
    }

    var registeredShortcutCount: Int { hotKeys.values.filter(\.isActive).count }
    func shortcutState(for binding: AppBinding) -> (text: String, color: NSColor) {
        guard binding.shortcut != nil else { return ("待设置", .secondaryLabelColor) }
        if previewMode { return ("预览", .secondaryLabelColor) }
        guard isEnabled else { return ("已暂停", .secondaryLabelColor) }
        return hotKeys[binding.id]?.isActive == true
            ? ("已注册", .systemGreen)
            : ("未注册 · 请检查组合", .systemOrange)
    }

    /// Rows stay single-line (icon＋name｜recorder capsule｜more menu) unless
    /// they have an actionable problem: a target the system can no longer
    /// locate, or a shortcut that failed to register. Normal states stay on
    /// the recorder capsule, the header switch and the status banner.
    func rowStatusAttention(for binding: AppBinding) -> (text: String, color: NSColor)? {
        if !ShortcutProbe.appIsPresent(bundleIdentifier: binding.target.bundleIdentifier, path: binding.target.path) {
            return ("找不到目标应用，请重新选择。", .systemRed)
        }
        let state = shortcutState(for: binding)
        return state.color == .systemOrange ? state : nil
    }
    var diagnosticSummary: String {
        let configured = bindings.filter { $0.shortcut != nil }.count
        let configuredFunction = bindings.filter { $0.shortcut?.isFunctionDigit == true }.count
            + (settingsShortcut.isFunctionDigit ? 1 : 0)
        let registration = isEnabled
            ? "应用热键 \(registeredShortcutCount)/\(configured) 已注册"
            : "应用热键已全部停用"
        let permission = Accessibility.isTrusted ? "辅助功能已授权" : "辅助功能未授权"
        let functionChannel = FunctionHotKeyCenter.shared.diagnosticDescription(
            configuredCount: configuredFunction
        )
        return "\(bindings.count) 个应用 · \(registration) · \(functionChannel) · \(permission)"
    }
    var accessibilityStatus: String {
        Accessibility.isTrusted
            ? "已授权，可恢复最小化窗口并使用 fn 快捷键。"
            : "可选；普通快捷键无需授权。"
    }

    /// Result of a successful add: the binding to reveal in the list, and
    /// whether it was already present (duplicate add).
    struct AddTargetOutcome: Equatable {
        let bindingID: UUID
        let isExisting: Bool
    }

    func addTarget(url: URL) -> AddTargetOutcome? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            reportStatus("所选项目不是有效的 macOS 应用。", tone: .error)
            return nil
        }
        guard identifier != Bundle.main.bundleIdentifier else {
            reportStatus("不能把 AiGoodChange 本身设为目标应用。", tone: .warning)
            return nil
        }
        if let existing = bindings.first(where: { $0.target.bundleIdentifier == identifier }) {
            // Re-selecting a moved app whose stored path is dead: repair the
            // path in place — same binding ID, shortcut and 未运行时打开
            // setting — instead of refusing the add as a duplicate, which
            // would leave a broken target unfixable. Only when the stored
            // path no longer exists on disk.
            if !FileManager.default.fileExists(atPath: existing.target.path),
               existing.target.path != url.path,
               let index = bindings.firstIndex(where: { $0.id == existing.id }) {
                bindings[index].target = TargetApplication(
                    bundleIdentifier: identifier,
                    name: existing.target.name,
                    path: url.path
                )
                saveBindings()
                reportStatus("已把 \(existing.target.name) 重新关联到新位置，原快捷键与设置保持不变。")
                return AddTargetOutcome(bindingID: existing.id, isExisting: true)
            }
            reportStatus("这个应用已经在列表里。", tone: .warning)
            return AddTargetOutcome(bindingID: existing.id, isExisting: true)
        }
        let displayName = ApplicationScanner.displayName(for: url)
        let bindingID = UUID()
        bindings.append(AppBinding(
            id: bindingID,
            target: TargetApplication(
                bundleIdentifier: identifier,
                name: displayName,
                path: url.path
            ),
            shortcut: nil,
            launchIfNeeded: true
        ))
        saveBindings()
        let outcome = AddTargetOutcome(bindingID: bindingID, isExisting: false)
        if identifier != "com.apple.finder", let suggested = nextFreeRecommendedDigit {
            if applyShortcut(suggested, for: bindingID) {
                if previewMode {
                    reportStatus("预览：为 \(displayName) 分配 \(suggested.displayName)，本次预览关闭后不保留。")
                    return outcome
                }
                let message = "已为 \(displayName) 分配 \(suggested.displayName)：按一下呼出，再按一下藏回。点行内按钮可换键。"
                if let warning = shortcutWarning(for: suggested) {
                    reportStatus(message + " " + warning, tone: .warning)
                } else {
                    reportStatus(message)
                }
                return outcome
            }
            return outcome
        }
        reportStatus("已添加 \(displayName)，请为它录制快捷键。")
        return outcome
    }

    /// The hotkey callback resolves this stable binding ID at press time.
    /// Keep its registration; discard only the old target's restore session.
    @discardableResult
    func replaceTarget(for bindingID: UUID, with url: URL) -> Bool {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else {
            reportStatus("原应用已不在列表里，请重新选择要更换的行。", tone: .warning)
            return false
        }
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              !identifier.isEmpty else {
            reportStatus("所选项目不是有效的 macOS 应用，原绑定未改变。", tone: .error)
            return false
        }
        guard !Self.ownBundleIdentifiers.contains(identifier) else {
            reportStatus("不能把 AiGoodChange 本身设为目标应用，原绑定未改变。", tone: .warning)
            return false
        }
        if let existing = bindings.first(where: { $0.id != bindingID && $0.target.bundleIdentifier == identifier }) {
            reportStatus("\(existing.target.name) 已在另一行，原绑定未改变。", tone: .warning)
            return false
        }
        let original = bindings[index]
        let name = ApplicationScanner.displayName(for: url)
        engines.removeValue(forKey: bindingID)?.cancelSession()
        bindings[index].target = TargetApplication(bundleIdentifier: identifier, name: name, path: url.path)
        saveBindings()
        let retained = original.shortcut.map { "快捷键仍是 \($0.displayName)" } ?? "仍未设置快捷键"
        reportStatus("已将 \(original.target.name) 更换为 \(name)，\(retained)。")
        return true
    }

    static var ownBundleIdentifiers: Set<String> {
        Set(["com.quicktoggle.app", "com.quicktoggle.preview", Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    func selectTheme(_ identifier: String) {
        guard ThemeCatalog.bundled.contains(where: { $0.id == identifier }) else { return }
        guard themeIdentifier != identifier || ThemeCatalog.selectedID != identifier else { return }
        themeIdentifier = identifier
        preferences?.themeIdentifier = identifier
        ThemeCatalog.select(identifier)
        onChange?()
    }

    func selectApplicationLayout(_ layout: ApplicationLayout) {
        guard applicationLayout != layout else { return }
        applicationLayout = layout
        preferences?.applicationLayout = layout
        onChange?()
    }

    var nextFreeRecommendedDigit: Shortcut? {
        ShortcutSuggester.nextFreeRecommendedDigit(
            bindings: bindings,
            occupied: occupiedHotKeys,
            settingsShortcut: settingsShortcut
        )
    }

    func applyShortcut(_ candidate: Shortcut, for bindingID: UUID) -> Bool {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return false }
        let binding = bindings[index]
        let preservedShortcut = binding.shortcut == nil
            ? "请改用其他组合。"
            : "原快捷键仍然有效。"
        switch ShortcutProbe.inspect(
            candidate,
            appName: binding.target.name,
            bundleIdentifier: binding.target.bundleIdentifier,
            path: binding.target.path,
            bindings: bindings,
            excluding: bindingID,
            asSettings: false,
            occupied: occupiedHotKeys
        ) {
        case .invalid(let error):
            reportStatus(error, tone: .error)
            return false
        case .missingApp(let name):
            reportStatus("已探测：找不到 \(name)。未改键。", tone: .error)
            return false
        case .usedByQuickToggle:
            reportStatus("已探测：该组合已用于 AiGoodChange 其他应用。\(preservedShortcut)", tone: .warning)
            return false
        case .occupiedLocally(let owner):
            reportStatus("已探测：占用（\(owner)）。\(preservedShortcut)", tone: .warning)
            return false
        case .ready:
            break
        }

        if previewMode {
            bindings[index].shortcut = candidate
            reportStatus("预览：\(binding.target.name) → \(candidate.displayName)，没有注册或保存到当前配置。")
            return true
        }
        let manager = hotKeyManager(for: bindingID)
        let result = isEnabled ? manager.replace(with: candidate) : manager.probe(candidate)
        switch result {
        case .failure(.occupied):
            reportStatus("已探测：系统占用。\(preservedShortcut)", tone: .warning)
            return false
        case .failure(.permissionDenied):
            reportStatus("fn/🌐 热键需要“辅助功能”授权；完成授权后请重新录制。\(preservedShortcut)", tone: .error)
            return false
        case .failure(.failed):
            reportStatus(
                candidate.isFunctionDigit
                    ? "已探测：系统无法建立 fn/🌐 事件监听。\(preservedShortcut)"
                    : "已探测：系统无法注册该组合。\(preservedShortcut)",
                tone: .error
            )
            return false
        case .success:
            bindings[index].shortcut = candidate
            saveBindings()
            if let warning = shortcutWarning(for: candidate) {
                reportStatus("已探测：空闲。\(warning)", tone: .warning)
            } else {
                reportStatus(
                    isEnabled
                        ? "已探测：空闲。\(bindings[index].target.name) \(candidate.displayName) 已立即生效。"
                        : "已探测：空闲。快捷键已保存，当前全部停用。"
                )
            }
            return true
        }
    }

    func applySettingsShortcut(_ candidate: Shortcut) -> Bool {
        switch ShortcutProbe.inspect(
            candidate,
            bindings: bindings,
            excluding: UUID(),
            asSettings: true,
            occupied: occupiedHotKeys
        ) {
        case .invalid(let error):
            reportStatus(error, tone: .error)
            return false
        case .missingApp:
            reportStatus("已探测：找不到设置窗口。未改键。", tone: .error)
            return false
        case .usedByQuickToggle:
            reportStatus("已探测：该组合已用于应用快捷键。原设置快捷键仍然有效。", tone: .warning)
            return false
        case .occupiedLocally(let owner):
            reportStatus("已探测：占用（\(owner)）。原设置快捷键仍然有效。", tone: .warning)
            return false
        case .ready:
            break
        }

        if previewMode {
            settingsShortcut = candidate
            reportStatus("预览：打开 AiGoodChange 的快捷键改为 \(candidate.displayName)。")
            return true
        }
        switch settingsHotKey.replace(with: candidate) {
        case .failure(.occupied):
            reportStatus("已探测：系统占用。原设置快捷键仍然有效。", tone: .warning)
            return false
        case .failure(.permissionDenied):
            reportStatus("fn/🌐 热键需要“辅助功能”授权；系统已提示授权，完成后请重新录制。原设置快捷键仍然有效。", tone: .error)
            return false
        case .failure(.failed):
            reportStatus(
                candidate.isFunctionDigit
                    ? "已探测：系统无法建立 fn/🌐 事件监听。原设置快捷键仍然有效。"
                    : "已探测：系统无法注册该组合。原设置快捷键仍然有效。",
                tone: .error
            )
            return false
        case .success:
            settingsShortcut = candidate
            preferences?.settingsShortcut = candidate
            if let warning = candidate.riskWarning {
                reportStatus("已探测：空闲。\(warning)", tone: .warning)
            } else {
                reportStatus("已探测：空闲。设置窗口快捷键已改为 \(candidate.displayName)，保存并立即生效。")
            }
            return true
        }
    }

    func clearShortcut(for bindingID: UUID) -> Bool {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return false }
        if let manager = hotKeys[bindingID], manager.isActive, case .failure = manager.disable() {
            reportStatus("系统无法停用当前快捷键，原快捷键仍然有效。", tone: .error)
            return false
        }
        bindings[index].shortcut = nil
        saveBindings()
        reportStatus("已清除 \(bindings[index].target.name) 的快捷键。")
        return true
    }

    func conflictWarning(for shortcut: Shortcut) -> String? {
        ShortcutConflictKnowledgeBase.warning(for: shortcut, in: shortcutConflictKnowledge)
    }

    private func shortcutWarning(for shortcut: Shortcut) -> String? {
        let warnings = [shortcut.riskWarning, conflictWarning(for: shortcut)].compactMap { $0 }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    func toggleLaunchIfNeeded(for bindingID: UUID) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        bindings[index].launchIfNeeded.toggle()
        saveBindings()
        reportStatus(
            bindings[index].launchIfNeeded
                ? "\(bindings[index].target.name) 未运行时将自动打开。"
                : "已关闭自动打开；\(bindings[index].target.name) 未运行时不会启动。"
        )
    }

    func removeBinding(_ bindingID: UUID) {
        guard let index = bindings.firstIndex(where: { $0.id == bindingID }) else { return }
        let name = bindings[index].target.name
        hotKeys.removeValue(forKey: bindingID)?.close()
        engines.removeValue(forKey: bindingID)?.cancelSession()
        bindings.remove(at: index)
        saveBindings()
        reportStatus("已移除 \(name)。")
    }

    func toggleEnabled() {
        if previewMode {
            isEnabled.toggle()
            reportStatus("预览：\(isEnabled ? "启用" : "暂停")界面状态，实际快捷键保持不变。")
            return
        }
        if isEnabled {
            for manager in hotKeys.values where manager.isActive {
                guard case .success = manager.disable() else {
                    _ = registerAll()
                    reportStatus("系统无法完整停用快捷键，已恢复原状态。", tone: .error)
                    return
                }
            }
            isEnabled = false
            preferences?.enabled = false
            engines.values.forEach { $0.cancelSession() }
            reportStatus("所有应用快捷键已停用；\(settingsShortcut.displayName) 仍可显示或隐藏设置。")
            return
        }

        isEnabled = true
        preferences?.enabled = true
        let result = registerAll()
        if result.failed > 0 {
            reportStatus("已启用 \(result.active) 个快捷键；\(result.failed) 个冲突项保持停用。", tone: .warning)
        } else if result.active > 0 {
            reportStatus("已启用 \(result.active) 个应用快捷键。")
        } else {
            reportStatus("尚未录制应用快捷键。")
        }
    }

    func requestAccessibility() {
        guard !previewMode else { return }
        Accessibility.requestExplicitly()
        reportStatus("已请求辅助功能权限；授权后可精确恢复窗口并使用 fn/🌐 热键，返回 AiGoodChange 即可刷新状态。")
    }

    var loginAtLaunchEnabled: Bool { LoginAtLaunch.status.isOn }

    var loginAtLaunchHelp: String { LoginAtLaunch.status.helpText }

    func setLoginAtLaunch(_ enabled: Bool) {
        guard !previewMode else { return }
        let (status, error) = LoginAtLaunch.setEnabled(enabled)
        if let error {
            reportStatus(error, tone: .warning)
            return
        }
        reportStatus(
            status.isOn
                ? "已打开登录时启动；下次登录会自动运行 AiGoodChange。"
                : "已关闭登录时启动。"
        )
    }

    func close() {
        hotKeys.values.forEach { $0.close() }
        engines.values.forEach { $0.cancelSession() }
        settingsHotKey.close()
    }

    private func importVerifiedLaunchApps() {
        guard let preferences else { return }
        var imported = Set(preferences.importedVerifiedLaunchIDs)
        var added: [String] = []
        var occupied: [String] = []
        var conflictWarnings: [String] = []
        for item in VerifiedLaunchHotKeys.all {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            if bindings.contains(where: { $0.target.bundleIdentifier == item.bundleIdentifier }) {
                imported.insert(item.bundleIdentifier)
                continue
            }
            if imported.contains(item.bundleIdentifier) { continue }
            guard addTarget(url: url) != nil else { continue }
            imported.insert(item.bundleIdentifier)
            added.append(item.name)
            guard let bindingID = bindings.first(where: { $0.target.bundleIdentifier == item.bundleIdentifier })?.id else {
                continue
            }
            if !applyShortcut(item.shortcut, for: bindingID) {
                occupied.append("\(item.name) \(item.shortcut.displayName)")
            } else if let warning = conflictWarning(for: item.shortcut) {
                conflictWarnings.append(warning)
            }
        }
        preferences.importedVerifiedLaunchIDs = Array(imported).sorted()
        if added.isEmpty { return }
        if occupied.isEmpty && conflictWarnings.isEmpty {
            applyStatus("已加入 \(added.joined(separator: "、"))，可在本行直接修改快捷键。", tone: .info)
        } else {
            var details: [String] = []
            if !occupied.isEmpty {
                details.append("\(occupied.joined(separator: "、")) 正被应用自己占用，点右侧改成其他组合后立即由 AiGoodChange 接管。")
            }
            details.append(contentsOf: conflictWarnings)
            applyStatus("已加入 \(added.joined(separator: "、"))。" + details.joined(separator: " "), tone: .warning)
        }
    }

    private func importSuggestedToggleApps() {
        guard let preferences else { return }
        var imported = Set(preferences.importedSuggestedAppIDs)
        var added: [String] = []
        var occupied: [String] = []
        var conflictWarnings: [String] = []
        for item in SuggestedToggleApps.all {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            if bindings.contains(where: { $0.target.bundleIdentifier == item.bundleIdentifier }) {
                imported.insert(item.bundleIdentifier)
                continue
            }
            if imported.contains(item.bundleIdentifier) { continue }
            guard addTarget(url: url) != nil else { continue }
            imported.insert(item.bundleIdentifier)
            added.append("\(item.name) \(item.shortcut.displayName)")
            guard let bindingID = bindings.first(where: { $0.target.bundleIdentifier == item.bundleIdentifier })?.id else {
                continue
            }
            if !applyShortcut(item.shortcut, for: bindingID) {
                occupied.append("\(item.name) \(item.shortcut.displayName)")
            } else if let warning = conflictWarning(for: item.shortcut) {
                conflictWarnings.append(warning)
            }
        }
        preferences.importedSuggestedAppIDs = Array(imported).sorted()
        if added.isEmpty { return }
        if occupied.isEmpty && conflictWarnings.isEmpty {
            applyStatus("已加入 \(added.joined(separator: "、"))，保存并立即生效。", tone: .info)
        } else {
            var details: [String] = []
            if !occupied.isEmpty {
                details.append("\(occupied.joined(separator: "、")) 被占用，请在本行改成其他组合。")
            }
            details.append(contentsOf: conflictWarnings)
            applyStatus("已加入应用。" + details.joined(separator: " "), tone: .warning)
        }
    }

    func addOccupiedHotKey(name: String, shortcut: Shortcut) -> Bool {
        guard let preferences else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reportStatus("请先填写占用方名称。", tone: .error)
            return false
        }
        if OccupiedHotKeys.owner(of: shortcut, in: occupiedHotKeys) != nil {
            reportStatus("该组合已在占用列表中。", tone: .warning)
            return false
        }
        if bindings.contains(where: { $0.shortcut == shortcut }) {
            reportStatus("该组合已是 AiGoodChange 的热键，无需再标记占用。", tone: .warning)
            return false
        }
        occupiedHotKeys.append(OccupiedHotKeyEntry(name: trimmed, shortcut: shortcut))
        preferences.saveOccupiedHotKeys(occupiedHotKeys)
        reportStatus("已记录本机占用：\(trimmed) \(shortcut.displayName)。录制时会避开它。")
        return true
    }

    func removeOccupiedHotKey(_ entry: OccupiedHotKeyEntry) {
        guard let preferences else { return }
        occupiedHotKeys.removeAll { $0 == entry }
        preferences.saveOccupiedHotKeys(occupiedHotKeys)
        reportStatus("已移除占用记录：\(entry.name) \(entry.shortcut.displayName)。")
    }

    func exportConfiguration() -> ConfigurationExchange.Payload {
        ConfigurationExchange.makePayload(
            bindings: bindings,
            settingsShortcut: settingsShortcut,
            enabled: isEnabled,
            launchIfNeeded: preferences?.launchIfNeeded ?? true,
            importedVerifiedLaunchIDs: preferences?.importedVerifiedLaunchIDs ?? [],
            importedSuggestedAppIDs: preferences?.importedSuggestedAppIDs ?? [],
            occupiedHotKeys: occupiedHotKeys
        )
    }

    func importableBindings(in payload: ConfigurationExchange.Payload) -> (importable: [AppBinding], missing: [String]) {
        ConfigurationExchange.partitionImportable(payload.bindings)
    }

    func applyImportedConfiguration(_ payload: ConfigurationExchange.Payload) -> Bool {
        guard let preferences else { return false }
        let (importable, missing) = ConfigurationExchange.partitionImportable(payload.bindings)
        guard !importable.isEmpty else { return false }

        hotKeys.values.forEach { $0.close() }
        hotKeys.removeAll()
        engines.values.forEach { $0.cancelSession() }
        engines.removeAll()

        bindings = importable
        occupiedHotKeys = payload.occupiedHotKeys
        preferences.saveBindings(bindings)
        preferences.saveOccupiedHotKeys(occupiedHotKeys)
        preferences.launchIfNeeded = payload.launchIfNeeded
        preferences.importedVerifiedLaunchIDs = payload.importedVerifiedLaunchIDs
        preferences.importedSuggestedAppIDs = payload.importedSuggestedAppIDs

        if payload.enabled != isEnabled {
            preferences.enabled = payload.enabled
            isEnabled = payload.enabled
        }

        if let shortcut = payload.settingsShortcut,
           case .success = settingsHotKey.replace(with: shortcut) {
            settingsShortcut = shortcut
            preferences.settingsShortcut = shortcut
        }

        var message = "已导入 \(importable.count) 条绑定"
        if !missing.isEmpty {
            message += "；跳过缺失应用：\(missing.joined(separator: "、"))"
        }
        if isEnabled {
            let result = registerAll()
            if result.failed > 0 {
                reportStatus(message + "；\(result.failed) 个快捷键冲突未注册。", tone: .warning)
            } else {
                reportStatus(message + "，\(result.active) 个快捷键已生效。")
            }
        } else {
            reportStatus(message + "；快捷键当前全部停用，可在菜单栏或设置中启用。")
        }
        return true
    }

    func recoverHotKeys() {
        guard preferences != nil else { return }
        var failed = 0
        if case .failure = settingsHotKey.rebind(settingsShortcut) { failed += 1 }
        if isEnabled {
            failed += rebindAll().failed
        }
        if failed > 0 {
            hotKeyRecoveryFailed = true
            reportStatus("快捷键注册已失效，已尝试恢复；仍有 \(failed) 个未成功。", tone: .error)
        } else if hotKeyRecoveryFailed {
            hotKeyRecoveryFailed = false
            reportStatus("快捷键已重新注册。")
        }
    }

    // MARK: Update check

    var dailyUpdateCheckEnabled: Bool { preferences?.dailyUpdateCheckEnabled ?? true }
    var isUpdateCheckInProgress: Bool { isCheckingForUpdate }
    var isUpdateAvailable: Bool { updateCheckState.isAvailable }

    var updateCheckSummary: String {
        let current = "当前版本 v\(appVersion)"
        switch updateCheckState {
        case .idle:
            if let last = preferences?.lastUpdateCheckDate {
                return "\(current) · 上次检查 \(Self.updateCheckTimeDescription(last))"
            }
            return "\(current) · 尚未检查过更新"
        case .checking:
            return "\(current) · 正在检查…"
        case .upToDate:
            return "\(current) · 已是最新"
        case .available(let latest):
            return "发现新版本 \(latest)（当前 v\(appVersion)），点“查看发行页”了解更新内容。"
        case .failed(let reason):
            return "\(current) · 检查失败：\(reason)。可稍后重试或手动再查。"
        }
    }

    func setDailyUpdateCheck(_ enabled: Bool) {
        preferences?.dailyUpdateCheckEnabled = enabled
        reportStatus(enabled
            ? "已打开每日更新检查：启动后和运行期间每 24 小时静默检查一次，只读发行版本号，不上传数据。"
            : "已关闭自动检查；仍可随时手动点“检查更新”。")
        if enabled { checkForUpdateIfDue() }
    }

    func checkForUpdate(userInitiated: Bool) {
        guard preferences != nil else {
            if userInitiated {
                reportStatus(previewMode ? "预览：不联网检查更新。" : "诊断模式：不联网检查更新。")
            }
            return
        }
        guard !isCheckingForUpdate else { return }
        beginUpdateCheck()
        preferences?.lastUpdateCheckDate = Date()
        if userInitiated {
            reportStatus("正在检查更新…")
        } else {
            onChange?()
        }
        UpdateCheckService.fetchLatestTag { [weak self] result in
            self?.completeUpdateCheck(result, userInitiated: userInitiated)
        }
    }

    fileprivate func beginUpdateCheck() {
        isCheckingForUpdate = true
        // The separate progress flag drives the button without erasing known releases.
        if !updateCheckState.isAvailable { updateCheckState = .checking }
    }

    fileprivate func completeUpdateCheck(_ result: Result<UpdateCheckService.LatestRelease, UpdateCheckService.Failure>, userInitiated: Bool) {
        isCheckingForUpdate = false
        switch result {
        case .failure(let failure):
            if !updateCheckState.isAvailable { updateCheckState = .failed(reason: failure.userDescription) }
            if userInitiated { reportStatus("检查更新失败：\(failure.userDescription)。", tone: .warning) }
        case .success(let release):
            applyUpdateTag(release, userInitiated: userInitiated)
        }
        onChange?()
    }

    func checkForUpdateIfDue() {
        guard preferences?.dailyUpdateCheckEnabled == true else { return }
        if let last = preferences?.lastUpdateCheckDate,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        checkForUpdate(userInitiated: false)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(UpdateCheckEndpoints.releasePage)
    }

    private func applyUpdateTag(_ release: UpdateCheckService.LatestRelease, userInitiated: Bool) {
        let tag = String(release.tag.prefix(32))
        switch ReleaseVersion.isCurrent(appVersion, behind: tag) {
        case .some(true):
            updateCheckState = .available(latest: tag)
            updateCheckNotes = Self.sanitizedUpdateNotes(release.notes)
            preferences?.knownAvailableUpdate = tag
            preferences?.knownAvailableUpdateNotes = updateCheckNotes
            reportStatus("发现新版本 \(tag)，当前 v\(appVersion)。可在菜单栏或“设置与帮助”里打开发行页。")
        case .some(false):
            updateCheckState = .upToDate
            updateCheckNotes = nil
            preferences?.knownAvailableUpdate = nil
            preferences?.knownAvailableUpdateNotes = nil
            if userInitiated {
                reportStatus("已是最新版本 v\(appVersion)。")
            }
        case .none:
            if !updateCheckState.isAvailable {
                updateCheckState = .failed(reason: "无法识别版本号 “\(tag)”")
            }
            if userInitiated {
                reportStatus("检查完成，但无法识别发行版本 “\(tag)”，请到发行页确认。", tone: .warning)
            }
        }
    }

    /// Collapses release body markdown into a single teaser line; nil when
    /// nothing readable remains.
    static func sanitizedUpdateNotes(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw
            .replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == "#" || $0 == "*" || $0 == "-" })
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let notes = lines.joined(separator: " / ")
        return notes.count > 200 ? notes.prefix(200) + "…" : notes
    }

    /// Returns the state to restore from a persisted known-update tag.
    static func restoredUpdateState(knownTag: String?, currentVersion: String) -> UpdateCheckState {
        guard let knownTag,
              ReleaseVersion.isCurrent(currentVersion, behind: knownTag) == true else { return .idle }
        return .available(latest: knownTag)
    }

    private static let updateCheckTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func updateCheckTimeDescription(_ date: Date) -> String {
        updateCheckTimeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func reportStatus(_ message: String, tone: StatusTone = .info) {
        let displayed = previewMode && !message.hasPrefix("预览") ? "预览：" + message : message
        applyStatus(displayed, tone: tone, preserveStickyFailure: false)
        onChange?()
    }

    /// Appends context to the current banner without changing its tone —
    /// used when the list view adjusts a filter to reveal a row.
    func appendStatusDetail(_ detail: String) {
        statusMessage = "\(statusMessage) \(detail)"
        onChange?()
    }

    private func applyStatus(
        _ message: String,
        tone: StatusTone,
        preserveStickyFailure: Bool = false
    ) {
        if preserveStickyFailure,
           StatusPolicy.shouldKeepCurrent(
            current: statusTone,
            incoming: tone,
            stickyUntil: statusStickyUntil
           ) {
            return
        }
        statusMessage = message
        statusTone = tone
        statusStickyUntil = tone == .info
            ? .distantPast
            : Date().addingTimeInterval(StatusPolicy.stickyDuration)
    }

    private func saveBindings() {
        preferences?.saveBindings(bindings)
    }

    private func hotKeyManager(for bindingID: UUID) -> HotKeyManager {
        if let manager = hotKeys[bindingID] { return manager }
        let manager = HotKeyManager()
        manager.onPress = { [weak self] in self?.handleHotKey(bindingID) }
        hotKeys[bindingID] = manager
        return manager
    }

    private func toggleEngine(for bindingID: UUID) -> ToggleEngine {
        if let engine = engines[bindingID] { return engine }
        let engine = ToggleEngine()
        engine.onStatus = { [weak self] message, tone in
            self?.applyStatus(message, tone: tone, preserveStickyFailure: tone == .info)
            self?.onChange?()
        }
        engines[bindingID] = engine
        return engine
    }

    private func registerAll() -> (active: Int, failed: Int) {
        var active = 0
        var failed = 0
        for binding in bindings {
            guard let shortcut = binding.shortcut else { continue }
            switch hotKeyManager(for: binding.id).replace(with: shortcut) {
            case .success: active += 1
            case .failure: failed += 1
            }
        }
        return (active, failed)
    }

    private func rebindAll() -> (active: Int, failed: Int) {
        var active = 0
        var failed = 0
        for binding in bindings {
            guard let shortcut = binding.shortcut else { continue }
            switch hotKeyManager(for: binding.id).rebind(shortcut) {
            case .success: active += 1
            case .failure: failed += 1
            }
        }
        return (active, failed)
    }

    fileprivate func handleHotKey(_ bindingID: UUID) {
        guard let binding = bindings.first(where: { $0.id == bindingID }) else { return }
        guard !previewMode else {
            reportStatus("预览：已点选 \(binding.target.name)。实际呼出与恢复在正式候选中验证。")
            return
        }
        toggleEngine(for: bindingID).toggle(
            binding.target,
            launchIfNeeded: binding.launchIfNeeded
        )
    }
}

// MARK: - Shortcut recorder

private final class ShortcutRecorderButton: GlassActionButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var onRecord: ((Shortcut) -> Bool)?
    var onClear: (() -> Bool)?
    var onInvalid: ((String) -> Void)?

    private var isRecording = false
    private var monitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "未设置"
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        controlSize = .large
        font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        bezelColor = NSColor(name: nil) { appearance in
            VisualPalette.isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.085)
                : NSColor.white.withAlphaComponent(0.52)
        }
        contentTintColor = nil
        target = self
        action = #selector(beginRecording)
        focusRingType = .default
        setAccessibilityLabel("全局快捷键录制")
        setAccessibilityHelp("按下按钮后输入组合键；Esc 取消，Delete 或 Backspace 清除。")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    deinit { removeMonitor() }

    static func shouldCapture(isRecording: Bool, windowIsKey: Bool) -> Bool {
        isRecording && windowIsKey
    }

    @objc private func beginRecording() {
        guard let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        emphasized = true
        title = "请按组合键…"
        removeMonitor()
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.finish()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.shouldCapture(
                isRecording: self.isRecording,
                windowIsKey: self.window?.isKeyWindow == true
            ) else { return event }
            self.handle(event)
            return nil
        }
        updateAccessibilityState()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { finish() }
        return result
    }

    private func handle(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape) {
            finish()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            if onClear?() == true { shortcut = nil }
            finish()
            return
        }
        guard let candidate = Shortcut.from(event: event) else {
            onInvalid?("请选择字母、数字、方向键或 F1–F12。")
            NSSound.beep()
            return
        }
        guard onRecord?(candidate) == true else {
            NSSound.beep()
            finish()
            return
        }
        shortcut = candidate
        finish()
    }

    private func finish() {
        isRecording = false
        emphasized = false
        removeMonitor()
        updateTitle()
        updateAccessibilityState()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    private func updateTitle() {
        title = isRecording ? "请按组合键…" : shortcut?.displayName ?? "未设置"
        setAccessibilityValue(title)
    }

    private func updateAccessibilityState() {
        if isRecording {
            setAccessibilityValue("正在录制，请按组合键")
            setAccessibilityHelp("输入组合键；Esc 取消，Delete 或 Backspace 清除。切换到其他窗口会自动取消。")
        } else {
            setAccessibilityValue(shortcut?.displayName ?? "未设置")
            setAccessibilityHelp("按下按钮后输入组合键；Esc 取消，Delete 或 Backspace 清除。")
        }
    }
}

// MARK: - Native single-page settings

private final class GlassCardView: NSBox {
    private var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 12
        borderWidth = 1
        updateColors()
        displayOptionsObserver = observeAccessibilityDisplayOptions { [weak self] in
            self?.updateColors()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        fillColor = .clear
        borderColor = .clear
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        VisualPalette.drawSurface(in: bounds, radius: cornerRadius, dark: VisualPalette.isDark(effectiveAppearance))
    }
}

private final class StatusDotView: NSView {
    var color = NSColor.systemOrange { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

private final class BindingActionRow: NSBox {
    var isCard = false
    var onPress: (() -> Void)?
    var onRequestDelete: (() -> Void)?
    var onArrow: ((Bool) -> Void)?
    var onHorizontalArrow: ((Bool) -> Void)?
    /// The row's recorder control, so focus can be re-anchored to it after a
    /// rebuild replaces all rows.
    fileprivate weak var recorderButton: ShortcutRecorderButton?
    /// The row's conditional second line (missing target / unregistered), so
    /// the controller can refresh it in place while the row is reused.
    fileprivate var statusLine: NSTextField?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var keyboardFocused = false
    private(set) var isFlashing = false
    private var flashWork: DispatchWorkItem?
    private var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayOptionsObserver = observeAccessibilityDisplayOptions { [weak self] in
            self?.updateRowColors()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    /// Draws attention to a row that was just added (or located after a
    /// duplicate add): accent border and fill for a moment, then back to
    /// normal. Purely visual — never triggers the row's activate action.
    func flashNewlyAdded() {
        flashWork?.cancel()
        isFlashing = true
        updateRowColors()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFlashing else { return }
            self.isFlashing = false
            self.flashWork = nil
            self.updateRowColors()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateRowColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateRowColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRowColors()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { keyboardFocused = true }
        updateRowColors()
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { keyboardFocused = false }
        updateRowColors()
        return accepted
    }
    fileprivate func updateRowColors() {
        let dark = VisualPalette.isDark(effectiveAppearance)
        borderColor = keyboardFocused || isFlashing ? VisualPalette.primary(dark) : .clear
        if isFlashing {
            fillColor = VisualPalette.selectionFill(dark)
        } else {
            fillColor = hovered ? VisualPalette.foreground(dark).withAlphaComponent(0.07) : .clear
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isCard {
            VisualPalette.drawSurface(in: bounds, radius: 12, dark: VisualPalette.isDark(effectiveAppearance))
        }
        super.draw(dirtyRect)
        guard !isCard else { return }
        let dark = VisualPalette.isDark(effectiveAppearance)
        VisualPalette.foreground(dark).withAlphaComponent(VisualPalette.increasedContrast() ? 0.30 : 0.07).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 54, y: 0.5))
        line.line(to: NSPoint(x: max(54, bounds.width - 10), y: 0.5))
        line.lineWidth = 0.5
        line.stroke()
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            // Embedded controls keep their own click and recording behavior.
            if view is NSButton { return hit }
            if let text = view as? NSTextField, text.isEditable || text.isSelectable { return hit }
            ancestor = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        window?.makeFirstResponder(self)
        onPress?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isActivateKey = [UInt16(kVK_Space), UInt16(kVK_Return)].contains(event.keyCode)
        let isDeleteKey = [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode)
        let isArrowKey = [UInt16(kVK_UpArrow), UInt16(kVK_DownArrow)].contains(event.keyCode)
        if modifiers.isEmpty && isActivateKey {
            if !event.isARepeat { onPress?() }
        } else if modifiers.isEmpty && isDeleteKey, onRequestDelete != nil, !event.isARepeat {
            onRequestDelete?()
        } else if modifiers.isEmpty && isArrowKey, onArrow != nil, !event.isARepeat {
            onArrow?(event.keyCode == UInt16(kVK_DownArrow))
        } else if modifiers.isEmpty && [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow)].contains(event.keyCode),
                  let onHorizontalArrow, !event.isARepeat {
            onHorizontalArrow(event.keyCode == UInt16(kVK_RightArrow))
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private enum ApplicationListScope: Int {
    case all, needsShortcut, occupied
}

private enum ApplicationListFilter {
    static func rows(bindings: [AppBinding], occupied: [OccupiedHotKeyEntry], scope: ApplicationListScope, query: String) -> [QuickToggleRow] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let rows: [QuickToggleRow]
        switch scope {
        case .all: rows = bindings.map(QuickToggleRow.binding)
        case .needsShortcut: rows = bindings.filter { $0.shortcut == nil }.map(QuickToggleRow.binding)
        case .occupied: rows = occupied.map(QuickToggleRow.occupied)
        }
        return BindingOrder.sorted(rows).filter { row in
            let searchable: String
            switch row {
            case .binding(let binding):
                searchable = [binding.target.name, binding.shortcut?.displayName ?? "未设置"].joined(separator: " ")
            case .occupied(let entry):
                searchable = entry.name + " " + entry.shortcut.displayName
            }
            return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }
}

private final class QuickToggleWindow: NSWindow {
    var onFind: (() -> Void)?
    var onAdd: (() -> Void)?
    var onPreferences: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if sheetParent != nil { performClose(sender) } else { super.cancelOperation(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_F where onFind != nil: onFind?(); return true
        case kVK_ANSI_N where onAdd != nil: onAdd?(); return true
        case kVK_ANSI_Comma where onPreferences != nil: onPreferences?(); return true
        case kVK_ANSI_W: performClose(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private enum ApplicationLayout: String { case cards, list }

private final class SettingsController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    let window: QuickToggleWindow
    var onWindowClosed: (() -> Void)?
    struct Presentation {
        let frame: NSRect
        let query: String
        let scope: Int
        let scrollY: CGFloat
    }
    var presentation: Presentation {
        Presentation(frame: window.frame, query: searchField.stringValue,
                     scope: scopeControl.selectedSegment, scrollY: listScroll.contentView.bounds.minY)
    }
    private let model: QuickToggleModel
    fileprivate let bindingsStack = FlippedStackView()
    fileprivate let listScroll = NSScrollView()
    /// Test seam: invoked for every freshly built binding row; nil in production.
    var onBindingRowBuilt: ((BindingActionRow) -> Void)?
    private let countLabel = NSTextField(labelWithString: "")
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private let generalStatus = NSTextField(wrappingLabelWithString: "")
    private let preferencesStatus = NSTextField(wrappingLabelWithString: "")
    private let addButton = GlassActionButton()
    private let enableButton = NSButton()
    private let permissionButton = NSButton()
    private let permissionIcon = NSImageView()
    private let loginButton = NSButton()
    private let settingsShortcutRecorder = ShortcutRecorderButton(frame: .zero)
    private let guideButton = NSButton()
    private let guideCard = GlassCardView(frame: .zero)
    private let appGuideButton = NSButton()
    private let appGuideCard = GlassCardView(frame: .zero)
    private let statusDot = StatusDotView(frame: .zero)
    private let statusBanner = NSView()
    fileprivate let searchField = NSSearchField()
    fileprivate let scopeControl = NSSegmentedControl()
    fileprivate let layoutControl = NSSegmentedControl()
    private var renderedLayout: ApplicationLayout = .list
    private var renderedColumns = 1
    fileprivate var displayedBindingRows: [BindingActionRow] {
        bindingsStack.arrangedSubviews.flatMap { view -> [BindingActionRow] in
            if let row = view as? BindingActionRow { return [row] }
            return (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? BindingActionRow } ?? []
        }
    }
    var isVisible: Bool { window.isVisible || preferencesPanel?.isVisible == true }
    private let listTitle = NSTextField(labelWithString: "我的应用")
    private let preferencesButton = GlassActionButton()
    fileprivate let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let updateNotesLabel = NSTextField(wrappingLabelWithString: "")
    private let checkUpdateButton = GlassActionButton()
    private let releasePageButton = GlassActionButton()
    private let dailyUpdateCheckButton = NSButton()
    private var preferencesPanel: QuickToggleWindow?
    private var windowScrimView: WindowScrimView?
    private var rowStatusLabels: [UUID: NSTextField] = [:]
    private var lastRenderedBindings: [AppBinding]?
    private var guideExpanded = false
    private var appGuideExpanded = false
    private let helpPopover = NSPopover()
    private let addPopover = NSPopover()
    private let pendingPicker = PendingApplicationPickerController()
    private var pendingReplacementID: UUID?
    private let occupiedNameField = NSTextField()
    private let occupiedRecorder = ShortcutRecorderButton(frame: .zero)
    private var lastRenderedOccupied: [OccupiedHotKeyEntry]?
    /// Rows are expensive to build (views, icon, control bindings), so they
    /// are reused across rebuilds while their binding value is unchanged.
    /// Entries whose binding changed or was removed are rebuilt/dropped.
    private var bindingRowCache: [UUID: (row: BindingActionRow, binding: AppBinding, widthConstraint: NSLayoutConstraint)] = [:]
    private lazy var bottomSpacer: NSView = {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .vertical)
        view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return view
    }()
    private lazy var bottomSpacerWidth: NSLayoutConstraint =
        bottomSpacer.widthAnchor.constraint(equalTo: bindingsStack.widthAnchor)

    init(model: QuickToggleModel) {
        self.model = model
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let height = min(620, max(500, visible.height - 48))
        window = QuickToggleWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(640, visible.width - 48), height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = model.previewMode ? "AiGoodChange · \(appVersion) 预览" : "AiGoodChange"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 560, height: 500)
        window.delegate = self
        window.onFind = { [weak self] in self?.focusSearch() }
        window.onAdd = { [weak self] in self?.chooseApplication() }
        window.onPreferences = { [weak self] in self?.showPreferences() }
        window.isReleasedWhenClosed = false
        applyAccessibilityChrome()
        window.center()
        buildInterface()
        applyTheme()
        refresh()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeCatalog.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
        displayOptionsObserver = observeAccessibilityDisplayOptions { [weak self] in
            self?.applyAccessibilityChrome()
        }
    }

    private var displayOptionsObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    func show() {
        applyAccessibilityChrome()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.recalculateKeyViewLoop()
    }

    func restorePresentation(_ saved: Presentation) {
        window.setFrame(window.constrainFrameRect(saved.frame, to: NSScreen.main), display: false)
        searchField.stringValue = saved.query
        scopeControl.selectedSegment = saved.scope
        rebuildBindingRows()
        window.contentView?.layoutSubtreeIfNeeded()
        let maxY = max(0, bindingsStack.bounds.height - listScroll.contentSize.height)
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: min(saved.scrollY, maxY)))
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    /// The model owns hotkeys and preferences; hidden UI can be discarded safely.
    func prepareForBackground() {
        helpPopover.performClose(nil)
        addPopover.performClose(nil)
        if let panel = preferencesPanel, panel.sheetParent != nil { window.endSheet(panel) }
        preferencesPanel?.orderOut(nil)
        window.orderOut(nil)
        window.makeFirstResponder(nil)
        window.delegate = nil
        window.contentView = nil
        preferencesPanel?.contentView = nil
        bindingRowCache.removeAll()
        rowStatusLabels.removeAll()
        for view in bindingsStack.arrangedSubviews {
            bindingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func refresh() {
        themePicker.selectItem(at: ThemeCatalog.bundled.firstIndex { $0.id == model.themeIdentifier } ?? 0)
        layoutControl.selectedSegment = model.applicationLayout == .cards ? 0 : 1
        var restoredFocusScrollTarget: BindingActionRow?
        if lastRenderedBindings != model.bindings || lastRenderedOccupied != model.occupiedHotKeys || renderedLayout != model.applicationLayout {
            let bindingsChanged = lastRenderedBindings != model.bindings
            lastRenderedBindings = model.bindings
            lastRenderedOccupied = model.occupiedHotKeys
            restoredFocusScrollTarget = rebuildBindingRows(scrollRestoredFocusIntoView: bindingsChanged)
        }

        permissionStatus.stringValue = model.accessibilityStatus
        generalStatus.stringValue = model.statusMessage
        generalStatus.toolTip = model.statusMessage
        preferencesStatus.stringValue = model.statusMessage
        preferencesStatus.textColor = model.statusTone.color
        generalStatus.textColor = model.statusTone.color
        loginButton.state = model.loginAtLaunchEnabled ? .on : .off
        loginButton.toolTip = model.loginAtLaunchHelp
        settingsShortcutRecorder.shortcut = model.settingsShortcut
        enableButton.state = model.isEnabled ? .on : .off
        statusDot.color = model.statusTone == .info
            ? (model.registeredShortcutCount > 0 ? .systemGreen : .secondaryLabelColor)
            : model.statusTone.color
        let bindingsByID = Dictionary(uniqueKeysWithValues: model.bindings.map { ($0.id, $0) })
        rowStatusLabels.forEach { id, label in
            guard let binding = bindingsByID[id] else { return }
            if let attention = model.rowStatusAttention(for: binding) {
                label.stringValue = attention.text
                label.textColor = attention.color
                label.setAccessibilityLabel("\(binding.target.name) \(attention.text)")
                label.isHidden = false
            } else {
                label.stringValue = ""
                label.setAccessibilityLabel(nil)
                label.isHidden = true
            }
        }
        statusBanner.layer?.backgroundColor = model.statusTone == .info
            ? NSColor.clear.cgColor
            : model.statusTone.color.withAlphaComponent(0.14).cgColor
        permissionIcon.contentTintColor = Accessibility.isTrusted ? .systemGreen : .secondaryLabelColor
        permissionButton.isHidden = Accessibility.isTrusted
        permissionButton.isEnabled = !model.previewMode
        loginButton.isEnabled = !model.previewMode
        updateStatusLabel.stringValue = model.updateCheckSummary
        updateNotesLabel.stringValue = model.updateCheckNotes ?? ""
        updateNotesLabel.isHidden = !(model.isUpdateAvailable && !(model.updateCheckNotes ?? "").isEmpty)
        checkUpdateButton.isEnabled = !model.previewMode && !model.isUpdateCheckInProgress
        checkUpdateButton.title = model.isUpdateCheckInProgress ? "正在检查…" : "检查更新…"
        releasePageButton.isHidden = !model.isUpdateAvailable
        dailyUpdateCheckButton.state = model.dailyUpdateCheckEnabled ? .on : .off
        dailyUpdateCheckButton.isEnabled = !model.previewMode
        if let restoredFocusScrollTarget {
            scrollBindingRowIntoView(restoredFocusScrollTarget)
        }
    }

    private func buildInterface() {
        let material = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        material.autoresizingMask = [.width, .height]
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        window.contentView = material

        let scrim = WindowScrimView(frame: material.bounds)
        scrim.autoresizingMask = [.width, .height]
        material.addSubview(scrim)
        windowScrimView = scrim

        let title = NSTextField(labelWithString: "AiGoodChange")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let productIdentity = NSTextField(labelWithString: model.previewMode ? "\(appVersion) 预览" : appVersion)
        productIdentity.textColor = .secondaryLabelColor
        productIdentity.font = .systemFont(ofSize: 11.5, weight: .medium)
        settingsShortcutRecorder.shortcut = model.settingsShortcut
        settingsShortcutRecorder.controlSize = .small
        settingsShortcutRecorder.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        settingsShortcutRecorder.onRecord = { [weak self] shortcut in
            self?.model.applySettingsShortcut(shortcut) == true
        }
        settingsShortcutRecorder.onClear = { [weak self] in
            self?.model.reportStatus("设置窗口快捷键不能清除，请直接录制新组合。", tone: .warning)
            return false
        }
        settingsShortcutRecorder.onInvalid = { [weak self] message in
            self?.model.reportStatus(message, tone: .error)
        }
        settingsShortcutRecorder.widthAnchor.constraint(equalToConstant: 72).isActive = true
        settingsShortcutRecorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        settingsShortcutRecorder.setAccessibilityLabel("AiGoodChange 设置窗口快捷键")
        settingsShortcutRecorder.setAccessibilityHelp("点击后录制新的显示或隐藏设置窗口快捷键；推荐 Command 加数字，或 fn/Globe 加数字，Esc 取消。")
        settingsShortcutRecorder.toolTip = "点击更换；优先推荐 ⌘0–9，也可用 fn/🌐0–9、⌘⌥K / ⌘⇧K"
        let titleRow = horizontalStack([title, productIdentity], spacing: 9)
        titleRow.alignment = .lastBaseline
        let subtitle = NSTextField(labelWithString: "一按呼出，再按恢复。")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12.5)
        let titleStack = verticalStack([titleRow, subtitle], spacing: 3)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let settingsShortcutLabel = NSTextField(labelWithString: "打开窗口")
        settingsShortcutLabel.font = .systemFont(ofSize: 11.5)
        settingsShortcutLabel.textColor = .secondaryLabelColor
        let settingsShortcutControl = horizontalStack(
            [settingsShortcutLabel, settingsShortcutRecorder],
            spacing: 6
        )
        settingsShortcutControl.alignment = .centerY

        enableButton.target = self
        enableButton.action = #selector(toggleEnabled)
        enableButton.setButtonType(.switch)
        enableButton.title = "启用快捷键"
        enableButton.controlSize = .small
        enableButton.font = .systemFont(ofSize: 12)
        enableButton.setAccessibilityLabel("启用或停用全部应用快捷键")
        enableButton.widthAnchor.constraint(equalToConstant: 108).isActive = true
        enableButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let header = horizontalStack(
            [titleStack, headerSpacer, settingsShortcutControl, enableButton],
            spacing: 12
        )
        header.alignment = .centerY

        let applicationsCard = GlassCardView(frame: .zero)
        applicationsCard.setAccessibilityLabel("应用快捷键列表")
        applicationsCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        applicationsCard.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        listTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        let listHeaderSpacer = NSView()
        listHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addButton.title = "添加应用…"
        addButton.target = self
        addButton.action = #selector(chooseApplication)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        addButton.setAccessibilityLabel("添加目标应用")
        addButton.setAccessibilityHelp("打开已安装应用列表；添加后自动分配一个可用的数字快捷键。")
        addButton.emphasized = true
        layoutControl.segmentCount = 2
        for (index, label) in ["卡片", "列表"].enumerated() {
            layoutControl.setLabel(label, forSegment: index)
            layoutControl.setWidth(42, forSegment: index)
        }
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .rounded
        layoutControl.controlSize = .small
        layoutControl.target = self
        layoutControl.action = #selector(changeLayout(_:))
        layoutControl.setAccessibilityLabel("应用布局")
        let listHeader = horizontalStack([listTitle, countLabel, listHeaderSpacer, layoutControl, addButton], spacing: 8)
        listHeader.alignment = .centerY

        searchField.placeholderString = "搜索应用或快捷键"
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("搜索应用或快捷键")
        searchField.toolTip = "按 ⌘F 搜索应用名称或快捷键"
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        scopeControl.segmentCount = 3
        for (index, label) in ["全部应用", "待设置", "占用记录"].enumerated() {
            scopeControl.setLabel(label, forSegment: index)
            scopeControl.setWidth(index == 1 ? 62 : 78, forSegment: index)
        }
        scopeControl.trackingMode = .selectOne
        scopeControl.selectedSegment = 0
        scopeControl.segmentStyle = .rounded
        scopeControl.controlSize = .small
        scopeControl.target = self
        scopeControl.action = #selector(changeScope)
        scopeControl.setAccessibilityLabel("列表范围")
        let filterRow = horizontalStack([searchField, scopeControl], spacing: 12)
        filterRow.alignment = .centerY

        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .leading
        bindingsStack.distribution = .fill
        bindingsStack.spacing = 3
        bindingsStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        listScroll.documentView = bindingsStack
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false
        bindingsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bindingsStack.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            bindingsStack.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            bindingsStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            bindingsStack.heightAnchor.constraint(greaterThanOrEqualTo: listScroll.contentView.heightAnchor)
        ])
        listScroll.setContentHuggingPriority(.init(1), for: .vertical)
        listScroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 168).isActive = true

        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        generalStatus.textColor = .secondaryLabelColor
        generalStatus.font = .systemFont(ofSize: 12.2, weight: .medium)
        generalStatus.lineBreakMode = .byWordWrapping
        generalStatus.maximumNumberOfLines = 3
        generalStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        generalStatus.setAccessibilityLabel("当前状态")
        let statusRow = horizontalStack([statusDot, generalStatus], spacing: 8)
        statusRow.alignment = .centerY
        statusBanner.wantsLayer = true
        statusBanner.layer?.cornerRadius = 8
        pin(statusRow, inside: statusBanner, insets: NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9))

        let applicationsStack = verticalStack([listHeader, filterRow, listScroll], spacing: 8)
        pin(applicationsStack, inside: applicationsCard, insets: NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10))
        [listHeader, filterRow, listScroll].forEach {
            $0.widthAnchor.constraint(equalTo: applicationsStack.widthAnchor).isActive = true
        }

        permissionIcon.image = NSImage(
            systemSymbolName: "lock.shield",
            accessibilityDescription: "窗口恢复能力"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        permissionIcon.contentTintColor = .secondaryLabelColor
        permissionIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        permissionIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        permissionStatus.font = .systemFont(ofSize: 11.5)
        permissionStatus.textColor = .secondaryLabelColor
        permissionStatus.lineBreakMode = .byTruncatingTail
        permissionStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let permissionSpacer = NSView()
        permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        permissionButton.title = "授权…"
        permissionButton.target = self
        permissionButton.action = #selector(requestAccessibility)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 12, weight: .medium)
        permissionButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        permissionButton.setAccessibilityHelp("授权后可恢复最小化窗口，并使用 fn/Globe 快捷键。")
        let permissionTitle = NSTextField(labelWithString: "辅助功能")
        permissionTitle.font = .systemFont(ofSize: 12.5, weight: .medium)
        let permissionText = verticalStack([permissionTitle, permissionStatus], spacing: 1)

        let permissionRow = horizontalStack(
            [permissionIcon, permissionText, permissionSpacer, permissionButton],
            spacing: 8
        )
        permissionRow.alignment = .centerY
        permissionRow.setAccessibilityLabel("辅助功能")
        permissionRow.setContentHuggingPriority(.required, for: .vertical)

        loginButton.setButtonType(.switch)
        loginButton.title = "登录时自动启动"
        loginButton.target = self
        loginButton.action = #selector(toggleLoginAtLaunch)
        loginButton.font = .systemFont(ofSize: 12)
        loginButton.controlSize = .small
        loginButton.state = model.loginAtLaunchEnabled ? .on : .off
        loginButton.toolTip = model.loginAtLaunchHelp
        loginButton.setAccessibilityLabel("登录时启动 AiGoodChange")
        loginButton.setAccessibilityHelp("默认关闭。打开后由 macOS 在登录时启动 AiGoodChange，不会新增后台进程。")
        loginButton.setContentHuggingPriority(.required, for: .vertical)

        let runtimeTitle = NSTextField(labelWithString: "运行")
        runtimeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let runtimeSpacer = NSView()
        runtimeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let runtimeHeader = horizontalStack([runtimeTitle, runtimeSpacer, loginButton], spacing: 8)
        runtimeHeader.alignment = .centerY
        let runtimeStack = verticalStack([runtimeHeader, permissionRow], spacing: 10)
        let runtimeCard = GlassCardView(frame: .zero)
        runtimeCard.setAccessibilityLabel("运行设置")
        pin(runtimeStack, inside: runtimeCard, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        [runtimeHeader, permissionRow].forEach {
            $0.widthAnchor.constraint(equalTo: runtimeStack.widthAnchor).isActive = true
        }

        let updateTitle = NSTextField(labelWithString: "更新")
        updateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        updateStatusLabel.font = .systemFont(ofSize: 11.5)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.maximumNumberOfLines = 2
        updateStatusLabel.setAccessibilityLabel("更新检查状态")
        updateNotesLabel.font = .systemFont(ofSize: 11.5)
        updateNotesLabel.textColor = .secondaryLabelColor
        updateNotesLabel.maximumNumberOfLines = 3
        updateNotesLabel.lineBreakMode = .byTruncatingTail
        updateNotesLabel.isHidden = true
        updateNotesLabel.setAccessibilityLabel("发行说明摘要")

        checkUpdateButton.title = "检查更新…"
        checkUpdateButton.bezelStyle = .rounded
        checkUpdateButton.controlSize = .small
        checkUpdateButton.target = self
        checkUpdateButton.action = #selector(checkForUpdate)
        checkUpdateButton.setAccessibilityLabel("检查更新")
        checkUpdateButton.setAccessibilityHelp("向 GitHub 查询最新发行版本；只读版本号，不会上传任何数据，也不会自动安装。")

        releasePageButton.title = "查看发行页…"
        releasePageButton.bezelStyle = .rounded
        releasePageButton.controlSize = .small
        releasePageButton.target = self
        releasePageButton.action = #selector(openReleasePage)
        releasePageButton.setAccessibilityLabel("查看发行页")
        releasePageButton.isHidden = true

        dailyUpdateCheckButton.setButtonType(.switch)
        dailyUpdateCheckButton.title = "每天自动检查一次"
        dailyUpdateCheckButton.controlSize = .small
        dailyUpdateCheckButton.font = .systemFont(ofSize: 12)
        dailyUpdateCheckButton.target = self
        dailyUpdateCheckButton.action = #selector(toggleDailyUpdateCheck)
        dailyUpdateCheckButton.state = model.dailyUpdateCheckEnabled ? .on : .off
        dailyUpdateCheckButton.setAccessibilityLabel("每天自动检查一次更新")
        dailyUpdateCheckButton.toolTip = "打开后，启动和运行期间每 24 小时静默检查一次 GitHub 最新发行版。"

        let updateControls = horizontalStack([checkUpdateButton, releasePageButton, dailyUpdateCheckButton], spacing: 10)
        updateControls.alignment = .centerY
        let updateSpacer = NSView()
        updateSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let updateRow = horizontalStack([updateTitle, updateSpacer, updateControls], spacing: 8)
        updateRow.alignment = .centerY
        let updateStack = verticalStack([updateRow, updateStatusLabel, updateNotesLabel], spacing: 8)
        let updateCard = GlassCardView(frame: .zero)
        updateCard.setAccessibilityLabel("更新检查")
        pin(updateStack, inside: updateCard, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        [updateRow, updateStatusLabel, updateNotesLabel].forEach {
            $0.widthAnchor.constraint(equalTo: updateStack.widthAnchor).isActive = true
        }

        guideButton.title = "macOS 快捷键参考"
        guideButton.target = self
        guideButton.action = #selector(toggleGuide)
        guideButton.bezelStyle = .inline
        guideButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        guideButton.imagePosition = .imageLeading
        guideButton.contentTintColor = .secondaryLabelColor
        guideButton.font = .systemFont(ofSize: 13, weight: .medium)
        guideButton.alignment = .left
        guideButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        guideButton.setAccessibilityLabel("展开或收起 macOS 原生快捷键")

        let nativeShortcuts = [
            ("magnifyingglass", "聚焦搜索", "⌘ Space"),
            ("rectangle.stack", "切换应用", "⌘ Tab"),
            ("camera.viewfinder", "截图与录屏", "⇧⌘ 5"),
            ("face.smiling", "表情与符号", "⌃⌘ Space"),
            ("exclamationmark.octagon", "强制退出", "⌥⌘ Esc"),
            ("note.text", "快速备忘录", "fn Q")
        ]
        let leftColumn = verticalStack(nativeShortcuts.prefix(3).map(makeSystemShortcutItem), spacing: 10)
        let rightColumn = verticalStack(nativeShortcuts.suffix(3).map(makeSystemShortcutItem), spacing: 10)
        let shortcutGrid = horizontalStack([leftColumn, rightColumn], spacing: 28)
        shortcutGrid.distribution = .fillEqually

        // Official macOS shortcuts, grouped by purpose. Sourced 2026-09-27
        // from Apple Support 102650 (keyboard shortcuts) and mac-help mh35798
        // (Mission Control); see the note below for conditions and editing.
        let guideSections: [(String, String, [(String, String, String)])] = [
            ("macwindow", "窗口与 App", [
                ("rectangle.split.2x1", "显示最前 App 的所有窗口（再按一次返回）", "⌃ ↓"),
                ("arrow.triangle.swap", "当前 App 的窗口间切换 *", "⌘ `"),
                ("rectangle.stack", "在打开的 App 之间切换", "⌘ Tab"),
                ("square.stack.3d.up", "打开调度中心", "⌃ ↑"),
                ("sun.min", "移开所有窗口显示桌面", "fn H"),
                ("arrow.up.left.and.arrow.down.right", "进入或退出全屏（如果 App 支持）", "⌃⌘ F")
            ]),
            ("folder", "访达文件", [
                ("folder.badge.plus", "新建文件夹", "⇧⌘ N"),
                ("doc.on.doc", "复制所选文件", "⌘ D"),
                ("trash", "移到废纸篓", "⌘ Delete"),
                ("eye", "快速查看所选项目", "Space"),
                ("info.circle", "显示简介", "⌘ I"),
                ("arrow.uturn.right", "把拷贝的文件移动到当前位置", "⌥⌘ V")
            ]),
            ("camera.viewfinder", "截屏", [
                ("camera.viewfinder", "截屏与录屏工具", "⇧⌘ 5"),
                ("camera.on.rectangle", "全屏截图", "⇧⌘ 3"),
                ("plus.viewfinder", "选区截图", "⇧⌘ 4")
            ]),
            ("sparkles", "系统导航", [
                ("magnifyingglass", "聚焦搜索（多输入源时可能改为切换输入法）", "⌘ Space"),
                ("magnifyingglass", "访达窗口中进行聚焦搜索", "⌥⌘ Space"),
                ("exclamationmark.octagon", "强制退出 App", "⌥⌘ Esc"),
                ("lock", "锁定屏幕", "⌃⌘ Q")
            ])
        ]
        let sectionViews: [NSView] = guideSections.flatMap { symbol, title, items in
            var views = [makeGuideSectionHeader(symbol, title)]
            views.append(contentsOf: items.map(makeSystemShortcutItem))
            return views
        }
        let guideSectionsStack = verticalStack(sectionViews, spacing: 6)

        let nativeNote = NSTextField(wrappingLabelWithString:
            "以上均为 macOS 系统默认，可在“系统设置 > 键盘 > 键盘快捷键”中修改；AiGoodChange 不会注册或覆盖它们。* ⌘` 的按键因键盘布局而异。⌃↓ 是系统自带的 App Exposé：访达在最前时即总览访达的全部窗口，AiGoodChange 不另做此功能。来源：Apple 支持《Mac 键盘快捷键》(support.apple.com/zh-cn/102650) 与《在 Mac 上使用调度中心》(support.apple.com/zh-cn/guide/mac-help/mh35798/mac)，2026-09-27 查证。"
        )
        nativeNote.font = .systemFont(ofSize: 11.5)
        nativeNote.textColor = .secondaryLabelColor
        nativeNote.maximumNumberOfLines = 5

        let customGuide = NSTextField(wrappingLabelWithString:
            "优先推荐未占用的 ⌘0–9；⌘ 数字用尽后推荐 fn/🌐0–9（需辅助功能授权）。单按 Globe 的系统动作会警告；fn/🌐+F1–F12 受“将 F1、F2 等键用作标准功能键”影响，本版不注册。macOS 无法检测所有系统、应用或键盘固件冲突。"
        )
        customGuide.font = .systemFont(ofSize: 11.5)
        customGuide.textColor = .tertiaryLabelColor
        customGuide.maximumNumberOfLines = 3

        let guideContent = verticalStack([shortcutGrid, guideSectionsStack, nativeNote, customGuide], spacing: 10)
        [shortcutGrid, guideSectionsStack, nativeNote, customGuide].forEach {
            $0.widthAnchor.constraint(equalTo: guideContent.widthAnchor).isActive = true
        }
        guideCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 186).isActive = true
        guideCard.setAccessibilityLabel("macOS 原生快捷键指南")
        pin(guideContent, inside: guideCard, insets: NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18))

        appGuideButton.title = "应用快捷键与占用"
        appGuideButton.target = self
        appGuideButton.action = #selector(toggleAppGuide)
        appGuideButton.bezelStyle = .inline
        appGuideButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        appGuideButton.imagePosition = .imageLeading
        appGuideButton.contentTintColor = .secondaryLabelColor
        appGuideButton.font = .systemFont(ofSize: 13, weight: .medium)
        appGuideButton.alignment = .left
        appGuideButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        appGuideButton.setAccessibilityLabel("展开或收起应用内快捷键")

        let applicationRows = ConfirmedAppShortcuts.catalog.compactMap { identifier, name in
            makeApplicationShortcutRow(
                bundleIdentifier: identifier,
                name: name,
                shortcuts: ConfirmedAppShortcuts.entries(for: identifier)
            )
        }
        let applicationList: NSView
        if applicationRows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "暂未检测到支持的常用应用。")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            applicationList = empty
        } else {
            applicationList = verticalStack(applicationRows, spacing: 8)
        }

        let occupiedTitle = NSTextField(labelWithString: "本机占用的快捷键（用于自动避开冲突）")
        occupiedTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        occupiedTitle.textColor = .secondaryLabelColor

        occupiedNameField.placeholderString = "占用方名称"
        occupiedNameField.font = .systemFont(ofSize: 12)
        occupiedNameField.bezelStyle = .roundedBezel
        occupiedNameField.controlSize = .small
        occupiedNameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        occupiedNameField.setAccessibilityLabel("占用方名称")

        occupiedRecorder.controlSize = .small
        occupiedRecorder.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        occupiedRecorder.onRecord = { _ in true }
        occupiedRecorder.onClear = { true }
        occupiedRecorder.onInvalid = { [weak self] message in
            self?.model.reportStatus(message, tone: .error)
        }
        occupiedRecorder.widthAnchor.constraint(equalToConstant: 108).isActive = true
        occupiedRecorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        occupiedRecorder.setAccessibilityLabel("占用组合录制")
        occupiedRecorder.toolTip = "录制其他软件已占用的组合，再点“添加”"

        let occupiedAddButton = NSButton(
            title: "添加",
            target: self,
            action: #selector(addOccupiedAction)
        )
        occupiedAddButton.bezelStyle = .rounded
        occupiedAddButton.controlSize = .small
        occupiedAddButton.setAccessibilityLabel("添加本机占用记录")

        let occupiedAddRow = horizontalStack(
            [occupiedNameField, occupiedRecorder, occupiedAddButton],
            spacing: 8
        )

        let applicationNote = NSTextField(wrappingLabelWithString:
            "这里只记录你确认过的占用项；其他快捷键请以应用菜单为准。"
        )
        applicationNote.font = .systemFont(ofSize: 11.5)
        applicationNote.textColor = .secondaryLabelColor
        applicationNote.maximumNumberOfLines = 2

        let applicationGuideContent = verticalStack(
            [occupiedTitle, occupiedAddRow, applicationList, applicationNote],
            spacing: 10
        )
        [occupiedTitle, occupiedAddRow, applicationList, applicationNote].forEach {
            $0.widthAnchor.constraint(equalTo: applicationGuideContent.widthAnchor).isActive = true
        }
        appGuideCard.heightAnchor.constraint(equalToConstant: 220).isActive = true
        appGuideCard.isHidden = true
        guideCard.isHidden = true
        appGuideCard.setAccessibilityLabel("已安装应用的快捷键参考")
        let appGuideScroll = NSScrollView()
        appGuideScroll.drawsBackground = false
        appGuideScroll.hasVerticalScroller = true
        appGuideScroll.autohidesScrollers = true
        appGuideScroll.borderType = .noBorder
        appGuideScroll.documentView = applicationGuideContent
        pin(
            appGuideScroll,
            inside: appGuideCard,
            insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        )
        applicationGuideContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            applicationGuideContent.leadingAnchor.constraint(equalTo: appGuideScroll.contentView.leadingAnchor),
            applicationGuideContent.trailingAnchor.constraint(equalTo: appGuideScroll.contentView.trailingAnchor),
            applicationGuideContent.topAnchor.constraint(equalTo: appGuideScroll.contentView.topAnchor),
            applicationGuideContent.widthAnchor.constraint(equalTo: appGuideScroll.contentView.widthAnchor, constant: -8)
        ])

        pendingPicker.onPick = { [weak self] url in
            guard let self else { return }
            let replacementID = self.pendingReplacementID
            self.pendingReplacementID = nil
            self.addPopover.performClose(nil)
            self.completeApplicationSelection(url: url, replacing: replacementID)
        }
        pendingPicker.onChooseFromDisk = { [weak self] in
            guard let self else { return }
            let replacementID = self.pendingReplacementID
            self.pendingReplacementID = nil
            self.addPopover.performClose(nil)
            self.chooseApplicationFromDisk(replacing: replacementID)
        }
        addPopover.contentViewController = pendingPicker
        addPopover.behavior = .transient
        helpPopover.behavior = .transient
        applyAccessibilityChrome()

        preferencesButton.title = "设置与帮助…"
        preferencesButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        preferencesButton.imagePosition = .imageLeading
        preferencesButton.bezelStyle = .rounded
        preferencesButton.controlSize = .small
        preferencesButton.target = self
        preferencesButton.action = #selector(showPreferences)
        preferencesButton.setAccessibilityLabel("设置与帮助")
        let footerHint = NSTextField(labelWithString: model.previewMode
            ? "预览 · 配置不写回"
            : "点应用更换 · ⌘F 搜索")
        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = .secondaryLabelColor
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        themePicker.addItems(withTitles: ThemeCatalog.bundled.map(\.name))
        for (item, theme) in zip(themePicker.itemArray, ThemeCatalog.bundled) { item.representedObject = theme.id }
        themePicker.target = self
        themePicker.action = #selector(changeTheme(_:))
        themePicker.controlSize = .small
        themePicker.font = .systemFont(ofSize: 11.5)
        themePicker.widthAnchor.constraint(equalToConstant: 118).isActive = true
        themePicker.setAccessibilityLabel("主题")
        themePicker.toolTip = "选择主题，自动适配系统深色或浅色外观"
        let themeLabel = NSTextField(labelWithString: "主题")
        themeLabel.font = .systemFont(ofSize: 11)
        themeLabel.textColor = VisualPalette.secondaryText
        let footer = horizontalStack([footerHint, footerSpacer, themeLabel, themePicker, preferencesButton], spacing: 8)
        footer.alignment = .centerY
        buildPreferencesPanel(views: [runtimeCard, updateCard, guideButton, guideCard, appGuideButton, appGuideCard])

        let rootStack = verticalStack([header, applicationsCard, statusBanner, footer], spacing: 8)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(rootStack)
        header.setContentHuggingPriority(.required, for: .vertical)
        statusBanner.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        guideButton.setContentHuggingPriority(.required, for: .vertical)
        appGuideButton.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: material.topAnchor, constant: 36),
            rootStack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            applicationsCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            statusBanner.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
        window.initialFirstResponder = addButton
    }

    private func buildPreferencesPanel(views: [NSView]) {
        let panel = QuickToggleWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 530),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "设置与帮助"
        panel.minSize = NSSize(width: 570, height: 510)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let title = NSTextField(labelWithString: "按你的习惯使用 AiGoodChange")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "普通快捷键添加后即可使用；需要 fn 快捷键或恢复最小化窗口时，再开启辅助功能。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        preferencesStatus.font = .systemFont(ofSize: 11.5)
        preferencesStatus.maximumNumberOfLines = 3
        let done = GlassActionButton(title: "完成", target: self, action: #selector(closePreferences))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let version = NSTextField(labelWithString: "AiGoodChange · \(appVersion)\(model.previewMode ? " · 预览" : "")")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let footer = horizontalStack([version, spacer, done], spacing: 8)
        let content = FlippedStackView(views: [title, note] + views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let container = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        panel.contentView = container
        let scrim = WindowScrimView(frame: container.bounds)
        scrim.autoresizingMask = [.width, .height]
        container.addSubview(scrim)
        let root = verticalStack([scroll, preferencesStatus, footer], spacing: 12)
        pin(root, inside: container, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        root.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        content.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        views.forEach { $0.setContentHuggingPriority(.required, for: .vertical) }
        panel.initialFirstResponder = loginButton
        preferencesPanel = panel
    }

    @objc private func showPreferences() {
        guard let panel = preferencesPanel, window.attachedSheet == nil else { return }
        refresh()
        window.beginSheet(panel)
    }

    @objc private func closePreferences() {
        guard let panel = preferencesPanel, panel.sheetParent != nil else { return }
        window.endSheet(panel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === preferencesPanel { closePreferences(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { onWindowClosed?() }
    }

    private func focusSearch() {
        guard window.attachedSheet == nil else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildBindingRows()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    @objc fileprivate func changeScope() {
        rebuildBindingRows()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    @objc fileprivate func resetListFilter() {
        searchField.stringValue = ""
        scopeControl.selectedSegment = ApplicationListScope.all.rawValue
        changeScope()
    }

    @objc private func showOccupiedEditor() {
        appGuideExpanded = true
        guideExpanded = false
        updateGuideVisibility()
        showPreferences()
    }

    private func makeFilteredEmptyState(scope: ApplicationListScope) -> NSView {
        let searching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: searching ? "magnifyingglass" : "checkmark.circle", accessibilityDescription: nil)
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.widthAnchor.constraint(equalToConstant: 28).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: searching ? "没有找到匹配项" : (scope == .occupied ? "还没有占用记录" : "每个应用都有快捷键了"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: searching
            ? "试试应用名称或 ⌘4 这样的快捷键，也可以回到全部应用。"
            : (scope == .occupied ? "记录其他软件已占用的组合，添加应用时会自动避开。" : "回到全部应用，点击行内快捷键即可修改。"))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let button = NSButton(title: !searching && scope == .occupied ? "添加占用记录…" : "显示全部应用",
                              target: self, action: !searching && scope == .occupied ? #selector(showOccupiedEditor) : #selector(resetListFilter))
        button.bezelStyle = .rounded
        let content = verticalStack([symbol, title, detail, button], spacing: 10)
        content.alignment = .centerX
        let container = NSView()
        pin(content, inside: container, insets: NSEdgeInsets(top: 36, left: 20, bottom: 30, right: 20))
        return container
    }

    /// Where keyboard focus lived before `rebuildBindingRows()` destroyed the
    /// rows, so it can be re-anchored to the rebuilt controls.
    private struct BindingFocusAnchor {
        let bindingID: UUID
        let wasRecorder: Bool
        let rowIndex: Int
    }

    private func captureBindingFocusAnchor() -> BindingFocusAnchor? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        let rows = displayedBindingRows
        var current: NSView? = responder
        while let view = current {
            if let row = view as? BindingActionRow,
               let rawID = row.identifier?.rawValue,
               let id = UUID(uuidString: rawID),
               let index = rows.firstIndex(where: { $0 === row }) {
                return BindingFocusAnchor(
                    bindingID: id,
                    wasRecorder: responder is ShortcutRecorderButton,
                    rowIndex: index
                )
            }
            current = view.superview
        }
        return nil
    }

    private func restoreBindingFocus(_ anchor: BindingFocusAnchor?) -> BindingActionRow? {
        guard let anchor else { return nil }
        let rows = displayedBindingRows
        if let sameBinding = rows.first(where: { $0.identifier?.rawValue == anchor.bindingID.uuidString }) {
            if anchor.wasRecorder, let recorder = sameBinding.recorderButton {
                window.makeFirstResponder(recorder)
            } else {
                window.makeFirstResponder(sameBinding)
            }
            return sameBinding
        }
        if rows.indices.contains(anchor.rowIndex) {
            window.makeFirstResponder(rows[anchor.rowIndex])
            return rows[anchor.rowIndex]
        }
        if let last = rows.last {
            window.makeFirstResponder(last)
            return last
        }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
        return nil
    }

    @discardableResult
    fileprivate func rebuildBindingRows(scrollRestoredFocusIntoView: Bool = false) -> BindingActionRow? {
        helpPopover.performClose(nil)
        addPopover.performClose(nil)
        let focusAnchor = captureBindingFocusAnchor()
        let focusedBindingChanged = focusAnchor.map { anchor in
            bindingRowCache[anchor.bindingID]?.binding
                != model.bindings.first(where: { $0.id == anchor.bindingID })
        } ?? false
        let focusedRowWasVisible = focusAnchor.flatMap { bindingRowCache[$0.bindingID]?.row }.map { row in
            let frame = row.convert(row.bounds, to: listScroll.contentView)
            return listScroll.contentView.bounds.contains(frame)
        } ?? false
        let scope = ApplicationListScope(rawValue: scopeControl.selectedSegment) ?? .all
        let showCards = model.applicationLayout == .cards && scope != .occupied
        let columns = showCards ? cardColumnCount : 1
        if renderedLayout != model.applicationLayout {
            for entry in bindingRowCache.values { entry.widthConstraint.isActive = false }
            bindingRowCache.removeAll()
        }
        let columnsChanged = renderedColumns != columns
        renderedLayout = model.applicationLayout
        renderedColumns = columns
        bindingsStack.spacing = showCards ? 8 : 3
        layoutControl.isEnabled = scope != .occupied
        addButton.title = scope == .occupied ? "添加占用…" : "添加应用…"
        addButton.setAccessibilityLabel(scope == .occupied ? "添加占用记录" : "添加目标应用")
        addButton.setAccessibilityHelp(scope == .occupied ? "记录其他软件已占用的组合，自动分配时会避开。" : "打开已安装应用列表；添加后自动分配一个可用的数字快捷键。")
        let rows = ApplicationListFilter.rows(bindings: model.bindings, occupied: model.occupiedHotKeys, scope: scope, query: searchField.stringValue)
        listTitle.stringValue = scope == .occupied ? "占用记录" : (scope == .needsShortcut ? "待设置快捷键" : "我的应用")
        let total = scope == .occupied ? model.occupiedHotKeys.count : model.bindings.count
        countLabel.stringValue = rows.count == total ? "\(total) 项" : "\(rows.count) / \(total) 项"

        // Build the desired view sequence, reusing cached rows for bindings
        // whose value is unchanged (rows are expensive: views, icon, control
        // bindings). Hidden-but-valid rows stay cached for cheap filter
        // round-trips; changed or removed bindings drop their entries.
        var desired: [NSView] = []
        var freshViews: [NSView] = []
        var nextCache: [UUID: (row: BindingActionRow, binding: AppBinding, widthConstraint: NSLayoutConstraint)] = [:]
        if rows.isEmpty {
            let isFirstUse = scope == .all && model.bindings.isEmpty && searchField.stringValue.isEmpty
            let card = isFirstUse ? makeWelcomeCard() : makeFilteredEmptyState(scope: scope)
            desired.append(card)
            freshViews.append(card)
        } else {
            for row in rows {
                switch row {
                case .binding(let binding):
                    let rowView: BindingActionRow
                    let widthConstraint: NSLayoutConstraint
                    if let cached = bindingRowCache[binding.id], cached.binding == binding {
                        rowView = cached.row
                        if columnsChanged {
                            cached.widthConstraint.isActive = false
                            widthConstraint = bindingWidthConstraint(for: rowView, columns: columns)
                        } else {
                            widthConstraint = cached.widthConstraint
                        }
                    } else {
                        rowView = makeBindingRow(binding)
                        widthConstraint = bindingWidthConstraint(for: rowView, columns: columns)
                    }
                    nextCache[binding.id] = (rowView, binding, widthConstraint)
                    desired.append(rowView)
                case .occupied(let entry):
                    let view = makeOccupiedInlineRow(entry)
                    desired.append(view)
                    freshViews.append(view)
                }
            }
        }
        for (id, entry) in bindingRowCache where nextCache[id] == nil {
            if let binding = model.bindings.first(where: { $0.id == id }), binding == entry.binding {
                if columnsChanged {
                    entry.widthConstraint.isActive = false
                    nextCache[id] = (entry.row, entry.binding, bindingWidthConstraint(for: entry.row, columns: columns))
                } else {
                    nextCache[id] = entry
                }
            }
        }
        if showCards, !rows.isEmpty {
            // Cards move between bands when filtering or reordering. Remove
            // ancestor width constraints before detaching them from that tree.
            NSLayoutConstraint.deactivate(bindingRowCache.values.map { $0.widthConstraint })
        }
        bindingRowCache = nextCache
        rowStatusLabels = bindingRowCache.reduce(into: [UUID: NSTextField]()) { dict, entry in
            if let line = entry.value.row.statusLine { dict[entry.key] = line }
        }
        if showCards, !rows.isEmpty {
            let cardViews = desired
            // Release the old bands before moving cached cards into new bands.
            for band in bindingsStack.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
                for card in band.arrangedSubviews {
                    band.removeArrangedSubview(card)
                    card.removeFromSuperview()
                }
            }
            desired = stride(from: 0, to: cardViews.count, by: columns).map { start in
                let band = horizontalStack(Array(cardViews[start..<min(start + columns, cardViews.count)]), spacing: 8)
                band.alignment = .top
                if start + columns > cardViews.count {
                    let trailing = NSView()
                    trailing.setContentHuggingPriority(.init(1), for: .horizontal)
                    band.addArrangedSubview(trailing)
                }
                freshViews.append(band)
                return band
            }
        }
        desired.append(bottomSpacer)
        // Sync the stack with the desired sequence. When nothing was added,
        // removed or reordered, leave the attached views (and their focus,
        // constraints and key-view loop) untouched.
        let current = bindingsStack.arrangedSubviews
        let identical = current.count == desired.count
            && zip(current, desired).allSatisfy { $0 === $1 }
        for view in current where !desired.contains(where: { $0 === view }) {
            bindingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var remaining = bindingsStack.arrangedSubviews
        var insertAt = 0
        for view in desired {
            if insertAt < remaining.count, remaining[insertAt] === view {
                insertAt += 1
                continue
            }
            if let index = remaining.firstIndex(where: { $0 === view }) {
                bindingsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
                remaining.remove(at: index)
            }
            bindingsStack.insertArrangedSubview(view, at: insertAt)
            remaining.insert(view, at: insertAt)
            insertAt += 1
        }
        for view in freshViews {
            view.widthAnchor.constraint(equalTo: bindingsStack.widthAnchor).isActive = true
        }
        bottomSpacerWidth.isActive = true
        for entry in bindingRowCache.values where entry.row.window != nil {
            entry.widthConstraint.isActive = true
        }
        let restoredRow = restoreBindingFocus(focusAnchor)
        if !identical { window.recalculateKeyViewLoop() }
        return scrollRestoredFocusIntoView && !identical && (focusedBindingChanged || focusedRowWasVisible)
            ? restoredRow : nil
    }

    // The supported window is at least 560 pt wide. Keep three columns while
    // Auto Layout adjusts their widths, including before the clip view is laid out.
    private let cardColumnCount = 3

    private func bindingWidthConstraint(for row: NSView, columns: Int) -> NSLayoutConstraint {
        row.widthAnchor.constraint(equalTo: bindingsStack.widthAnchor, multiplier: 1 / CGFloat(columns),
                                   constant: -8 * CGFloat(columns - 1) / CGFloat(columns))
    }

    @objc fileprivate func changeLayout(_ sender: NSSegmentedControl) {
        model.selectApplicationLayout(sender.selectedSegment == 0 ? .cards : .list)
        refresh()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window,
              model.applicationLayout == .cards,
              scopeControl.selectedSegment != ApplicationListScope.occupied.rawValue else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        guard cardColumnCount != renderedColumns else { return }
        rebuildBindingRows()
    }

    private func scrollBindingRowIntoView(_ row: BindingActionRow) {
        window.contentView?.layoutSubtreeIfNeeded()
        let rowFrame = row.convert(row.bounds, to: listScroll.contentView)
        let viewport = listScroll.contentView.bounds
        guard rowFrame.minY < viewport.minY || rowFrame.maxY > viewport.maxY else { return }
        let maxY = max(0, bindingsStack.bounds.height - viewport.height)
        let targetY = min(max(rowFrame.minY - 6, 0), maxY)
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    /// Brings the row for `id` into view after an add (or a duplicate add):
    /// switches back to the "全部" filter when it hides the row, scrolls the
    /// row into the viewport, flashes it briefly and puts keyboard focus on
    /// it. Visual only — never activates the app behind the row.
    fileprivate func revealBinding(_ id: UUID) {
        func currentRow() -> BindingActionRow? {
            displayedBindingRows
                .first { $0.identifier?.rawValue == id.uuidString }
        }
        var row = currentRow()
        if row == nil {
            let scope = ApplicationListScope(rawValue: scopeControl.selectedSegment) ?? .all
            let searching = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard scope != .all || searching else { return }
            resetListFilter()
            // The status callback can run refresh() and rebuild the rows, so
            // take the final row reference only after it has settled.
            model.appendStatusDetail("已切回全部应用并高亮该行。")
            row = currentRow()
        }
        guard let row else { return }
        scrollBindingRowIntoView(row)
        row.flashNewlyAdded()
        window.makeFirstResponder(row)
    }

    private func makeWelcomeCard() -> NSView {
        let emptyState = NSView()

        let title = NSTextField(labelWithString: "先添加一个常用应用")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let hasFreeDigit = model.nextFreeRecommendedDigit != nil
        let message = hasFreeDigit
            ? "AiGoodChange 会自动分配可用的数字快捷键：按一下呼出，再按一下藏回。"
            : "添加后在应用行的“未设置”按钮上录制快捷键即可。"
        let guide = NSTextField(wrappingLabelWithString: message)
        guide.font = .systemFont(ofSize: 12.5)
        guide.textColor = .secondaryLabelColor
        guide.alignment = .left

        let callToAction = NSButton(title: "添加第一个应用…", target: self, action: #selector(chooseApplication))
        callToAction.bezelStyle = .rounded
        callToAction.controlSize = .large
        callToAction.setAccessibilityLabel("添加第一个应用")
        callToAction.setAccessibilityHelp("打开已安装应用列表；添加后自动分配一个可用的数字快捷键。")
        callToAction.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let hint = NSTextField(labelWithString: "点快捷键换键，点图标或名称更换应用。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let content = verticalStack([title, guide, callToAction, hint], spacing: 8)
        pin(content, inside: emptyState, insets: NSEdgeInsets(top: 22, left: 18, bottom: 22, right: 18))
        return emptyState
    }

    private func makeOccupiedInlineRow(_ entry: OccupiedHotKeyEntry) -> NSView {
        let row = NSBox()
        row.boxType = .custom
        row.cornerRadius = 8
        row.borderWidth = 1
        row.borderColor = .separatorColor.withAlphaComponent(0.45)
        row.fillColor = .controlBackgroundColor.withAlphaComponent(0.18)
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        row.setAccessibilityLabel("本机占用 \(entry.name) \(entry.shortcut.displayName)")

        let badge = NSTextField(labelWithString: "本机占用")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .systemOrange
        let badgePill = NSView()
        badgePill.wantsLayer = true
        badgePill.layer?.cornerRadius = 5
        badgePill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        pin(badge, inside: badgePill, insets: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSTextField(labelWithString: entry.shortcut.displayName)
        keys.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        keys.textColor = .secondaryLabelColor

        let remove = NSButton(title: "移除", target: self, action: #selector(removeOccupiedAction(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.tag = model.occupiedHotKeys.firstIndex(of: entry) ?? -1
        remove.isEnabled = remove.tag >= 0
        remove.setAccessibilityLabel("移除占用记录 \(entry.name)")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = horizontalStack([badgePill, name, keys, spacer, remove], spacing: 8)
        pin(content, inside: row, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        return row
    }

    @objc private func addOccupiedAction() {
        guard let shortcut = occupiedRecorder.shortcut else {
            model.reportStatus("请先录制要标记为占用的组合。", tone: .error)
            return
        }
        guard model.addOccupiedHotKey(name: occupiedNameField.stringValue, shortcut: shortcut) else { return }
        occupiedNameField.stringValue = ""
        occupiedRecorder.shortcut = nil
    }

    @objc private func removeOccupiedAction(_ sender: NSButton) {
        let entries = model.occupiedHotKeys
        guard entries.indices.contains(sender.tag) else { return }
        model.removeOccupiedHotKey(entries[sender.tag])
    }

    private func makeBindingRow(_ binding: AppBinding) -> BindingActionRow {
        let row = BindingActionRow()
        let isCard = model.applicationLayout == .cards
        row.isCard = isCard
        row.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
        row.onPress = { [weak self] in self?.chooseReplacement(for: binding.id) }
        row.boxType = .custom
        row.cornerRadius = isCard ? 12 : 8
        row.contentViewMargins = .zero
        row.borderWidth = 1
        row.borderColor = .clear
        row.fillColor = .clear
        row.heightAnchor.constraint(equalToConstant: isCard ? 96 : 52).isActive = true
        row.setAccessibilityLabel("\(binding.target.name) 快捷键设置")
        row.setAccessibilityHelp("点图标、名称或空白处更换应用，保留原快捷键；聚焦后按空格或回车选择，↑↓ 移动到相邻行，删除键移除（会先确认）。")
        row.toolTip = "更换 \(binding.target.name)，保留\(binding.shortcut?.displayName ?? "未设置的快捷键")"
        row.onRequestDelete = { [weak self] in self?.confirmRemoval(of: binding) }
        row.onArrow = { [weak self, weak row] isDown in
            guard let self, let row else { return }
            self.moveRowFocus(from: row, isDown: isDown)
        }
        if isCard {
            row.onHorizontalArrow = { [weak self, weak row] isRight in
                guard let self, let row else { return }
                self.moveRowFocus(from: row, isDown: isRight, horizontal: true)
            }
        }

        let icon = NSImageView()
        let iconSize: CGFloat = isCard ? 28 : 32
        icon.image = sizedApplicationIcon(at: binding.target.path, pointSize: iconSize)
        icon.imageScaling = .scaleNone
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.setAccessibilityLabel("\(binding.target.name) 图标")

        let name = isCard ? NSTextField(wrappingLabelWithString: binding.target.name)
                          : NSTextField(labelWithString: binding.target.name)
        name.font = .systemFont(ofSize: isCard ? 12 : 13, weight: .semibold)
        name.maximumNumberOfLines = isCard ? 2 : 1
        name.lineBreakMode = isCard ? .byWordWrapping : .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = row.toolTip
        let switchIndicator = NSImageView()
        switchIndicator.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        switchIndicator.contentTintColor = .secondaryLabelColor
        switchIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        switchIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        switchIndicator.setAccessibilityElement(false)

        let attention = model.rowStatusAttention(for: binding)
        let statusLine = NSTextField(labelWithString: attention?.text ?? "")
        statusLine.font = .systemFont(ofSize: 10.5)
        statusLine.textColor = attention?.color ?? .secondaryLabelColor
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLine.isHidden = attention == nil
        if let attention { statusLine.setAccessibilityLabel("\(binding.target.name) \(attention.text)") }
        row.statusLine = statusLine

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let recorder = ShortcutRecorderButton(frame: .zero)
        recorder.shortcut = binding.shortcut
        recorder.onRecord = { [weak self] shortcut in
            self?.model.applyShortcut(shortcut, for: binding.id) == true
        }
        recorder.onClear = { [weak self] in
            self?.model.clearShortcut(for: binding.id) == true
        }
        recorder.onInvalid = { [weak self] message in
            self?.model.reportStatus(message, tone: .error)
        }
        recorder.controlSize = .small
        recorder.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        recorder.widthAnchor.constraint(equalToConstant: isCard ? 92 : 108).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        recorder.setAccessibilityLabel("\(binding.target.name) 快捷键录制")
        if let native = VerifiedLaunchHotKeys.shortcut(for: binding.target.bundleIdentifier) {
            recorder.toolTip = "应用自带 \(native.displayName)。点此改成 AiGoodChange 热键，改完立即生效。"
        } else if let recommended = SuggestedToggleApps.shortcut(for: binding.target.bundleIdentifier) {
            recorder.toolTip = "推荐 \(recommended.displayName)。点此录制或改键，改完立即生效。"
        } else {
            recorder.toolTip = "优先推荐 ⌘0–9，用尽后推荐 fn/🌐0–9；系统冲突会阻止或警告"
        }
        if let shortcut = binding.shortcut,
           let warning = model.conflictWarning(for: shortcut) {
            recorder.toolTip = [recorder.toolTip, "⚠︎ \(warning)"]
                .compactMap { $0 }
                .joined(separator: "\n")
        }

        let moreButton = NSButton()
        moreButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "更多"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        moreButton.bezelStyle = .inline
        moreButton.isBordered = false
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.target = self
        moreButton.action = #selector(showRowMenu(_:))
        moreButton.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
        moreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        moreButton.setAccessibilityLabel("\(binding.target.name) 的更多操作")
        moreButton.setAccessibilityHelp("打开菜单：更换应用并保留快捷键、呼出应用、切换未运行时打开、查看快捷键说明，或移除这个应用。")
        moreButton.setAccessibilityRole(.button)
        moreButton.toolTip = "更多操作：更换应用、呼出、自动打开、说明、移除"

        if isCard {
            let body = NSView()
            pin(body, inside: row.contentView ?? row,
                insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
            let identity = horizontalStack([icon, name, switchIndicator], spacing: 6)
            identity.alignment = .centerY
            let controls = horizontalStack([recorder, spacer, moreButton], spacing: 8)
            controls.alignment = .centerY
            for view in [identity, statusLine, controls] {
                view.translatesAutoresizingMaskIntoConstraints = false
                body.addSubview(view)
            }
            // Keep optical centers and the action baseline independent of name
            // wrapping or warning visibility. Normalized icons share one box.
            NSLayoutConstraint.activate([
                identity.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                identity.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                identity.topAnchor.constraint(equalTo: body.topAnchor),
                identity.heightAnchor.constraint(equalToConstant: 32),
                statusLine.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                statusLine.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                statusLine.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 2),
                statusLine.heightAnchor.constraint(equalToConstant: 13),
                controls.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                controls.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                controls.heightAnchor.constraint(equalToConstant: 26)
            ])
        } else {
            let labels = verticalStack([name, statusLine], spacing: 2)
            let rowStack = horizontalStack([icon, labels, switchIndicator, spacer, recorder, moreButton], spacing: 8)
            rowStack.alignment = .centerY
            pin(rowStack, inside: row.contentView ?? row,
                insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        }
        row.recorderButton = recorder
        onBindingRowBuilt?(row)
        return row
    }

    private func makeGuideSectionHeader(_ symbol: String, _ title: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let row = horizontalStack([icon, label], spacing: 6)
        row.alignment = .centerY
        row.setAccessibilityLabel("快捷键分组：\(title)")
        return row
    }

    private func makeSystemShortcutItem(_ item: (String, String, String)) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: item.1)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let keys = NSTextField(labelWithString: item.2)
        keys.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        keys.textColor = .secondaryLabelColor

        let row = horizontalStack([icon, title, spacer, keys], spacing: 8)
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.setAccessibilityLabel("\(item.1)，\(item.2)")
        return row
    }

    private func makeApplicationShortcutRow(
        bundleIdentifier: String,
        name: String,
        shortcuts: [(String, String)]
    ) -> NSView? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }

        let icon = NSImageView()
        icon.image = sizedApplicationIcon(at: applicationURL.path, pointSize: 32)
        icon.imageScaling = .scaleNone
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        icon.setAccessibilityLabel("\(name) 图标")

        let appName = NSTextField(labelWithString: name)
        appName.font = .systemFont(ofSize: 13, weight: .semibold)
        appName.widthAnchor.constraint(equalToConstant: 76).isActive = true

        let tipViews = shortcuts.map { action, keys -> NSView in
            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = .systemFont(ofSize: 11.5)
            actionLabel.textColor = .secondaryLabelColor
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let keyLabel = NSTextField(labelWithString: keys)
            keyLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
            let tip = horizontalStack([actionLabel, spacer, keyLabel], spacing: 8)
            tip.alignment = .centerY
            tip.setAccessibilityLabel("\(name)，\(action)，\(keys)")
            return tip
        }
        var columns = tipViews
        if columns.count == 1 {
            columns.append(NSView())
        }
        let tips = horizontalStack(columns, spacing: 18)
        tips.distribution = .fillEqually
        let row = horizontalStack([icon, appName, tips], spacing: 10)
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func pin(_ view: NSView, inside container: NSView, insets: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
    }

    @objc fileprivate func chooseApplication() {
        if scopeControl.selectedSegment == ApplicationListScope.occupied.rawValue {
            showOccupiedEditor()
            return
        }
        guard window.attachedSheet == nil else { return }
        if addPopover.isShown {
            addPopover.performClose(nil)
            return
        }
        pendingReplacementID = nil
        let excluded = Set(model.bindings.map(\.target.bundleIdentifier)).union(QuickToggleModel.ownBundleIdentifiers)
        pendingPicker.reload(excluding: excluded)
        addPopover.contentSize = NSSize(width: 300, height: 336)
        addPopover.show(relativeTo: addButton.bounds, of: addButton, preferredEdge: .maxY)
    }

    private func chooseReplacement(for bindingID: UUID) {
        guard window.attachedSheet == nil,
              let binding = model.bindings.first(where: { $0.id == bindingID }),
              let row = bindingRowCache[bindingID]?.row else { return }
        addPopover.performClose(nil)
        pendingReplacementID = bindingID
        let excluded = Set(model.bindings.map(\.target.bundleIdentifier)).union(QuickToggleModel.ownBundleIdentifiers)
        pendingPicker.reload(excluding: excluded, replacing: binding)
        addPopover.contentSize = NSSize(width: 340, height: 336)
        addPopover.show(relativeTo: NSRect(x: 10, y: 0, width: min(200, row.bounds.width), height: row.bounds.height),
                        of: row, preferredEdge: .maxY)
    }

    fileprivate func completeApplicationSelection(url: URL, replacing bindingID: UUID?) {
        if let bindingID {
            if model.replaceTarget(for: bindingID, with: url) { revealBinding(bindingID) }
        } else if let outcome = model.addTarget(url: url) {
            revealBinding(outcome.bindingID)
        }
    }

    private func chooseApplicationFromDisk(replacing bindingID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = bindingID == nil ? "添加要呼出的应用" : "更换应用，保留原快捷键"
        panel.prompt = bindingID == nil ? "添加" : "更换"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completeApplicationSelection(url: url, replacing: bindingID)
    }

    @objc fileprivate func changeTheme(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        model.selectTheme(id)
    }

    /// Builds the per-row "更多…" menu: always discoverable, keyboard and
    /// VoiceOver reachable, with the 未运行时打开 checkbox state readable.
    fileprivate func makeRowMenu(for binding: AppBinding) -> NSMenu {
        let rawValue = binding.id.uuidString
        let menu = NSMenu()

        let replaceItem = NSMenuItem(title: "更换应用…", action: #selector(replaceApplicationFromMenu(_:)), keyEquivalent: "")
        replaceItem.target = self
        replaceItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
        replaceItem.toolTip = "选择其他 App，保留这一行的快捷键。"
        menu.addItem(replaceItem)
        let revealItem = NSMenuItem(title: "呼出 / 恢复应用", action: #selector(revealApplicationFromMenu(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
        menu.addItem(revealItem)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "未运行时打开",
            action: #selector(toggleLaunchIfNeededFromMenu(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
        launchItem.state = binding.launchIfNeeded ? .on : .off
        launchItem.toolTip = "呼出时若应用未运行，自动启动它。"
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let helpItem = NSMenuItem(
            title: "快捷键说明",
            action: #selector(showBindingHelpFromMenu(_:)),
            keyEquivalent: ""
        )
        helpItem.target = self
        helpItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
        menu.addItem(helpItem)

        if !ShortcutProbe.appIsPresent(bundleIdentifier: binding.target.bundleIdentifier, path: binding.target.path) {
            menu.addItem(.separator())
            let relocateItem = NSMenuItem(
                title: "重新选择应用位置…",
                action: #selector(relocateBindingFromMenu(_:)),
                keyEquivalent: ""
            )
            relocateItem.target = self
            relocateItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
            relocateItem.toolTip = "原位置找不到这个应用；重新选择后保留原快捷键和设置。"
            menu.addItem(relocateItem)
        }

        menu.addItem(.separator())
        let removeItem = NSMenuItem(
            title: "移除…",
            action: #selector(removeBindingFromMenu(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.identifier = NSUserInterfaceItemIdentifier(rawValue)
        menu.addItem(removeItem)
        return menu
    }

    @objc private func showRowMenu(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let binding = model.bindings.first(where: { $0.id == id }) else { return }
        makeRowMenu(for: binding)
            .popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY - 4), in: sender)
    }

    @objc fileprivate func toggleLaunchIfNeededFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.identifier?.rawValue, let id = UUID(uuidString: rawValue) else { return }
        model.toggleLaunchIfNeeded(for: id)
    }

    @objc private func showBindingHelpFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let binding = model.bindings.first(where: { $0.id == id }),
              let row = displayedBindingRows
                  .first(where: { $0.identifier?.rawValue == rawValue }) else { return }
        if helpPopover.isShown { helpPopover.performClose(nil) }
        let controller = NSViewController()
        controller.view = BindingHelpContent.view(for: binding)
        helpPopover.contentViewController = controller
        helpPopover.contentSize = controller.view.fittingSize
        helpPopover.show(relativeTo: row.bounds, of: row, preferredEdge: .minX)
    }

    @objc private func relocateBindingFromMenu(_ sender: NSMenuItem) {
        chooseApplicationFromDisk()
    }

    @objc private func replaceApplicationFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        chooseReplacement(for: id)
    }

    @objc private func revealApplicationFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        model.handleHotKey(id)
    }

    @objc private func removeBindingFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let binding = model.bindings.first(where: { $0.id == id }) else { return }
        confirmRemoval(of: binding)
    }

    private func moveRowFocus(from row: BindingActionRow, isDown: Bool, horizontal: Bool = false) {
        let rows = displayedBindingRows
        guard let index = rows.firstIndex(where: { $0 === row }) else { return }
        let step = horizontal ? 1 : renderedColumns
        let targetIndex = index + (isDown ? step : -step)
        guard rows.indices.contains(targetIndex) else {
            if !isDown {
                window.makeFirstResponder(searchField)
                searchField.selectText(nil)
            }
            return
        }
        if window.makeFirstResponder(rows[targetIndex]) { scrollBindingRowIntoView(rows[targetIndex]) }
    }

    private func confirmRemoval(of binding: AppBinding) {
        let alert = NSAlert()
        alert.messageText = "移除 \(binding.target.name)？"
        alert.informativeText = "会删除这个应用的快捷键设置，不会退出或删除应用。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.removeBinding(binding.id)
    }

    @objc private func toggleEnabled() { model.toggleEnabled() }
    @objc private func requestAccessibility() { model.requestAccessibility() }
    @objc private func toggleLoginAtLaunch() {
        model.setLoginAtLaunch(loginButton.state == .on)
        loginButton.state = model.loginAtLaunchEnabled ? .on : .off
        loginButton.toolTip = model.loginAtLaunchHelp
    }

    @objc private func checkForUpdate() { model.checkForUpdate(userInitiated: true) }
    @objc private func openReleasePage() { model.openReleasePage() }
    @objc private func toggleDailyUpdateCheck() {
        model.setDailyUpdateCheck(dailyUpdateCheckButton.state == .on)
        dailyUpdateCheckButton.state = model.dailyUpdateCheckEnabled ? .on : .off
    }

    private func applyAccessibilityChrome() {
        let reduced = VisualPalette.opaqueSurface()
        for target in [window, preferencesPanel].compactMap({ $0 }) {
            target.isOpaque = reduced
            target.backgroundColor = reduced ? .windowBackgroundColor : .clear
            if let material = target.contentView as? NSVisualEffectView {
                material.state = reduced ? .inactive : .active
                material.material = reduced ? .contentBackground : .hudWindow
                material.subviews.compactMap { $0 as? WindowScrimView }.forEach { $0.updateColors() }
            }
        }
        windowScrimView?.updateColors()
    }

    private func applyTheme() {
        applyAccessibilityChrome()
        scopeControl.selectedSegmentBezelColor = VisualPalette.accent
        func update(_ view: NSView) {
            view.needsDisplay = true
            if let label = view as? NSTextField {
                if label.textColor == .secondaryLabelColor { label.textColor = VisualPalette.secondaryText }
                else if label.textColor == .tertiaryLabelColor { label.textColor = VisualPalette.tertiaryText }
            }
            if let image = view as? NSImageView, image.contentTintColor == .secondaryLabelColor {
                image.contentTintColor = VisualPalette.secondaryText
            }
            if let row = view as? BindingActionRow { row.updateRowColors() }
            if let button = view as? GlassActionButton {
                button.contentTintColor = .labelColor
            }
            view.subviews.forEach(update)
        }
        if let root = window.contentView { update(root) }
        if let root = preferencesPanel?.contentView { update(root) }
        window.invalidateShadow()
    }

    @objc private func toggleGuide() {
        guideExpanded.toggle()
        if guideExpanded { appGuideExpanded = false }
        updateGuideVisibility()
    }

    @objc private func toggleAppGuide() {
        appGuideExpanded.toggle()
        if appGuideExpanded { guideExpanded = false }
        updateGuideVisibility()
    }

    private func updateGuideVisibility() {
        guideCard.isHidden = !guideExpanded
        appGuideCard.isHidden = !appGuideExpanded
        guideButton.image = NSImage(
            systemSymbolName: guideExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        appGuideButton.image = NSImage(
            systemSymbolName: appGuideExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        window.recalculateKeyViewLoop()
    }

    func interfaceLayoutFailures() -> [String] {
        var failures: [String] = []
        for size in [NSSize(width: 560, height: 500), NSSize(width: 640, height: 620), NSSize(width: 1080, height: 760)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let root = window.contentView else { continue }
            for (name, view) in [("search", searchField as NSView), ("add", addButton), ("feedback", statusBanner), ("preferences", preferencesButton), ("theme", themePicker), ("layout", layoutControl), ("enable", enableButton), ("settingsShortcut", settingsShortcutRecorder)] {
                let rect = view.convert(view.bounds, to: root)
                if rect.width < 20 || rect.height < 10 || !root.bounds.insetBy(dx: -1, dy: -1).contains(rect) {
                    failures.append("\(name) clipped at \(Int(size.width))x\(Int(size.height)): \(rect)")
                }
            }
            if abs(bindingsStack.bounds.width - listScroll.contentSize.width) > 1 {
                failures.append("list width did not track viewport at \(Int(size.width))")
            }
            if let first = bindingsStack.arrangedSubviews.first {
                let rowRect = first.convert(first.bounds, to: listScroll.contentView)
                if !listScroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(rowRect) {
                    failures.append("first row starts outside viewport at \(Int(size.width)): \(rowRect), viewport \(listScroll.contentView.bounds)")
                }
            }
        }
        let mainSize = window.frame.size
        guideExpanded = true
        updateGuideVisibility()
        preferencesPanel?.contentView?.layoutSubtreeIfNeeded()
        if window.frame.size != mainSize { failures.append("help expansion resized the application window") }
        guideExpanded = false
        updateGuideVisibility()
        if let raw = ProcessInfo.processInfo.environment["QUICKTOGGLE_RENDER_DIR"], !raw.isEmpty {
            let directory = URL(fileURLWithPath: raw, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                window.setContentSize(NSSize(width: 760, height: 690))
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    guard let root = window.contentView else { continue }
                    root.layoutSubtreeIfNeeded()
                    var imageData: Data?
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        imageData = bitmap.representation(using: .png, properties: [:])
                    }
                    if let imageData { try imageData.write(to: directory.appendingPathComponent("layout-\(name).png")) }
                    else { failures.append("\(name) appearance produced no image") }
                    if let prefsPanel = preferencesPanel, let prefsRoot = prefsPanel.contentView {
                        prefsPanel.appearance = NSAppearance(named: appearance)
                        prefsPanel.setContentSize(NSSize(width: 590, height: 530))
                        prefsRoot.layoutSubtreeIfNeeded()
                        var prefsData: Data?
                        prefsPanel.effectiveAppearance.performAsCurrentDrawingAppearance {
                            guard let bitmap = prefsRoot.bitmapImageRepForCachingDisplay(in: prefsRoot.bounds) else { return }
                            prefsRoot.cacheDisplay(in: prefsRoot.bounds, to: bitmap)
                            prefsData = bitmap.representation(using: .png, properties: [:])
                        }
                        if let prefsData { try prefsData.write(to: directory.appendingPathComponent("layout-prefs-\(name).png")) }
                        else { failures.append("\(name) appearance produced no prefs image") }
                    }
                }
            } catch { failures.append("appearance render failed: \(error)") }
        }
        return failures
    }
}
// MARK: - Menu bar application

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model: QuickToggleModel
    private var statusItem: NSStatusItem?
    private var settings: SettingsController?
    private var settingsPresentation: SettingsController.Presentation?
    private var previousApplication: NSRunningApplication?
    private var lastHotKeyRecovery = Date.distantPast
    private var updateCheckTimer: Timer?
    private var statusMenuGeneration = 0

    override init() {
        #if QUICKTOGGLE_PREVIEW
        model = QuickToggleModel(diagnosticMode: true, previewMode: true)
        #else
        model = QuickToggleModel(diagnosticMode: false)
        #endif
        super.init()
        model.onChange = { [weak self] in self?.refreshInterface() }
        model.onSettingsHotKey = { [weak self] in
            self?.recoverHotKeysIfNeeded()
            self?.toggleSettings()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()
        observeWorkspaceRecovery()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.model.checkForUpdateIfDue()
        }
        updateCheckTimer?.tolerance = 600
        if model.previewMode || model.bindings.isEmpty || model.bindings.allSatisfy({ $0.shortcut == nil }) {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        DispatchQueue.main.async { [weak self] in self?.model.checkForUpdateIfDue() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addMenuItem("打开 AiGoodChange", action: #selector(showSettingsAction), key: ",", to: appMenu)
        addMenuItem("退出 AiGoodChange", action: #selector(quitAction), key: "q", to: appMenu)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recoverHotKeysIfNeeded()
        refreshInterface()
    }
    func applicationDidHide(_ notification: Notification) { releaseSettings() }
    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        model.close()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        statusMenuGeneration += 1
        recoverHotKeysIfNeeded()
        populateStatusMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        let generation = statusMenuGeneration
        // Let the selected item's action finish before dropping menu icons.
        DispatchQueue.main.async { [weak self, weak menu] in
            guard self?.statusMenuGeneration == generation else { return }
            menu?.removeAllItems()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "AiGoodChange")
            button.image?.isTemplate = true
            button.toolTip = "AiGoodChange"
        }
        statusItem = item
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshInterface()
    }

    private func refreshInterface() {
        if settings?.isVisible == true && !NSApp.isHidden { settings?.refresh() }
        if case .available(let latest) = model.updateCheckState {
            statusItem?.button?.toolTip = "AiGoodChange · 发现新版本 \(latest)"
        } else {
            statusItem?.button?.toolTip = "AiGoodChange"
        }
    }

    private static let displayVersion: String = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(appVersion) (build \(build))"
    }()

    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItem("打开 AiGoodChange", action: #selector(showSettingsAction), key: ",", to: menu)
        let state = NSMenuItem(title: model.previewMode ? "界面预览 · 配置副本" : (model.isEnabled ? "\(model.registeredShortcutCount) 个应用快捷键已注册" : "应用快捷键已暂停"), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let version = NSMenuItem(title: "AiGoodChange \(Self.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        let appsItem = NSMenuItem(title: "呼出应用", action: nil, keyEquivalent: "")
        let appsMenu = NSMenu(title: "呼出应用")
        for row in BindingOrder.sorted(model.bindings.map(QuickToggleRow.binding)) {
            guard case .binding(let binding) = row else { continue }
            let item = NSMenuItem(title: "\(binding.target.name)    \(binding.shortcut?.displayName ?? "未设置")", action: #selector(toggleApplicationAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = binding.id.uuidString
            if let icon = NSWorkspace.shared.icon(forFile: binding.target.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            appsMenu.addItem(item)
        }
        appsItem.submenu = appsMenu
        appsItem.isEnabled = !model.bindings.isEmpty
        menu.addItem(appsItem)

        menu.addItem(.separator())
        addMenuItem(model.isEnabled ? "停用全部快捷键" : "启用全部快捷键", action: #selector(toggleEnabledAction), to: menu)
        addMenuItem("申请辅助功能权限", action: #selector(requestAccessibilityAction), to: menu)
        let checkItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdateAction), keyEquivalent: "")
        checkItem.target = self
        checkItem.isEnabled = !model.isUpdateCheckInProgress
        menu.addItem(checkItem)
        if case .available(let latest) = model.updateCheckState {
            addMenuItem("发现新版本 \(latest)，查看发行页…", action: #selector(openReleasePageAction), to: menu)
        }
        addMenuItem("导出配置…", action: #selector(exportConfigurationAction), to: menu)
        addMenuItem("导入配置…", action: #selector(importConfigurationAction), to: menu)
        let detailsItem = NSMenuItem(title: "状态与版本", action: nil, keyEquivalent: "")
        let details = NSMenu(title: "状态与版本")
        details.addItem(version)
        for text in [model.statusMessage, model.updateCheckSummary, model.diagnosticSummary, "打开 AiGoodChange：\(model.settingsShortcut.displayName)"] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            details.addItem(item)
        }
        detailsItem.submenu = details
        menu.addItem(detailsItem)
        menu.addItem(.separator())
        addMenuItem("退出", action: #selector(quitAction), key: "q", to: menu)
    }

    private func addMenuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func showSettings() {
        if settings?.window.isVisible != true,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        if settings == nil {
            let controller = SettingsController(model: model)
            settings = controller
            if let settingsPresentation { controller.restorePresentation(settingsPresentation) }
            controller.onWindowClosed = { [weak self, weak controller] in
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self, let controller, self.settings === controller, !controller.isVisible else { return }
                    self.releaseSettings()
                }
            }
        }
        settings?.show()
    }

    private func releaseSettings() {
        guard let settings else { return }
        settingsPresentation = settings.presentation
        settings.prepareForBackground()
        self.settings = nil
    }

    private func toggleSettings() {
        guard let window = settings?.window, window.isVisible else {
            showSettings()
            return
        }

        let shouldRestoreFocus = NSApp.isActive
        releaseSettings()
        if shouldRestoreFocus,
           let previousApplication,
           !previousApplication.isTerminated {
            _ = previousApplication.activate(options: .activateIgnoringOtherApps)
        }
        previousApplication = nil
    }

    @objc private func showSettingsAction() {
        recoverHotKeysIfNeeded()
        showSettings()
    }
    @objc private func toggleEnabledAction() { model.toggleEnabled() }
    @objc private func toggleApplicationAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        model.handleHotKey(id)
    }
    @objc private func requestAccessibilityAction() { model.requestAccessibility() }
    @objc private func checkForUpdateAction() {
        recoverHotKeysIfNeeded()
        model.checkForUpdate(userInitiated: true)
    }
    @objc private func openReleasePageAction() { model.openReleasePage() }

    @objc private func exportConfigurationAction() {
        let payload = model.exportConfiguration()
        guard let data = ConfigurationExchange.encode(payload) else {
            model.reportStatus("导出失败：无法生成配置文件。", tone: .error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "导出 AiGoodChange 配置"
        panel.message = "备份当前全部应用绑定、设置快捷键与本机占用记录。"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "quicktoggle-backup-\(formatter.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            model.reportStatus("配置已导出：\(url.lastPathComponent)。")
        } catch {
            model.reportStatus("导出失败：无法写入所选位置。", tone: .error)
        }
    }

    @objc private func importConfigurationAction() {
        recoverHotKeysIfNeeded()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "导入 AiGoodChange 配置"
        panel.message = "选择此前导出的 JSON 备份；导入会替换当前绑定。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            model.reportStatus("导入失败：无法读取所选文件。", tone: .error)
            return
        }
        guard let payload = ConfigurationExchange.decode(data) else {
            model.reportStatus("导入失败：这不是有效的 AiGoodChange 配置备份。", tone: .error)
            return
        }
        let (importable, missing) = model.importableBindings(in: payload)
        if importable.isEmpty {
            model.reportStatus(
                missing.isEmpty
                    ? "备份里没有应用绑定，无需导入。"
                    : "备份里的应用（\(missing.joined(separator: "、"))）都不在本机，未导入。",
                tone: .warning
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导入配置并替换当前设置？"
        var detail = "将用备份中的 \(importable.count) 条绑定替换当前 \(model.bindings.count) 条；设置快捷键、启用状态和本机占用记录一并替换。"
        if !missing.isEmpty {
            detail += "缺失应用将跳过：\(missing.joined(separator: "、"))。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = model.applyImportedConfiguration(payload)
    }

    @objc private func quitAction() { NSApp.terminate(nil) }

    private func observeWorkspaceRecovery() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(handleWorkspaceRecovery),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleWorkspaceRecovery),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleWorkspaceRecovery),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleWorkspaceRecovery),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func handleWorkspaceRecovery() {
        recoverHotKeysIfNeeded(force: true)
        model.checkForUpdateIfDue()
    }

    private func recoverHotKeysIfNeeded(force: Bool = false) {
        if relaunchIfOnDiskBuildIsNewer() { return }
        if !force, Date().timeIntervalSince(lastHotKeyRecovery) < 2 { return }
        lastHotKeyRecovery = Date()
        model.recoverHotKeys()
    }

    private func relaunchIfOnDiskBuildIsNewer() -> Bool {
        guard let launched = NSRunningApplication.current.launchDate,
              let executable = Bundle.main.executableURL,
              let modified = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified.timeIntervalSince(launched) > 2 else { return false }
        let appPath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 0.4; /usr/bin/open \"\(appPath)\""]
        do {
            try process.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Runnable self-test

private enum SelfTest {
    static func runComponentSmoke() -> Bool {
        let model = QuickToggleModel(diagnosticMode: true)
        defer { model.close() }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "诊断：\(model.diagnosticSummary)", action: nil, keyEquivalent: ""))
        let binding = AppBinding(
            id: UUID(),
            target: TargetApplication(
                bundleIdentifier: "com.quicktoggle.smoke",
                name: "Smoke",
                path: "/Applications/Smoke.app"
            ),
            shortcut: Shortcut(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(cmdKey | shiftKey),
                label: "K"
            ),
            launchIfNeeded: true
        )
        let payload = ConfigurationExchange.makePayload(
            bindings: [binding],
            settingsShortcut: model.settingsShortcut,
            enabled: model.isEnabled,
            launchIfNeeded: true,
            importedVerifiedLaunchIDs: [],
            importedSuggestedAppIDs: [],
            occupiedHotKeys: [],
            appVersion: "smoke"
        )
        let roundTrip = ConfigurationExchange.encode(payload).flatMap(ConfigurationExchange.decode)
        let passed = menu.items.count == 1
            && menu.items[0].title.contains("诊断：0 个应用")
            && model.settingsShortcut.displayName == "⌘3"
            && roundTrip == payload
        print(passed ? "Menu/model smoke passed" : "Menu/model smoke failed")
        return checkDigitFixtureMapping() && checkBindingRowInteraction() && checkAddRevealBehavior()
            && checkUpdateCheckLogic() && checkFocusRecoveryAndReassociation()
            && checkApplicationReplacementAndFinderBinding()
            && checkRowStructureAndMoreMenu() && checkStateAndKeyboardTransitions()
            && checkScaleAndRecovery() && checkThemeSelection() && checkCompactLayouts()
            && checkBackgroundUIRelease() && passed
    }

    private static func checkBackgroundUIRelease() -> Bool {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("qt-background-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let app = makeFixtureApp(named: "BackgroundFixture", bundleID: "test.background.fixture", in: fixtureRoot)
        let bindings = makeScaleBindings(28, bundleID: "test.background.fixture", path: app.path)
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        model.selectApplicationLayout(.cards)
        defer { model.close() }
        var passed = true
        var presentation: SettingsController.Presentation?
        for _ in 0..<3 {
            weak var releasedController: SettingsController?
            weak var releasedRow: BindingActionRow?
            autoreleasepool {
                let controller = SettingsController(model: model)
                releasedController = controller
                if let presentation { controller.restorePresentation(presentation) }
                for query in ["规模应用 1", "", "规模应用 2", "", "规模应用 1"] {
                    controller.searchField.stringValue = query
                    controller.rebuildBindingRows()
                    controller.window.contentView?.layoutSubtreeIfNeeded()
                }
                releasedRow = controller.displayedBindingRows.first
                passed = releasedRow != nil && passed
                controller.window.makeFirstResponder(releasedRow?.recorderButton)
                presentation = controller.presentation
                controller.prepareForBackground()
                passed = controller.displayedBindingRows.isEmpty && controller.window.contentView == nil && passed
            }
            passed = releasedController == nil && releasedRow == nil && passed
        }
        let restored = SettingsController(model: model)
        if let presentation { restored.restorePresentation(presentation) }
        passed = restored.searchField.stringValue == "规模应用 1" && !restored.displayedBindingRows.isEmpty
            && restored.displayedBindingRows.allSatisfy(\.isCard) && model.bindings == bindings && passed
        print(passed ? "Background UI release passed (controllers, cards, reopen state, unchanged bindings)"
              : "Background UI release FAILED")
        return passed
    }

    private static func checkCompactLayouts() -> Bool {
        var failures: [String] = []
        func require(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("qt-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let app = makeFixtureApp(named: "LayoutFixture", bundleID: "test.layout.fixture", in: fixtureRoot)
        var bindings = makeScaleBindings(50, bundleID: "test.layout.fixture", path: app.path)
        for (index, name) in ["Muse", "Adobe Photoshop 2026", "一个很长的应用名称用于检查换行"].enumerated() {
            bindings[index].target = TargetApplication(bundleIdentifier: "test.layout.fixture", name: name, path: app.path)
        }
        func textFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        let originalTheme = model.themeIdentifier
        for layout in [ApplicationLayout.cards, .list, .cards] {
            controller.layoutControl.selectedSegment = layout == .cards ? 0 : 1
            controller.changeLayout(controller.layoutControl)
            for width: CGFloat in [560, 640, 920] {
                controller.window.setContentSize(NSSize(width: width, height: 620))
                controller.window.contentView?.layoutSubtreeIfNeeded()
                controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: controller.window))
                controller.window.contentView?.layoutSubtreeIfNeeded()
                let rows = controller.displayedBindingRows
                require(rows.count == bindings.count, "\(layout) lost apps at \(width)")
                require(rows.allSatisfy { $0.isCard == (layout == .cards) }, "mixed row types after layout change")
                for row in rows {
                    let frame = row.convert(row.bounds, to: controller.bindingsStack)
                    require(frame.minX >= -1 && frame.maxX <= controller.bindingsStack.bounds.width + 1,
                            "\(layout) horizontal overflow at \(width): \(frame)")
                    if let recorder = row.recorderButton {
                        let recorderFrame = recorder.convert(recorder.bounds, to: row)
                        require(row.bounds.insetBy(dx: -1, dy: -1).contains(recorderFrame),
                                "shortcut clipped at \(width)")
                        if layout == .cards {
                            let more = recorder.superview?.subviews.compactMap { $0 as? NSButton }
                                .first { $0 !== recorder }
                            require(more.map { abs($0.convert($0.bounds, to: row).midY - recorderFrame.midY) < 1 } == true,
                                    "card actions visually misaligned at \(width)")
                            if let name = textFields(in: row).first(where: { $0 !== row.statusLine }) {
                                let nameFrame = name.convert(name.bounds, to: row)
                                require(nameFrame.height <= 33 && !nameFrame.intersects(recorderFrame),
                                        "wrapped name overlaps card actions at \(width)")
                                if width <= 640 && name.stringValue == "Adobe Photoshop 2026" {
                                    require(nameFrame.height > 20, "long card name did not wrap at \(width)")
                                }
                            } else { require(false, "card name missing") }
                        }
                    }
                }
                if layout == .cards, rows.count > 3 {
                    let first = rows[0].convert(rows[0].bounds, to: controller.bindingsStack)
                    let second = rows[1].convert(rows[1].bounds, to: controller.bindingsStack)
                    let third = rows[2].convert(rows[2].bounds, to: controller.bindingsStack)
                    let next = rows[3].convert(rows[3].bounds, to: controller.bindingsStack)
                    require(abs(first.minY - second.minY) < 1 && abs(first.minY - third.minY) < 1
                            && second.minX >= first.maxX + 7 && third.minX >= second.maxX + 7
                            && abs(next.minX - first.minX) < 1 && abs(next.minY - first.minY) >= 103,
                            "cards did not form three aligned columns at \(width)")
                    let actionCenters = rows.prefix(3).compactMap { row in
                        row.recorderButton.map { $0.convert($0.bounds, to: controller.bindingsStack).midY }
                    }
                    require(actionCenters.count == 3 && (actionCenters.max()! - actionCenters.min()!) < 1,
                            "card action baseline changed with name length at \(width)")
                }
                guard let first = rows.first else { continue }
                controller.listScroll.contentView.scroll(to: .zero)
                controller.window.makeFirstResponder(first)
                for _ in 0..<8 {
                    guard let focused = controller.window.firstResponder as? BindingActionRow else { break }
                    focused.onArrow?(true)
                }
                if let focused = controller.window.firstResponder as? BindingActionRow {
                    let frame = focused.convert(focused.bounds, to: controller.listScroll.contentView)
                    require(controller.listScroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                            "arrow focus offscreen in \(layout) at \(width)")
                } else { require(false, "arrow focus lost in \(layout)") }
            }
            require(model.bindings == bindings && model.themeIdentifier == originalTheme,
                    "layout switch changed configuration")
        }
        let visibleRow = controller.displayedBindingRows[0]
        let retainedID = visibleRow.identifier
        let recorder = visibleRow.recorderButton
        controller.window.makeFirstResponder(recorder)
        require(recorder?.onClear?() == true, "card shortcut clear failed")
        let replacement = controller.displayedBindingRows.first { $0.identifier == retainedID }
        require(controller.window.firstResponder === replacement?.recorderButton, "card recorder focus lost after reordering")
        controller.searchField.stringValue = "规模应用 1"
        controller.rebuildBindingRows()
        require(!controller.displayedBindingRows.isEmpty && controller.displayedBindingRows.count < bindings.count, "card search failed")
        controller.searchField.stringValue = ""
        controller.rebuildBindingRows()
        require(controller.displayedBindingRows.count == bindings.count, "card search reset lost apps")
        let suite = "quicktoggle.selftest.layout.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = PreferenceStore(defaults: defaults)
            require(store.applicationLayout == .list, "existing users lost default list")
            store.applicationLayout = .cards
            require(PreferenceStore(defaults: defaults).applicationLayout == .cards, "layout preference not persistent")
        }
        print(failures.isEmpty ? "Compact layouts passed (list/three-column cards, 560/640/920, optical alignment, long names, focus, search, isolated persistence)"
              : "Compact layouts FAILED: \(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    private static func checkThemeSelection() -> Bool {
        let themes = ThemeCatalog.bundled
        var failures: [String] = []
        func require(_ result: Bool, _ message: String) { if !result { failures.append(message) } }
        require(themes.count == 10 && Set(themes.map(\.id)).count == 10, "missing or duplicate theme resources")
        require(themes.allSatisfy { $0.light.isValid && $0.dark.isValid }, "invalid theme colors")
        let originalID = ThemeCatalog.selectedID
        defer { ThemeCatalog.select(originalID) }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [])
        defer { model.close() }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        let bindingsBefore = model.bindings
        for (index, theme) in themes.enumerated() {
            controller.themePicker.selectItem(at: index)
            controller.changeTheme(controller.themePicker)
            require(model.themeIdentifier == theme.id && ThemeCatalog.selectedID == theme.id, "theme selection did not propagate: \(theme.id)")
            for dark in [false, true] {
                let variant = dark ? theme.dark : theme.light
                require(VisualPalette.primary(dark) == VisualPalette.parseColor(variant.accent.primary), "theme accent diverged: \(theme.id)")
                require(VisualPalette.selectionFill(dark) == VisualPalette.parseColor(variant.selection.fill), "selection fill diverged: \(theme.id)")
            }
        }
        for source in themes {
            model.selectTheme(source.id)
            for destination in themes {
                model.selectTheme(destination.id)
                require(ThemeCatalog.selectedID == destination.id, "theme round trip failed")
                require(VisualPalette.primary(true) == VisualPalette.parseColor(destination.dark.accent.primary), "stale cached theme color")
                model.selectTheme(source.id)
            }
        }
        model.selectTheme(themes.last?.id ?? "codexu.default")
        model.selectTheme("invalid.theme")
        require(model.themeIdentifier == themes.last?.id, "invalid selection changed the theme")
        ThemeCatalog.select("invalid.theme")
        require(ThemeCatalog.selectedID == "codexu.default", "invalid saved theme has no fallback")
        require(model.bindings == bindingsBefore && model.registeredShortcutCount == 0, "theme selection modified hotkeys")
        let suite = "quicktoggle.selftest.theme.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = PreferenceStore(defaults: defaults)
            require(preferences.themeIdentifier == "codexu.default", "default theme changed")
            preferences.themeIdentifier = "codexu.forbidden-city-red"
            require(PreferenceStore(defaults: defaults).themeIdentifier == "codexu.forbidden-city-red", "theme preference did not persist")
        } else { require(false, "isolated theme preference suite unavailable") }
        print(failures.isEmpty ? "Theme selection passed (10 themes, 100 pairwise transitions, light/dark, isolated persistence)"
              : "Theme selection FAILED: \(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    /// Offscreen snapshots of the user's read-only configuration copy. This is
    /// a layout/render check, never a claim of live window or Finder acceptance.
    static func renderThemeGallery() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["QUICKTOGGLE_RENDER_DIR"] else { return false }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true)
        defer { model.close() }
        let initialID = model.themeIdentifier
        defer { ThemeCatalog.select(initialID) }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        guard let root = controller.window.contentView else { return false }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for layout in [ApplicationLayout.list, .cards] {
                model.selectApplicationLayout(layout)
                for theme in ThemeCatalog.bundled {
                    model.selectTheme(theme.id)
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                        controller.window.appearance = NSAppearance(named: appearance)
                        for size in [NSSize(width: 560, height: 500), NSSize(width: 640, height: 620)] {
                            controller.window.setContentSize(size)
                            root.layoutSubtreeIfNeeded()
                            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: controller.window))
                            root.layoutSubtreeIfNeeded()
                            var data: Data?
                            controller.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                                root.cacheDisplay(in: root.bounds, to: bitmap)
                                data = bitmap.representation(using: .png, properties: [:])
                            }
                            guard let data else { return false }
                            try data.write(to: directory.appendingPathComponent("\(theme.id)-\(layout.rawValue)-\(name)-\(Int(size.width)).png"))
                        }
                    }
                }
            }
            print("Theme gallery rendered: \(ThemeCatalog.bundled.count) themes × 2 layouts × 2 appearances × 2 sizes; \(model.bindings.count) read-only app bindings")
            return true
        } catch { print("Theme gallery failed: \(error)"); return false }
    }

    private static func checkApplicationReplacementAndFinderBinding() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qt-replacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = makeFixtureApp(named: "Original", bundleID: "test.replace.original", in: root)
        let replacementURL = makeFixtureApp(named: "NewChoice", bundleID: "test.replace.new", in: root)
        let otherURL = makeFixtureApp(named: "Other", bundleID: "test.replace.other", in: root)
        let selfURL = makeFixtureApp(named: "Self", bundleID: "com.quicktoggle.app", in: root)
        let id = UUID()
        let otherID = UUID()
        let bindings = [
            AppBinding(id: id, target: TargetApplication(bundleIdentifier: "test.replace.original", name: "Original", path: originalURL.path),
                       shortcut: digitShortcut(4), launchIfNeeded: false),
            AppBinding(id: otherID, target: TargetApplication(bundleIdentifier: "test.replace.other", name: "Other", path: otherURL.path),
                       shortcut: nil, launchIfNeeded: true)
        ]
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        var failures: [String] = []
        func require(_ result: Bool, _ message: String) { if !result { failures.append(message) } }
        let notifications = NSWorkspace.shared.notificationCenter
        var workspaceEvents = 0
        let observers = [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { _ in workspaceEvents += 1 }
        }
        defer { observers.forEach { notifications.removeObserver($0) } }

        controller.completeApplicationSelection(url: replacementURL, replacing: id)
        let replacement = model.bindings.first { $0.id == id }
        require(model.bindings.count == 2, "replacement changed row count")
        require(replacement?.shortcut == bindings[0].shortcut, "replacement changed the shortcut")
        require(replacement?.launchIfNeeded == false, "replacement changed launch preference")
        require(replacement?.target.bundleIdentifier == "test.replace.new" && replacement?.target.path == replacementURL.path,
                "replacement did not change the target")
        require(replacement?.target.name == "NewChoice", "replacement kept the old display name")
        require(model.bindings[1] == bindings[1], "replacement changed another binding")
        let row = controller.bindingsStack.arrangedSubviews.compactMap { $0 as? BindingActionRow }
            .first { $0.identifier?.rawValue == id.uuidString }
        require(row?.recorderButton?.shortcut == digitShortcut(4), "replacement row lost its recorder")
        require(controller.window.firstResponder === row, "replacement row did not regain focus")
        require(row?.toolTip?.contains("NewChoice") == true, "replacement row kept the old identity")
        let payload = model.exportConfiguration()
        require(ConfigurationExchange.encode(payload).flatMap(ConfigurationExchange.decode) == payload,
                "replacement configuration did not round-trip")
        model.handleHotKey(id)
        require(model.statusMessage.contains("NewChoice"), "hotkey binding still resolved the old target")

        let beforeRejectedSelection = model.bindings
        for url in [otherURL, root.appendingPathComponent("missing.app"), selfURL] {
            require(!model.replaceTarget(for: id, with: url), "invalid or duplicate replacement accepted: \(url.lastPathComponent)")
            require(model.bindings == beforeRejectedSelection, "rejected replacement changed bindings")
        }
        require(!model.replaceTarget(for: UUID(), with: originalURL), "removed binding replacement accepted")
        require(model.bindings == beforeRejectedSelection, "removed binding selection became an add")
        require(model.replaceTarget(for: otherID, with: originalURL), "replacement of unassigned binding failed")
        require(model.bindings[1].shortcut == nil && model.bindings[1].launchIfNeeded, "unassigned replacement got a new key")

        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let beforeFinder = model.bindings
        controller.completeApplicationSelection(url: finderURL, replacing: nil)
        if let finder = model.bindings.first(where: { $0.target.bundleIdentifier == "com.apple.finder" }) {
            require(finder.target.name == "访达", "Finder display name is not searchable in Chinese")
            require(finder.shortcut == nil, "Finder was assigned a key before the user chose it")
            require(model.bindings.filter { $0.id != finder.id } == beforeFinder, "adding Finder changed existing bindings")
            require(model.addTarget(url: finderURL)?.bindingID == finder.id, "duplicate Finder changed binding ID")
            require(model.bindings.count == beforeFinder.count + 1, "duplicate Finder added a second row")
            let finderRow = controller.bindingsStack.arrangedSubviews.compactMap { $0 as? BindingActionRow }
                .first { $0.identifier?.rawValue == finder.id.uuidString }
            require(finderRow?.recorderButton != nil, "Finder has no shortcut recorder")
            require(finderRow?.recorderButton?.onRecord?(digitShortcut(8)) == true, "Finder recorder rejected a valid shortcut")
            require(model.bindings.first { $0.id == finder.id }?.shortcut == digitShortcut(8), "Finder recorder did not save the shortcut")
            model.handleHotKey(finder.id)
            require(model.statusMessage.contains("访达"), "Finder hotkey did not resolve the binding")
            require(model.clearShortcut(for: finder.id), "Finder shortcut could not be cleared")
        } else { require(false, "Finder was not added as a normal app binding") }
        require(model.registeredShortcutCount == 0, "preview registered a global shortcut")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        require(workspaceEvents == 0, "preview launched or activated an application")
        print(failures.isEmpty ? "Application replacement and Finder binding passed"
              : "Application replacement and Finder binding FAILED: \(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    private static func checkUpdateCheckLogic() -> Bool {
        var passed = true
        passed = passed && ReleaseVersion.parse("v1.0.0")?.components == [1, 0, 0]
        passed = passed && ReleaseVersion.parse("1.10.2")?.components == [1, 10, 2]
        passed = passed && ReleaseVersion.parse("v1.2")?.components == [1, 2, 0]
        passed = passed && ReleaseVersion.parse("v01.02.03")?.components == [1, 2, 3]
        passed = passed && ReleaseVersion.parse("v1.0.0-windows-preview.1") == nil
        passed = passed && ReleaseVersion.parse("1.0.0-beta") == nil
        passed = passed && ReleaseVersion.parse("1..0") == nil
        passed = passed && ReleaseVersion.parse("") == nil
        passed = passed && ReleaseVersion.parse("1.-2.0") == nil
        passed = passed && ReleaseVersion.isCurrent("1.0.0", behind: "v1.0.0") == false
        passed = passed && ReleaseVersion.isCurrent("1.0.0", behind: "v1.0.1") == true
        passed = passed && ReleaseVersion.isCurrent("1.10.0", behind: "v1.9.9") == false
        passed = passed && ReleaseVersion.isCurrent("1.0.0", behind: "v2.0.0") == true
        passed = passed && ReleaseVersion.isCurrent("1.0.0", behind: "v1.0.0-windows-preview.1") == nil
        passed = passed && QuickToggleModel.sanitizedUpdateNotes(nil) == nil
        passed = passed && QuickToggleModel.sanitizedUpdateNotes("   \n  \n") == nil
        passed = passed && QuickToggleModel.sanitizedUpdateNotes("## What's Changed\n\n* fix: crash on quit\n") == "What's Changed / fix: crash on quit"
        passed = passed && QuickToggleModel.sanitizedUpdateNotes("---\n\n- adds dark mode\n") == "adds dark mode"
        let overlong = QuickToggleModel.sanitizedUpdateNotes(String(repeating: "字", count: 250))
        passed = passed && overlong?.count == 201 && overlong?.hasSuffix("…") == true
        passed = passed && QuickToggleModel.restoredUpdateState(knownTag: "v1.1.0", currentVersion: "1.0.0") == .available(latest: "v1.1.0")
        passed = passed && QuickToggleModel.restoredUpdateState(knownTag: "v1.0.0", currentVersion: "1.0.0") == .idle
        passed = passed && QuickToggleModel.restoredUpdateState(knownTag: nil, currentVersion: "1.0.0") == .idle
        passed = passed && QuickToggleModel.restoredUpdateState(knownTag: "v1.0.0-windows-preview.1", currentVersion: "1.0.0") == .idle

        let model = QuickToggleModel(diagnosticMode: true)
        defer { model.close() }
        model.completeUpdateCheck(.success(.init(tag: "v999.0.0", notes: "Known release")), userInitiated: false)
        for result: Result<UpdateCheckService.LatestRelease, UpdateCheckService.Failure> in [
            .failure(.transport("offline")), .success(.init(tag: "invalid-tag", notes: nil))
        ] {
            model.beginUpdateCheck()
            passed = model.isUpdateCheckInProgress && model.isUpdateAvailable && passed
            model.completeUpdateCheck(result, userInitiated: true)
            passed = !model.isUpdateCheckInProgress && model.updateCheckState == .available(latest: "v999.0.0")
                && model.updateCheckNotes == "Known release" && passed
        }
        model.beginUpdateCheck()
        model.completeUpdateCheck(.success(.init(tag: appVersion, notes: nil)), userInitiated: false)
        passed = model.updateCheckState == .upToDate && model.updateCheckNotes == nil && passed

        let suiteName = "quicktoggle.selftest.updatecheck"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let store = PreferenceStore(defaults: defaults)
        passed = passed && store.dailyUpdateCheckEnabled == true
        store.dailyUpdateCheckEnabled = false
        passed = passed && store.dailyUpdateCheckEnabled == false
        passed = passed && store.lastUpdateCheckDate == nil
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        store.lastUpdateCheckDate = stamp
        passed = passed && abs((store.lastUpdateCheckDate?.timeIntervalSince1970 ?? 0) - 1_000_000) < 0.001
        store.lastUpdateCheckDate = nil
        passed = passed && store.lastUpdateCheckDate == nil
        passed = passed && store.knownAvailableUpdate == nil
        store.knownAvailableUpdate = "v1.0.1"
        passed = passed && store.knownAvailableUpdate == "v1.0.1"
        store.knownAvailableUpdate = nil
        passed = passed && store.knownAvailableUpdate == nil
        defaults.removePersistentDomain(forName: suiteName)

        print(passed ? "Update check logic passed" : "Update check logic failed")
        return passed
    }

    private static func checkBindingRowInteraction() -> Bool {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        let row = BindingActionRow(frame: NSRect(x: 20, y: 20, width: 580, height: 60))
        row.boxType = .custom
        parent.addSubview(row)
        let name = NSTextField(labelWithString: "Synthetic app")
        name.frame = NSRect(x: 55, y: 20, width: 150, height: 20)
        let icon = NSImageView(frame: NSRect(x: 10, y: 15, width: 32, height: 32))
        let recorder = NSButton(title: "Record", target: nil, action: nil)
        recorder.frame = NSRect(x: 400, y: 15, width: 80, height: 30)
        let checkbox = NSButton(checkboxWithTitle: "Auto open", target: nil, action: nil)
        checkbox.frame = NSRect(x: 220, y: 15, width: 120, height: 30)
        [name, icon, recorder, checkbox].forEach { row.addSubview($0) }
        var firstPresses = 0
        var secondPresses = 0
        row.onPress = { firstPresses += 1 }
        let other = BindingActionRow(frame: NSRect(x: 20, y: 100, width: 580, height: 60))
        other.boxType = .custom
        other.onPress = { secondPresses += 1 }
        parent.addSubview(other)
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ) else { return false }
        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: parent)
        }
        var passed = true
        for point in [center(name), center(icon), row.convert(NSPoint(x: 370, y: 30), to: parent)] {
            let hit = row.hitTest(point)
            passed = (hit === row) && passed
            hit?.mouseDown(with: click)
        }
        passed = firstPresses == 3 && passed
        passed = (row.hitTest(center(recorder)) === recorder) && passed
        passed = (row.hitTest(center(checkbox)) === checkbox) && passed
        passed = row.hitTest(NSPoint(x: -10, y: -10)) == nil && passed
        other.hitTest(center(other))?.mouseDown(with: click)
        passed = secondPresses == 1 && firstPresses == 3 && passed
        row.frame.origin = NSPoint(x: 35, y: 175)
        passed = (row.hitTest(center(name)) === row) && passed
        passed = row.acceptsFirstResponder && row.accessibilityPerformPress() && passed
        for code in [UInt16(kVK_Space), UInt16(kVK_Return)] {
            for repeating in [false, true] {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: repeating, keyCode: code
                ) else { return false }
                row.keyDown(with: event)
            }
        }
        passed = firstPresses == 6 && secondPresses == 1 && passed
        var arrowMoves: [Bool] = []
        row.onArrow = { arrowMoves.append($0) }
        for (code, glyph, expectedDown) in [(UInt16(kVK_DownArrow), "\u{F701}", true), (UInt16(kVK_UpArrow), "\u{F700}", false)] {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: glyph, charactersIgnoringModifiers: glyph,
                isARepeat: false, keyCode: code
            ) else { return false }
            row.keyDown(with: event)
            passed = (arrowMoves.last == expectedDown) && passed
        }
        if let commandArrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: UInt16(kVK_DownArrow)
        ) {
            row.keyDown(with: commandArrow)
        }
        passed = arrowMoves.count == 2 && passed
        row.onArrow = nil
        print(passed ? "Binding row mouse/control/keyboard/accessibility routing passed" : "Binding row interaction failed")
        return passed
    }

    /// Carbon digit key codes are NOT contiguous (1=18, 2=19, 3=20, 4=21,
    /// 5=23, 6=22, 7=26, 8=28, 9=25, 0=29): arithmetic on kVK_ANSI_1 produces
    /// wrong keys from ⌘5 on. Fixtures must use this explicit table.
    private static let fixtureDigitKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    /// ⌘1…⌘9 fixture shortcut for a 1-based digit number.
    private static func digitShortcut(_ number: Int) -> Shortcut {
        Shortcut(
            keyCode: fixtureDigitKeyCodes[number - 1],
            modifiers: UInt32(cmdKey),
            label: String(number)
        )
    }

    /// Asserts the explicit table really maps to the digits its labels claim,
    /// through the real event→shortcut mapping (which reads the key map).
    private static func checkDigitFixtureMapping() -> Bool {
        var passed = true
        for number in 1...9 {
            let shortcut = digitShortcut(number)
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(number),
                charactersIgnoringModifiers: String(number),
                isARepeat: false,
                keyCode: UInt16(fixtureDigitKeyCodes[number - 1])
            )
            let fromEvent = event.flatMap(Shortcut.from(event:))
            if shortcut.validationError != nil
                || fromEvent != shortcut
                || shortcut.displayName != "⌘\(number)" {
                print("Digit fixture mapping FAILED at ⌘\(number): \(fromEvent?.displayName ?? "nil")")
                passed = false
            }
        }
        print(passed ? "Digit fixture mapping passed" : "Digit fixture mapping FAILED")
        return passed
    }

    /// Regression for "add an app and immediately see it": the new row scrolls
    /// into the viewport, flashes briefly and takes keyboard focus without any
    /// row activation, and a hiding filter is lifted with a status note. The
    /// test wires the production onChange → refresh chain so refresh-triggered
    /// row rebuilds are exercised, not skipped.
    private static func checkAddRevealBehavior() -> Bool {
        let bindings = (1...20).map { index in
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.reveal.\(index)",
                    name: "定位测试应用 \(index)",
                    path: "/fixture.app"
                ),
                shortcut: digitShortcut(1 + (index - 1) % 9),
                launchIfNeeded: true
            )
        }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        // Same wiring as AppDelegate, so status callbacks really run refresh().
        model.onChange = { controller.refresh() }
        controller.window.setContentSize(NSSize(width: 600, height: 500))
        controller.window.contentView?.layoutSubtreeIfNeeded()

        // Observable evidence that reveal never launches anything. NSWorkspace
        // notifications must be observed on NSWorkspace.shared.notificationCenter.
        var launchedBundleIDs: [String] = []
        var activationAttempts = 0
        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: nil
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                launchedBundleIDs.append(app.bundleIdentifier ?? "?")
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }

        func row(for id: UUID) -> BindingActionRow? {
            controller.bindingsStack.arrangedSubviews
                .compactMap { $0 as? BindingActionRow }
                .first { $0.identifier?.rawValue == id.uuidString }
        }
        func visibleInViewport(_ view: NSView) -> Bool {
            let rect = view.convert(view.bounds, to: controller.listScroll.contentView)
            return controller.listScroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(rect)
        }
        // Persistent spy via the row-factory seam: every row built by any
        // rebuild gets the counting spy, so activation always flows through
        // the spy — never the production onPress → handleHotKey path — and no
        // rebuild can silently swap it back.
        controller.onBindingRowBuilt = { row in
            row.onPress = { activationAttempts += 1 }
        }
        // Rows built before the seam was installed (the initial refresh inside
        // SettingsController.init) get the spy once here.
        controller.bindingsStack.arrangedSubviews
            .compactMap { $0 as? BindingActionRow }
            .forEach { $0.onPress = { activationAttempts += 1 } }

        var failures: [String] = []
        var passed = true
        func require(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            passed = passed && condition
        }
        func requireRevealedRow(_ id: UUID, path: String) {
            controller.window.contentView?.layoutSubtreeIfNeeded()
            guard let revealed = row(for: id) else {
                require(false, "row missing after reveal (\(path))")
                return
            }
            require(revealed.window === controller.window, "revealed row detached from window (\(path))")
            require(visibleInViewport(revealed), "revealed row not visible in viewport (\(path))")
            require(revealed.isFlashing, "revealed row not flashing (\(path))")
            require(controller.window.firstResponder === revealed, "revealed row not firstResponder (\(path))")
        }

        let last = bindings[19]
        guard let lastRow = row(for: last.id) else {
            print("Add-target reveal behavior FAILED: last row missing")
            return false
        }
        require(!visibleInViewport(lastRow), "row 20 visible before reveal")

        controller.revealBinding(last.id)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        require(visibleInViewport(lastRow), "row 20 not visible after reveal (no filter)")
        require(lastRow.isFlashing, "row 20 not flashing (no filter)")
        require(controller.window.firstResponder === lastRow, "row 20 not firstResponder (no filter)")
        RunLoop.current.run(until: Date().addingTimeInterval(2.6))
        require(!lastRow.isFlashing, "row 20 flash did not clear")

        // A search that hides the target row must be lifted with a note.
        controller.searchField.stringValue = "没有匹配的搜索词"
        controller.rebuildBindingRows()
        require(row(for: last.id) == nil, "search did not hide row 20")
        controller.revealBinding(last.id)
        requireRevealedRow(last.id, path: "search")
        require(controller.searchField.stringValue.isEmpty, "search not cleared")
        require(model.statusMessage.contains("已切回全部应用"), "switch note missing (search)")

        // The 待设置 scope is empty here; revealing must switch back too.
        controller.scopeControl.selectedSegment = ApplicationListScope.needsShortcut.rawValue
        controller.rebuildBindingRows()
        controller.revealBinding(last.id)
        requireRevealedRow(last.id, path: "scope")
        require(controller.scopeControl.selectedSegment == ApplicationListScope.all.rawValue, "scope not reset")

        // Add and re-add a real app bundle; reveal it through the same paths.
        let candidates = [
            URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            URL(fileURLWithPath: "/System/Applications/Preview.app"),
            URL(fileURLWithPath: "/Applications/Safari.app")
        ]
        guard let fixtureURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            failures.append("add/duplicate reveal path NOT COVERED: no system app bundle found")
            print("Add-target reveal behavior FAILED: \(failures.joined(separator: "; "))")
            return false
        }
        guard let fixtureBundleID = Bundle(url: fixtureURL)?.bundleIdentifier else {
            print("Add-target reveal behavior FAILED: fixture has no bundle id (\(fixtureURL.path))")
            return false
        }
        let beforeCount = model.bindings.count
        guard let added = model.addTarget(url: fixtureURL) else {
            print("Add-target reveal behavior FAILED: addTarget returned nil for \(fixtureURL.path)")
            return false
        }
        let addedShortcut = model.bindings.first { $0.id == added.bindingID }?.shortcut
        require(!added.isExisting, "first add reported existing")
        require(model.bindings.count == beforeCount + 1, "binding count did not grow by one")
        controller.refresh()
        controller.revealBinding(added.bindingID)
        requireRevealedRow(added.bindingID, path: "add")

        let duplicate = model.addTarget(url: fixtureURL)
        let duplicateShortcut = model.bindings.first { $0.id == added.bindingID }?.shortcut
        require(duplicate?.isExisting == true, "duplicate add not reported existing")
        require(duplicate?.bindingID == added.bindingID, "duplicate add returned wrong binding")
        require(model.bindings.count == beforeCount + 1, "duplicate add changed binding count")
        require(duplicateShortcut == addedShortcut, "duplicate add changed the assigned shortcut")
        require(model.statusTone == .warning, "duplicate add lost warning tone")
        // Reveal the duplicate while a filter hides it: the earlier warning
        // and the switch note must both survive in the banner.
        controller.searchField.stringValue = "\(model.bindings.last?.target.name ?? "?")不匹配的词"
        controller.rebuildBindingRows()
        controller.revealBinding(added.bindingID)
        requireRevealedRow(added.bindingID, path: "duplicate")
        require(model.statusMessage.contains("已经在列表里"), "duplicate warning text lost")
        require(model.statusMessage.contains("已切回全部应用"), "switch note missing (duplicate)")
        require(model.statusTone == .warning, "filter lift erased the warning tone")

        // Positive control: every row's activation is the counting spy now,
        // so this never reaches handleHotKey or the fixture app.
        // (revealBinding's internal filter reset rebuilds rows, so re-spy.)
        row(for: added.bindingID)?.onPress?()
        require(activationAttempts == 1, "activation spy did not register the positive control")
        require(!launchedBundleIDs.contains(fixtureBundleID), "fixture app was launched (\(fixtureBundleID))")

        print(passed ? "Add-target reveal behavior passed" : "Add-target reveal behavior FAILED: \(failures.joined(separator: "; "))")
        return passed
    }

    /// A minimal but real bundle so the shortcut probe sees the target as
    /// present; metadata only, never launched.
    private static func makeFixtureApp(named name: String, bundleID: String, in root: URL) -> URL {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>\(name)</string>
          <key>CFBundleIdentifier</key><string>\(bundleID)</string>
          <key>CFBundleExecutable</key><string>\(name)</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try? plist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        return appURL
    }

    /// 0927v2 P1 reproduction: keyboard focus must survive the row rebuilds
    /// triggered by a successful record, a clear and a confirmed delete, and
    /// re-selecting a moved app (same bundle ID, dead stored path) must repair
    /// the path instead of being refused as a duplicate. Runs entirely in the
    /// diagnostic/preview domain; no alert is shown and no real app launches.
    private static func checkFocusRecoveryAndReassociation() -> Bool {
        var passed = true
        var failures: [String] = []
        func require(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            passed = passed && condition
        }
        func recorder(in row: BindingActionRow?) -> ShortcutRecorderButton? {
            guard let row else { return nil }
            var queue: [NSView] = [row]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let recorder = view as? ShortcutRecorderButton { return recorder }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
        func allRows(_ stack: NSStackView) -> [BindingActionRow] {
            stack.arrangedSubviews.compactMap { $0 as? BindingActionRow }
        }

        // ---- Risk A: focus across record / clear / delete rebuilds ----------
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0927v2-focus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixtureApp = makeFixtureApp(named: "FocusFixture", bundleID: "test.focus.fixture", in: fixtureRoot)
        let bindings = (1...4).map { index in
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.focus.\(index)",
                    name: "焦点测试应用 \(index)",
                    path: fixtureApp.path
                ),
                shortcut: digitShortcut(index),
                launchIfNeeded: true
            )
        }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        // Same wiring as production: status callbacks rebuild the rows.
        model.onChange = { controller.refresh() }
        controller.window.setContentSize(NSSize(width: 600, height: 500))
        controller.window.contentView?.layoutSubtreeIfNeeded()

        func row(for id: UUID) -> BindingActionRow? {
            allRows(controller.bindingsStack).first { $0.identifier?.rawValue == id.uuidString }
        }

        // Successful record: the rebuild must return focus to the same
        // binding's recorder control.
        let originalRecorder = recorder(in: row(for: bindings[0].id))
        controller.window.makeFirstResponder(originalRecorder)
        let newCombo = Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey), label: "9")
        require(originalRecorder?.onRecord?(newCombo) == true, "record via onRecord did not apply")
        let afterRecord = recorder(in: row(for: bindings[0].id))
        require(afterRecord != nil && afterRecord !== originalRecorder, "recorder was not rebuilt")
        require(controller.window.firstResponder === afterRecord, "focus lost after successful record")

        // Clear (Delete during recording): same rule.
        controller.window.makeFirstResponder(afterRecord)
        require(afterRecord?.onClear?() == true, "clear via onClear did not apply")
        require(model.bindings.first { $0.id == bindings[0].id }?.shortcut == nil, "clear did not unset the shortcut")
        require(controller.window.firstResponder === recorder(in: row(for: bindings[0].id)), "focus lost after clear")

        // Conflict: no rebuild happens, so the same control keeps focus and
        // the shortcut stays unset.
        let conflictRecorder = recorder(in: row(for: bindings[0].id))
        controller.window.makeFirstResponder(conflictRecorder)
        let conflictCombo = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey), label: "2")
        require(conflictRecorder?.onRecord?(conflictCombo) == false, "conflicting combo was accepted")
        require(controller.window.firstResponder === conflictRecorder, "focus lost on conflict")
        require(model.bindings.first { $0.id == bindings[0].id }?.shortcut == nil, "conflict changed the shortcut")

        // Confirmed delete: focus moves to the row that took the deleted
        // slot in display order (the order the user sees). The modal alert
        // itself is skipped; the exercised chain is the same
        // removeBinding → onChange → refresh → rebuild the alert path uses.
        func displayRows() -> [BindingActionRow] { allRows(controller.bindingsStack) }
        func focusedBindingID(_ row: BindingActionRow?) -> UUID? {
            guard let raw = row?.identifier?.rawValue else { return nil }
            return UUID(uuidString: raw)
        }
        func searchFieldFocused() -> Bool {
            controller.window.firstResponder === controller.searchField
                || controller.window.firstResponder === controller.searchField.currentEditor()
        }

        let focusedBeforeDelete = row(for: bindings[1].id)
        let slotIndex = displayRows().firstIndex(where: { $0 === focusedBeforeDelete }) ?? 0
        controller.window.makeFirstResponder(focusedBeforeDelete)
        model.removeBinding(bindings[1].id)
        let rowsAfterDelete = displayRows()
        let expectedRow: BindingActionRow? = rowsAfterDelete.indices.contains(slotIndex)
            ? rowsAfterDelete[slotIndex]
            : rowsAfterDelete.last
        require(controller.window.firstResponder === expectedRow, "focus did not move to the next row after delete")

        // Deleting the focused visually-last row falls back to the previous row.
        let lastRowBefore = displayRows().last
        controller.window.makeFirstResponder(lastRowBefore)
        if let id = focusedBindingID(lastRowBefore) { model.removeBinding(id) }
        require(controller.window.firstResponder === displayRows().last, "focus did not fall back after deleting the last row")

        // Deleting rows down to one keeps focus inside the list; deleting the
        // only remaining row hands focus to the search field.
        while let current = displayRows().first {
            controller.window.makeFirstResponder(current)
            guard let id = focusedBindingID(current) else { break }
            model.removeBinding(id)
            let remaining = displayRows()
            if remaining.isEmpty {
                require(searchFieldFocused(), "empty list did not move focus to the search field")
            } else {
                require(remaining.contains(where: { $0 === controller.window.firstResponder }),
                        "focus left the list during row deletion")
            }
        }
        require(allRows(controller.bindingsStack).isEmpty, "list not empty after removing all bindings")

        // A shortcut edit can move the focused recorder far below the viewport.
        // A later delete must also reveal the row that inherits its focus.
        for scale in [20, 200] {
            let visibleBindings = makeScaleBindings(scale, bundleID: "test.focus.fixture", path: fixtureApp.path)
            let visibleModel = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: visibleBindings)
            let visibleController = SettingsController(model: visibleModel)
            var appendLongStatus = false
            visibleModel.onChange = {
                if appendLongStatus {
                    appendLongStatus = false
                    let callback = visibleModel.onChange
                    visibleModel.onChange = nil
                    visibleModel.appendStatusDetail(String(repeating: " 状态说明会占用更多高度。", count: 20))
                    visibleModel.onChange = callback
                }
                visibleController.refresh()
            }
            visibleController.window.setContentSize(NSSize(width: 600, height: 500))
            visibleController.window.contentView?.layoutSubtreeIfNeeded()
            func visibleRows() -> [BindingActionRow] { allRows(visibleController.bindingsStack) }
            func isVisible(_ row: BindingActionRow?) -> Bool {
                guard let row else { return false }
                let rect = row.convert(row.bounds, to: visibleController.listScroll.contentView)
                return visibleController.listScroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            }
            let movingID = visibleBindings[0].id
            let movingRow = visibleRows().first { $0.identifier?.rawValue == movingID.uuidString }
            let movingRecorder = recorder(in: movingRow)
            visibleController.window.makeFirstResponder(movingRecorder)
            let lateCombo = Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | optionKey), label: "Y")
            require(movingRecorder?.onRecord?(lateCombo) == true, "offscreen record did not apply at \(scale)")
            let movedRow = visibleRows().first { $0.identifier?.rawValue == movingID.uuidString }
            require(visibleController.window.firstResponder === recorder(in: movedRow), "offscreen record lost focus at \(scale)")
            require(isVisible(movedRow), "reordered focused row remained outside viewport at \(scale)")
            let scrolledY = visibleController.listScroll.contentView.bounds.minY
            require(scrolledY > 0, "reordered focused row did not scroll at \(scale)")
            visibleController.refresh()
            require(abs(visibleController.listScroll.contentView.bounds.minY - scrolledY) < 1,
                    "unchanged refresh moved the viewport at \(scale)")

            // Reproduce deletion with a focused row outside the current viewport.
            visibleController.listScroll.contentView.scroll(to: .zero)
            visibleController.listScroll.reflectScrolledClipView(visibleController.listScroll.contentView)
            require(!isVisible(movedRow), "delete fixture row unexpectedly visible at top at \(scale)")
            let deletedIndex = visibleRows().firstIndex(where: { $0 === movedRow }) ?? 0
            visibleModel.removeBinding(movingID)
            let rowsAfterOffscreenDelete = visibleRows()
            let inheritedRow = rowsAfterOffscreenDelete.indices.contains(deletedIndex)
                ? rowsAfterOffscreenDelete[deletedIndex] : rowsAfterOffscreenDelete.last
            require(visibleController.window.firstResponder === inheritedRow, "offscreen delete lost adjacent focus at \(scale)")
            require(isVisible(inheritedRow), "row focused after offscreen delete remained outside viewport at \(scale)")

            visibleController.searchField.stringValue = "规模应用 1"
            visibleController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                                  object: visibleController.searchField))
            require(abs(visibleController.listScroll.contentView.bounds.minY) < 1,
                    "search did not start at the top of its results at \(scale)")
            visibleController.resetListFilter()

            // Editing B while an old firstResponder remains on offscreen A
            // must preserve the viewport the user has scrolled to.
            let focusedA = visibleRows().first!
            let unrelatedB = visibleRows()[scale / 2]
            visibleController.window.makeFirstResponder(focusedA)
            let bRect = unrelatedB.convert(unrelatedB.bounds, to: visibleController.listScroll.contentView)
            visibleController.listScroll.contentView.scroll(to: NSPoint(x: 0, y: bRect.minY))
            visibleController.listScroll.reflectScrolledClipView(visibleController.listScroll.contentView)
            require(!isVisible(focusedA) && isVisible(unrelatedB), "unrelated edit fixture invalid at \(scale)")
            let beforeUnrelatedEditY = visibleController.listScroll.contentView.bounds.minY
            if let bID = unrelatedB.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) {
                visibleModel.toggleLaunchIfNeeded(for: bID)
                require(visibleController.window.firstResponder === focusedA, "unrelated edit changed focus at \(scale)")
                require(abs(visibleController.listScroll.contentView.bounds.minY - beforeUnrelatedEditY) < 1,
                        "unrelated edit jumped to old focus at \(scale)")
            } else {
                require(false, "unrelated edit row has no binding ID at \(scale)")
            }

            // A taller status banner can shrink the list after row rebuilding.
            // Place the focused row at the old viewport's lower edge.
            visibleModel.reportStatus("短状态")
            visibleController.window.contentView?.layoutSubtreeIfNeeded()
            let bottomRow = visibleRows()[scale / 2 + 1]
            let bottomRect = bottomRow.convert(bottomRow.bounds, to: visibleController.listScroll.contentView)
            let beforeViewportHeight = visibleController.listScroll.contentView.bounds.height
            visibleController.listScroll.contentView.scroll(to: NSPoint(
                x: 0, y: bottomRect.maxY - beforeViewportHeight + 2
            ))
            visibleController.listScroll.reflectScrolledClipView(visibleController.listScroll.contentView)
            visibleController.window.makeFirstResponder(recorder(in: bottomRow))
            require(isVisible(bottomRow), "bottom-row fixture not visible before edit at \(scale)")
            if let bottomID = bottomRow.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) {
                appendLongStatus = true
                visibleModel.toggleLaunchIfNeeded(for: bottomID)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                visibleController.window.contentView?.layoutSubtreeIfNeeded()
                let rebuiltBottom = visibleRows().first { $0.identifier?.rawValue == bottomID.uuidString }
                require(visibleController.listScroll.contentView.bounds.height < beforeViewportHeight - 5,
                        "long status did not shrink viewport at \(scale)")
                require(visibleController.window.firstResponder === recorder(in: rebuiltBottom),
                        "bottom-row edit lost focus at \(scale)")
                require(isVisible(rebuiltBottom), "long status clipped focused bottom row at \(scale)")
            } else {
                require(false, "bottom-row fixture has no binding ID at \(scale)")
            }
            visibleModel.close()
        }

        // ---- Risk B: re-association for a moved app -------------------------
        let reassocRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0927v2-reassoc-\(UUID().uuidString)", isDirectory: true)
        let fixtureAppB = makeFixtureApp(named: "Relocated", bundleID: "test.relocated.fixture", in: reassocRoot)
        defer { try? FileManager.default.removeItem(at: reassocRoot) }
        guard Bundle(url: fixtureAppB)?.bundleIdentifier == "test.relocated.fixture" else {
            print("Focus/re-association check FAILED: fixture bundle not readable")
            return false
        }

        let staleID = UUID()
        let stalePath = fixtureRoot.appendingPathComponent("old-home/Relocated.app").path
        let reassociating = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [
            AppBinding(
                id: staleID,
                target: TargetApplication(
                    bundleIdentifier: "test.relocated.fixture",
                    name: "迁移应用",
                    path: stalePath
                ),
                shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey), label: "7"),
                launchIfNeeded: false
            )
        ])
        defer { reassociating.close() }
        let outcome = reassociating.addTarget(url: fixtureAppB)
        require(outcome?.bindingID == staleID, "re-association changed the binding ID")
        require(reassociating.bindings.count == 1, "re-association duplicated the row")
        let repaired = reassociating.bindings[0]
        require(repaired.target.path == fixtureAppB.path, "stale path was not repaired (still \(repaired.target.path))")
        require(repaired.shortcut?.displayName == "⌘7", "re-association lost the shortcut")
        require(repaired.launchIfNeeded == false, "re-association changed 未运行时打开")
        require(repaired.target.name == "迁移应用", "re-association renamed the binding")
        require(reassociating.statusMessage.contains("重新关联"), "re-association message missing: \(reassociating.statusMessage)")

        // Control: a duplicate add with a healthy path stays a warning and
        // changes nothing.
        let healthy = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.relocated.fixture",
                    name: "迁移应用",
                    path: fixtureAppB.path
                ),
                shortcut: nil,
                launchIfNeeded: true
            )
        ])
        defer { healthy.close() }
        let duplicate = healthy.addTarget(url: fixtureAppB)
        require(duplicate?.isExisting == true, "healthy duplicate not reported existing")
        require(healthy.bindings.count == 1, "healthy duplicate added a row")
        require(healthy.statusMessage.contains("已经在列表里"), "healthy duplicate warning lost")
        require(healthy.statusTone == .warning, "healthy duplicate tone lost")

        print(passed
            ? "Focus recovery and re-association passed"
            : "Focus recovery and re-association FAILED: \(failures.joined(separator: "; "))")
        return passed
    }

    /// Shared synthetic list for scale/benchmark fixtures: duplicate display
    /// names, emoji names and 80-character Chinese names included.
    private static func scaleName(_ index: Int) -> String {
        switch index % 20 {
        case 0: return "重复应用名"
        case 7: return "🎯🚀😀 Emoji 应用 \(index)"
        case 13: return String(repeating: "长", count: 80) + "超长名称应用 \(index)"
        default: return "规模应用 \(index)"
        }
    }

    private static func makeScaleBindings(_ count: Int, bundleID: String, path: String) -> [AppBinding] {
        (1...count).map { index in
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: bundleID,
                    name: scaleName(index),
                    path: path
                ),
                shortcut: index % 5 == 0 ? nil : digitShortcut(1 + (index - 1) % 9),
                launchIfNeeded: true
            )
        }
    }

    /// 0927v2 P2: normal rows collapse to「图标＋应用名｜快捷键胶囊｜更多…」;
    /// only actionable problems (missing target, failed registration) expand a
    /// second line. The more menu carries 未运行时打开 with a readable state,
    /// help, relocation for missing apps and removal.
    private static func checkRowStructureAndMoreMenu() -> Bool {
        var passed = true
        var failures: [String] = []
        func require(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            passed = passed && condition
        }
        func texts(in view: NSView) -> [String] {
            var found: [String] = []
            if let label = view as? NSTextField { found.append(label.stringValue) }
            for subview in view.subviews { found.append(contentsOf: texts(in: subview)) }
            return found
        }
        func rows(_ stack: NSStackView) -> [BindingActionRow] {
            stack.arrangedSubviews.compactMap { $0 as? BindingActionRow }
        }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0927v2-structure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixtureApp = makeFixtureApp(named: "StructureFixture", bundleID: "test.structure.fixture", in: fixtureRoot)

        let healthyID = UUID()
        let missingID = UUID()
        let unsetID = UUID()
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [
            AppBinding(
                id: healthyID,
                target: TargetApplication(bundleIdentifier: "test.structure.fixture", name: "结构测试应用甲", path: fixtureApp.path),
                shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), label: "1"),
                launchIfNeeded: false
            ),
            AppBinding(
                id: missingID,
                target: TargetApplication(bundleIdentifier: "test.structure.missing", name: "结构测试应用乙", path: fixtureRoot.appendingPathComponent("gone/乙.app").path),
                shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey), label: "2"),
                launchIfNeeded: true
            ),
            AppBinding(
                id: unsetID,
                target: TargetApplication(bundleIdentifier: "test.structure.fixture", name: "结构测试应用丙", path: fixtureApp.path),
                shortcut: nil,
                launchIfNeeded: true
            )
        ])
        defer { model.close() }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        controller.window.setContentSize(NSSize(width: 600, height: 500))
        controller.window.contentView?.layoutSubtreeIfNeeded()

        func row(for id: UUID) -> BindingActionRow? {
            rows(controller.bindingsStack).first { $0.identifier?.rawValue == id.uuidString }
        }

        // Healthy and unset rows stay single-line: no repeated 待设置/未注册
        // text and no second status line.
        let healthyTexts = texts(in: row(for: healthyID) ?? NSView())
        require(!healthyTexts.contains("找不到目标应用，请重新选择。"), "healthy row shows the missing-app line")
        require(!healthyTexts.contains("已注册") && !healthyTexts.contains("待设置"), "healthy row repeats its state")
        let unsetTexts = texts(in: row(for: unsetID) ?? NSView())
        require(!unsetTexts.contains("待设置") && !unsetTexts.contains("已注册"), "unset row repeats its state")

        // A reused row must reveal a new warning even without a binding change.
        let cachedHealthyRow = row(for: healthyID)
        let movedApp = fixtureRoot.appendingPathComponent("TemporarilyMoved.app")
        do {
            try FileManager.default.moveItem(at: fixtureApp, to: movedApp)
            controller.refresh()
            require(row(for: healthyID) === cachedHealthyRow, "warning refresh unnecessarily rebuilt row")
            require(cachedHealthyRow?.statusLine?.isHidden == false
                    && cachedHealthyRow?.statusLine?.stringValue == "找不到目标应用，请重新选择。", "cached row did not reveal new warning")
            try FileManager.default.moveItem(at: movedApp, to: fixtureApp)
            controller.refresh()
            require(cachedHealthyRow?.statusLine?.isHidden == true, "cached row kept cleared warning")
        } catch { require(false, "warning transition fixture failed: \(error)") }

        // Missing target: the second line carries the sanctioned copy.
        let missingTexts = texts(in: row(for: missingID) ?? NSView())
        require(missingTexts.contains("找不到目标应用，请重新选择。"), "missing row lost the re-select line")

        // More menu: normal rows offer 未运行时打开 (readable state), help and
        // removal; missing rows add the relocation entry.
        let healthy = model.bindings.first { $0.id == healthyID }
        let missing = model.bindings.first { $0.id == missingID }
        guard let healthy, let missing else {
            print("Row structure check FAILED: bindings not found")
            return false
        }
        let healthyMenu = controller.makeRowMenu(for: healthy)
        let healthyTitles = healthyMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        require(healthyTitles == ["更换应用…", "呼出 / 恢复应用", "未运行时打开", "快捷键说明", "移除…"], "healthy row menu wrong: \(healthyTitles)")
        let launchItem = healthyMenu.items.first { $0.title == "未运行时打开" }
        require(launchItem?.state == .off, "未运行时打开 state not readable as off")
        let missingMenu = controller.makeRowMenu(for: missing)
        let missingTitles = missingMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        require(missingTitles == ["更换应用…", "呼出 / 恢复应用", "未运行时打开", "快捷键说明", "重新选择应用位置…", "移除…"], "missing row menu wrong: \(missingTitles)")

        // Toggling 未运行时打开 from the menu keeps the binding and flips the
        // persisted setting through the normal model path.
        if let launchItem {
            controller.toggleLaunchIfNeededFromMenu(launchItem)
            let flipped = model.bindings.first { $0.id == healthyID }?.launchIfNeeded
            require(flipped == true, "menu toggle did not flip 未运行时打开")
        }

        // Row density: 52pt rows at 3pt spacing keep interactive controls at
        // least 24pt on both edges.
        for binding in model.bindings {
            guard let row = row(for: binding.id) else {
                require(false, "row missing for \(binding.target.name)")
                continue
            }
            require(abs(row.frame.height - 52) < 1, "row height is not 52pt: \(row.frame.height)")
            if let recorder = row.recorderButton {
                require(recorder.frame.height >= 24, "recorder below 24pt: \(recorder.frame.height)")
            }
        }

        // Optional offline render for the hub: list with the missing-app
        // line, healthy capsules and the unset capsule, in light and dark.
        // The missing row carries ⌘0 so BindingOrder sorts it to the top and
        // both window sizes show every state.
        if let raw = ProcessInfo.processInfo.environment["QUICKTOGGLE_RENDER_DIR"], !raw.isEmpty {
            let renderRoot = fixtureRoot.appendingPathComponent("render", isDirectory: true)
            let renderApp = makeFixtureApp(named: "RenderFixture", bundleID: "test.render.fixture", in: renderRoot)
            let renderBindings = [
                AppBinding(
                    id: UUID(),
                    target: TargetApplication(bundleIdentifier: "test.render.missing", name: "已搬走的示例应用", path: renderRoot.appendingPathComponent("gone/搬迁.app").path),
                    shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey), label: "0"),
                    launchIfNeeded: true
                )
            ]
            + (1...4).map { index in
                AppBinding(
                    id: UUID(),
                    target: TargetApplication(bundleIdentifier: "test.render.fixture", name: "示例应用 \(index) · A Long Application Title", path: renderApp.path),
                    shortcut: digitShortcut(index),
                    launchIfNeeded: true
                )
            }
            + [
                AppBinding(
                    id: UUID(),
                    target: TargetApplication(bundleIdentifier: "test.render.fixture", name: "还没录键的示例应用", path: renderApp.path),
                    shortcut: nil,
                    launchIfNeeded: true
                )
            ]
            let renderModel = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: renderBindings)
            defer { renderModel.close() }
            let renderController = SettingsController(model: renderModel)
            if let root = renderController.window.contentView {
                let directory = URL(fileURLWithPath: raw, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for size in [NSSize(width: 600, height: 500), NSSize(width: 760, height: 690)] {
                    renderController.window.setContentSize(size)
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                        renderController.window.appearance = NSAppearance(named: appearance)
                        root.layoutSubtreeIfNeeded()
                        var imageData: Data?
                        renderController.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            imageData = bitmap.representation(using: .png, properties: [:])
                        }
                        if let imageData {
                            try? imageData.write(to: directory.appendingPathComponent("list-\(Int(size.width))-\(name).png"))
                        }
                    }
                }
            }
        }

        print(passed
            ? "Row structure and more menu passed"
            : "Row structure and more menu FAILED: \(failures.joined(separator: "; "))")
        return passed
    }

    /// 专项3 (0927v2): state and keyboard transitions around the recorder and
    /// row lifecycle — the full event-path recording (begin → key → rebuild),
    /// Esc cancel, invalid keys, conflict finish, rapid refresh chains, stale
    /// row deallocation (observer cleanup), filter switches and the enable
    /// toggle. Preview/diagnostic only; no system state is touched.
    private static func checkStateAndKeyboardTransitions() -> Bool {
        var passed = true
        var failures: [String] = []
        func require(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            passed = passed && condition
        }
        func keyEvent(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }
        func drain() {
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0927v2-states-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixtureApp = makeFixtureApp(named: "StatesFixture", bundleID: "test.states.fixture", in: fixtureRoot)
        // Carbon digit key codes are not contiguous; use explicit constants so
        // the conflict probe below really matches binding 2's shortcut.
        let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        let bindings = (1...3).map { index in
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.states.\(index)",
                    name: "状态测试应用 \(index)",
                    path: fixtureApp.path
                ),
                shortcut: Shortcut(
                    keyCode: UInt32(digitKeyCodes[index - 1]),
                    modifiers: UInt32(cmdKey),
                    label: "\(index)"
                ),
                launchIfNeeded: true
            )
        }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        model.onChange = { controller.refresh() }
        controller.window.setContentSize(NSSize(width: 600, height: 500))
        controller.window.contentView?.layoutSubtreeIfNeeded()

        func row(for id: UUID) -> BindingActionRow? {
            controller.bindingsStack.arrangedSubviews
                .compactMap { $0 as? BindingActionRow }
                .first { $0.identifier?.rawValue == id.uuidString }
        }
        func recorderFocused() -> Bool {
            controller.window.firstResponder === row(for: bindings[0].id)?.recorderButton
        }
        func shortcut(of binding: AppBinding) -> String? {
            model.bindings.first { $0.id == binding.id }?.shortcut?.displayName
        }
        func beginRecording(_ recorder: ShortcutRecorderButton?) {
            guard let recorder else {
                require(false, "recorder missing for beginRecording")
                return
            }
            _ = NSApp.sendAction(recorder.action!, to: recorder.target, from: recorder)
        }

        // 1. Begin recording through the real action path.
        let rec0 = row(for: bindings[0].id)?.recorderButton
        beginRecording(rec0)
        require(controller.window.firstResponder === rec0, "beginRecording did not take firstResponder")
        require(rec0?.title == "请按组合键…", "beginRecording did not switch to recording title")

        // 2. Record success through the real keyDown path (⌘9): the rebuild
        // must return focus to the rebuilt recorder.
        rec0?.keyDown(with: keyEvent(UInt16(kVK_ANSI_9), [.command], "9"))
        let rebuilt0 = row(for: bindings[0].id)?.recorderButton
        require(rebuilt0 != nil && rebuilt0 !== rec0, "event-path record did not rebuild")
        require(controller.window.firstResponder === rebuilt0, "focus lost after event-path record")
        require(rebuilt0?.title == "⌘9", "recorded title wrong: \(rebuilt0?.title ?? "?")")
        require(shortcut(of: bindings[0]) == "⌘9", "event-path record did not apply ⌘9")

        // 3. Esc cancels: keep the old shortcut, exit recording, keep focus,
        // and do not rebuild.
        beginRecording(rebuilt0)
        rebuilt0?.keyDown(with: keyEvent(UInt16(kVK_Escape), [], "\u{1B}"))
        require(rebuilt0?.title == "⌘9", "Esc did not restore the title")
        require(shortcut(of: bindings[0]) == "⌘9", "Esc changed the shortcut")
        require(controller.window.firstResponder === rebuilt0, "Esc lost focus")
        require(row(for: bindings[0].id)?.recorderButton === rebuilt0, "Esc triggered a rebuild")

        // 4. Unsupported key keeps recording and reports, without rebuild.
        beginRecording(rebuilt0)
        rebuilt0?.keyDown(with: keyEvent(UInt16(kVK_CapsLock), [], " "))
        require(rebuilt0?.title == "请按组合键…", "invalid key exited recording")
        require(controller.window.firstResponder === rebuilt0, "invalid key lost focus")
        require(row(for: bindings[0].id)?.recorderButton === rebuilt0, "invalid key triggered a rebuild")
        rebuilt0?.keyDown(with: keyEvent(UInt16(kVK_Escape), [], "\u{1B}"))

        // 5. Conflict: exits recording, keeps the original key, keeps focus.
        beginRecording(rebuilt0)
        rebuilt0?.keyDown(with: keyEvent(UInt16(kVK_ANSI_2), [.command], "2"))
        require(rebuilt0?.title == "⌘9", "conflict did not restore the title")
        require(shortcut(of: bindings[0]) == "⌘9", "conflict changed the shortcut")
        require(controller.window.firstResponder === rebuilt0, "conflict lost focus")
        require(row(for: bindings[0].id)?.recorderButton === rebuilt0, "conflict triggered a rebuild")

        // 6. Delete during recording clears through the real path and returns
        // focus to the rebuilt recorder.
        beginRecording(rebuilt0)
        rebuilt0?.keyDown(with: keyEvent(UInt16(kVK_Delete), [], "\u{7F}"))
        let afterClear = row(for: bindings[0].id)?.recorderButton
        require(afterClear != nil && afterClear !== rebuilt0, "clear did not rebuild")
        require(shortcut(of: bindings[0]) == nil, "clear did not unset the shortcut")
        require(afterClear?.title == "未设置", "cleared title wrong: \(afterClear?.title ?? "?")")
        require(controller.window.firstResponder === afterClear, "focus lost after clear")

        // 7. Rapid refresh chain: record → clear → record back-to-back, then
        // unchanged refreshes must NOT rebuild rows.
        require(afterClear?.onRecord?(Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey), label: "5")) == true, "rapid record 1 failed")
        require(row(for: bindings[0].id)?.recorderButton?.onClear?() == true, "rapid clear failed")
        require(afterClear?.onRecord?(Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey), label: "5")) == true, "rapid record 2 failed")
        require(shortcut(of: bindings[0]) == "⌘5", "rapid chain lost the shortcut")
        require(recorderFocused(), "focus lost in rapid chain")
        var stableRow: BindingActionRow? = row(for: bindings[1].id)
        controller.refresh()
        controller.refresh()
        controller.refresh()
        require(row(for: bindings[1].id) === stableRow, "unchanged refresh rebuilt rows")
        require(recorderFocused(), "unchanged refresh disturbed focus")

        // 8. Filter switch that hides the focused row must leave focus on a
        // valid target and restore it afterwards.
        controller.window.makeFirstResponder(row(for: bindings[0].id))
        controller.scopeControl.selectedSegment = ApplicationListScope.occupied.rawValue
        controller.changeScope()
        drain()
        require(controller.searchField.currentEditor() != nil
            || controller.window.firstResponder === controller.searchField,
            "occupied scope did not hand focus to the search field")
        controller.resetListFilter()
        drain()
        require(row(for: bindings[0].id) != nil, "resetListFilter did not restore the rows")

        // 9. Preview enable toggle keeps bindings (and rows) untouched.
        let focusedBeforeToggle = row(for: bindings[0].id)?.recorderButton
        controller.window.makeFirstResponder(focusedBeforeToggle)
        model.toggleEnabled()
        require(row(for: bindings[0].id)?.recorderButton === focusedBeforeToggle, "enable toggle rebuilt rows")
        require(controller.window.firstResponder === focusedBeforeToggle, "enable toggle lost focus")
        model.toggleEnabled()

        // 10. After a rebuild no stale row may remain in the live hierarchy.
        // (Full deallocation cannot be asserted here: rows built by earlier
        // synchronous rebuilds carry pending autoreleases in the outermost
        // pool, which a synchronous test never drains. Actual row-churn
        // memory behavior is covered by the 0/1/50/200 scale check.)
        stableRow = nil
        autoreleasepool { model.removeBinding(bindings[2].id) }
        drain()
        let staleRowsInStack = controller.bindingsStack.arrangedSubviews
            .compactMap { $0 as? BindingActionRow }
            .filter { $0.identifier?.rawValue == bindings[2].id.uuidString }
        require(staleRowsInStack.isEmpty, "stale row stayed in the stack after rebuild")
        require(model.bindings.count == 2, "removeBinding did not shrink the model")

        print(passed
            ? "State and keyboard transitions passed"
            : "State and keyboard transitions FAILED: \(failures.joined(separator: "; "))")
        return passed
    }

    /// 专项4 (0927v2): 0/1/50/200 synthetic bindings — counts, empty states,
    /// search, duplicate/emoji/very-long Chinese names, reveal at scale,
    /// repeated refresh stability, layout at the three window sizes and a
    /// full drain back to the welcome card. Corrupted and missing-field
    /// configuration is decoded only against isolated fixtures.
    private static func checkScaleAndRecovery() -> Bool {
        var passed = true
        var failures: [String] = []
        func require(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            passed = passed && condition
        }
        func texts(in view: NSView) -> [String] {
            var found: [String] = []
            if let label = view as? NSTextField { found.append(label.stringValue) }
            for subview in view.subviews { found.append(contentsOf: texts(in: subview)) }
            return found
        }
        func rows(_ controller: SettingsController) -> [BindingActionRow] {
            controller.bindingsStack.arrangedSubviews.compactMap { $0 as? BindingActionRow }
        }
        func measure(_ work: () -> Void) -> Double {
            let start = Date()
            work()
            return Date().timeIntervalSince(start) * 1000
        }
        func drainRunloop() {
            for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }

        // ---- Corrupted / missing-field configuration (isolated only) --------
        require(ConfigurationExchange.decode(Data("这不是JSON".utf8)) == nil, "garbage payload decoded")
        require(ConfigurationExchange.decode(Data("{}".utf8)) == nil, "empty payload decoded")
        require(
            ConfigurationExchange.decode(Data(#"{"formatVersion":1}"#.utf8)) == nil,
            "missing-field payload decoded"
        )
        let payload = ConfigurationExchange.makePayload(
            bindings: [],
            settingsShortcut: nil,
            enabled: false,
            launchIfNeeded: true,
            importedVerifiedLaunchIDs: [],
            importedSuggestedAppIDs: [],
            occupiedHotKeys: [],
            appVersion: "scale"
        )
        if var object = (ConfigurationExchange.encode(payload).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) {
            object["formatVersion"] = 999
            if let mutated = try? JSONSerialization.data(withJSONObject: object) {
                require(ConfigurationExchange.decode(mutated) == nil, "wrong formatVersion decoded")
            } else {
                require(false, "formatVersion mutation failed")
            }
        } else {
            require(false, "payload encode failed")
        }

        let suiteName = "quicktoggle.selftest.scale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferenceStore(defaults: defaults)
        store.saveBindings([
            AppBinding(
                id: UUID(),
                target: TargetApplication(bundleIdentifier: "test.scale.store", name: "存储测试", path: "/tmp/app.app"),
                shortcut: nil,
                launchIfNeeded: true
            )
        ])
        defaults.set(Data("彻底损坏的绑定数据".utf8), forKey: "quickToggle.bindings")
        require(store.loadBindings().isEmpty, "corrupted bindings did not recover to empty")
        // A healthy save after corruption must round-trip again.
        let healthy = AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.scale.store", name: "恢复测试", path: "/tmp/app.app"),
            shortcut: nil,
            launchIfNeeded: true
        )
        store.saveBindings([healthy])
        require(store.loadBindings() == [healthy], "healthy rewrite after corruption failed")

        // ---- 0 bindings: welcome card ---------------------------------------
        let emptyModel = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [])
        defer { emptyModel.close() }
        let emptyController = SettingsController(model: emptyModel)
        emptyModel.onChange = { emptyController.refresh() }
        emptyController.window.setContentSize(NSSize(width: 600, height: 500))
        emptyController.window.contentView?.layoutSubtreeIfNeeded()
        let emptyTexts = texts(in: emptyController.window.contentView ?? NSView())
        require(emptyTexts.contains("先添加一个常用应用"), "first-use welcome missing at 0 bindings")
        require(emptyTexts.contains("0 项"), "count label wrong at 0 bindings")
        require(rows(emptyController).isEmpty, "phantom rows at 0 bindings")

        // ---- 1 binding: single row and reveal --------------------------------
        let oneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0927v2-scale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: oneRoot) }
        let fixtureApp = makeFixtureApp(named: "ScaleFixture", bundleID: "test.scale.fixture", in: oneRoot)
        let single = AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.scale.fixture", name: "唯一应用", path: fixtureApp.path),
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), label: "1"),
            launchIfNeeded: true
        )
        let oneModel = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [single])
        defer { oneModel.close() }
        let oneController = SettingsController(model: oneModel)
        oneModel.onChange = { oneController.refresh() }
        oneController.window.setContentSize(NSSize(width: 600, height: 500))
        oneController.window.contentView?.layoutSubtreeIfNeeded()
        require(rows(oneController).count == 1, "one binding did not build one row")
        require(texts(in: oneController.window.contentView ?? NSView()).contains("1 项"), "count label wrong at 1 binding")
        oneController.revealBinding(single.id)
        drainRunloop()
        require(oneController.window.firstResponder === rows(oneController).first, "reveal failed at 1 binding")

        // ---- 50 / 200 scale ---------------------------------------------------
        for scale in [50, 200] {
            let bindings = makeScaleBindings(scale, bundleID: "test.scale.fixture", path: fixtureApp.path)
            let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
            defer { model.close() }
            let controller = SettingsController(model: model)
            model.onChange = { controller.refresh() }
            controller.window.setContentSize(NSSize(width: 600, height: 500))
            controller.window.contentView?.layoutSubtreeIfNeeded()

            let buildMs = measure { controller.rebuildBindingRows() }
            require(rows(controller).count == scale, "row count \(rows(controller).count) != \(scale)")
            print("SCALE[\(scale)] rebuild=\(Int(buildMs))ms")
            require(buildMs < 15_000, "rebuild at \(scale) took \(Int(buildMs))ms")

            let viewTexts = texts(in: controller.window.contentView ?? NSView())
            require(viewTexts.contains("\(scale) 项"), "count label missing at \(scale)")

            // Every built row keeps the 52pt density, including the longest name.
            for row in rows(controller) where texts(in: row).contains(where: { $0.hasPrefix("长长长") }) {
                require(abs(row.frame.height - 52) < 1, "long-name row height \(row.frame.height) at \(scale)")
                break
            }

            // Repeated unchanged refreshes must not rebuild rows.
            let stable = rows(controller).first
            for _ in 0..<5 { controller.refresh() }
            require(rows(controller).first === stable, "unchanged refresh rebuilt rows at \(scale)")

            // Search filters to matching names (duplicates included) and back.
            controller.searchField.stringValue = "规模应用 1"
            let searchMs = measure { controller.rebuildBindingRows() }
            // Mirror ApplicationListFilter: terms match name AND shortcut text.
            let expected = bindings.filter { binding in
                let searchable = [binding.target.name, binding.shortcut?.displayName ?? "未设置"]
                    .joined(separator: " ")
                return ["规模应用", "1"].allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
            }.count
            require(rows(controller).count == expected, "search rows \(rows(controller).count) != expected \(expected) at \(scale)")
            print("SCALE[\(scale)] search=\(Int(searchMs))ms matches=\(expected)")
            controller.searchField.stringValue = "根本没有这个词xyz"
            controller.rebuildBindingRows()
            require(rows(controller).isEmpty, "no-match search kept rows at \(scale)")
            require(texts(in: controller.window.contentView ?? NSView()).contains("没有找到匹配项"), "no-match state missing at \(scale)")
            controller.resetListFilter()
            drainRunloop()
            require(rows(controller).count == scale, "reset did not restore \(scale) rows")

            // Reveal the last binding: visible, flashing-free, focused.
            let last = bindings.last!
            controller.revealBinding(last.id)
            drainRunloop()
            let revealed = rows(controller).first { $0.identifier?.rawValue == last.id.uuidString }
            require(controller.window.firstResponder === revealed, "reveal lost focus at \(scale)")

            // Layout smoke at the three window sizes (from a fresh, unscrolled
            // list — revealBinding leaves the viewport at the last row).
            controller.listScroll.contentView.scroll(to: .zero)
            controller.listScroll.reflectScrolledClipView(controller.listScroll.contentView)
            let layoutFailures = controller.interfaceLayoutFailures()
            require(layoutFailures.isEmpty, "layout failures at \(scale): \(layoutFailures.prefix(2))")

            // Full drain one binding at a time — the real repeated-rebuild
            // path — must recover to the welcome card.
            if scale == 50 {
                // Full drain (the real O(n) rebuild per removal path) and the
                // welcome-card recovery. At 200 this is prohibitively slow —
                // only a sample is measured there.
                let drainMs = measure {
                    while let first = model.bindings.first {
                        model.removeBinding(first.id)
                    }
                }
                print("SCALE[\(scale)] drain=\(Int(drainMs))ms")
                require(drainMs < 60_000, "drain at \(scale) took \(Int(drainMs))ms")
                require(rows(controller).isEmpty, "drain left rows at \(scale)")
                require(texts(in: controller.window.contentView ?? NSView()).contains("先添加一个常用应用"), "welcome did not return after drain at \(scale)")
            } else {
                let sampleMs = measure {
                    for _ in 0..<20 {
                        guard let first = model.bindings.first else { break }
                        model.removeBinding(first.id)
                    }
                }
                let perRemoval = Int(sampleMs / 20)
                print("SCALE[\(scale)] sample-removal=\(perRemoval)ms/each (full-list rebuild per removal)")
                require(rows(controller).count == scale - 20, "sample removal left \(rows(controller).count) rows")
            }
        }

        print(passed
            ? "Scale and recovery passed"
            : "Scale and recovery FAILED: \(failures.joined(separator: "; "))")
        return passed
    }

    static func runIdleMeasure() {
        let model = QuickToggleModel(diagnosticMode: true)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: model.diagnosticSummary, action: nil, keyEquivalent: ""))
        withExtendedLifetime((model, menu)) {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            var previousCPU = processUsage.cpuSeconds
            var previousDate = Date()
            var cpuTotal = 0.0
            var rssTotal = 0.0
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let now = Date()
                let usage = processUsage
                let elapsed = max(now.timeIntervalSince(previousDate), 0.001)
                cpuTotal += max(usage.cpuSeconds - previousCPU, 0) / elapsed * 100
                rssTotal += usage.peakRSSKilobytes
                previousCPU = usage.cpuSeconds
                previousDate = now
            }
            print(String(format: "空闲 CPU 平均值: %.2f%%", cpuTotal / 5))
            print(String(format: "空闲 RSS 峰值平均: %.0f KB (%.1f MB)", rssTotal / 5, rssTotal / 5 / 1024))
        }
        model.close()
        print("Idle measurement complete")
    }

    private static var processUsage: (cpuSeconds: Double, peakRSSKilobytes: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        // On Darwin ru_maxrss is bytes, unlike Linux where it is kilobytes.
        return (user + system, Double(usage.ru_maxrss) / 1024)
    }

    /// 续修执行单 0928v1：同口径 20/50/200 计时（重建/稳定刷新/搜索/单项更新/单项删除）。
    /// 每项 ≥3 次取中位数；构建配置、窗口尺寸 600×500、查询词与夹具固定；仅诊断/预览域。
    private static func median(_ values: [Double]) -> Int {
        Int(values.sorted()[values.count / 2].rounded())
    }

    static func runPerfBenchmark() {
        _ = NSApplication.shared
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt0928v1-perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let fixtureApp = makeFixtureApp(named: "PerfFixture", bundleID: "test.perf.fixture", in: fixtureRoot)

        func freshSetup(_ scale: Int, bindings: [AppBinding])
            -> (model: QuickToggleModel, controller: SettingsController) {
            let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
            let controller = SettingsController(model: model)
            model.onChange = { controller.refresh() }
            controller.window.setContentSize(NSSize(width: 600, height: 500))
            controller.window.contentView?.layoutSubtreeIfNeeded()
            return (model, controller)
        }
        func timed(_ work: () -> Void) -> Double {
            let start = Date()
            work()
            return Date().timeIntervalSince(start) * 1000
        }

        for scale in [20, 50, 200] {
            let bindings = makeScaleBindings(scale, bundleID: "test.perf.fixture", path: fixtureApp.path)
            let updateCombo = Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey), label: "0")

            // rebuild / stable refresh / search share one pristine setup.
            autoreleasepool {
                let (model, controller) = freshSetup(scale, bindings: bindings)
                defer { model.close() }
                var rebuildRuns: [Double] = []
                for _ in 0..<3 {
                    rebuildRuns.append(timed { controller.rebuildBindingRows() })
                }
                print("PERF scale=\(scale) op=rebuild median=\(median(rebuildRuns))ms runs=\(rebuildRuns.map { Int($0) })")

                var refreshRuns: [Double] = []
                for _ in 0..<3 {
                    refreshRuns.append(timed { controller.refresh() })
                }
                print("PERF scale=\(scale) op=stable-refresh median=\(median(refreshRuns))ms runs=\(refreshRuns.map { Int($0) })")

                var searchRuns: [Double] = []
                for _ in 0..<3 {
                    controller.searchField.stringValue = ""
                    controller.rebuildBindingRows()
                    searchRuns.append(timed {
                        controller.searchField.stringValue = "规模应用 1"
                        controller.rebuildBindingRows()
                    })
                }
                print("PERF scale=\(scale) op=search median=\(median(searchRuns))ms runs=\(searchRuns.map { Int($0) })")
                controller.searchField.stringValue = ""
                controller.rebuildBindingRows()
            }

            // Shortcut update (sort key changes) at first/middle/last.
            for (name, index) in [("first", 0), ("middle", scale / 2), ("last", scale - 1)] {
                var runs: [Double] = []
                for _ in 0..<3 {
                    autoreleasepool {
                        let (model, _) = freshSetup(scale, bindings: bindings)
                        defer { model.close() }
                        runs.append(timed { _ = model.applyShortcut(updateCombo, for: bindings[index].id) })
                    }
                }
                print("PERF scale=\(scale) op=update-shortcut-\(name) median=\(median(runs))ms runs=\(runs.map { Int($0) })")
            }

            // 未运行时打开 toggle (order-preserving) at middle.
            do {
                var runs: [Double] = []
                for _ in 0..<3 {
                    autoreleasepool {
                        let (model, _) = freshSetup(scale, bindings: bindings)
                        defer { model.close() }
                        runs.append(timed { model.toggleLaunchIfNeeded(for: bindings[scale / 2].id) })
                    }
                }
                print("PERF scale=\(scale) op=toggle-launch median=\(median(runs))ms runs=\(runs.map { Int($0) })")
            }

            // Delete at first/middle/last.
            for (name, index) in [("first", 0), ("middle", scale / 2), ("last", scale - 1)] {
                var runs: [Double] = []
                for _ in 0..<3 {
                    autoreleasepool {
                        let (model, _) = freshSetup(scale, bindings: bindings)
                        defer { model.close() }
                        runs.append(timed { model.removeBinding(bindings[index].id) })
                    }
                }
                print("PERF scale=\(scale) op=delete-\(name) median=\(median(runs))ms runs=\(runs.map { Int($0) })")
            }
        }
        print("PERF-BENCHMARK done")
    }

    static func run() -> Bool {
        var failures: [String] = []
        checkShortcutRules(&failures)
        checkSystemKeyboardOverlap(&failures)
        checkTransaction(&failures)
        checkHotKeyPressState(&failures)
        checkStateMachine(&failures)
        checkLaunchAttemptState(&failures)
        checkLaunchPolicy(&failures)
        checkRevealPolicy(&failures)
        checkWindowPresence(&failures)
        checkHotKeyRouting(&failures)
        checkHotKeyRebind(&failures)
        checkMultiBindingPreferences(&failures)
        checkShortcutConflictKnowledge(&failures)
        checkOccupiedHotKeys(&failures)
        checkShortcutSuggester(&failures)
        checkBindingOrder(&failures)
        checkConfigurationExchange(&failures)
        checkRecorderGate(&failures)
        checkApplicationScanner(&failures)
        checkConfirmedShortcuts(&failures)
        checkStatusPolicy(&failures)
        checkLoginAtLaunch(&failures)
        checkIconNormalizer(&failures)
        checkDiagnosticSummary(&failures)
        checkApplicationFiltering(&failures)

        if failures.isEmpty {
            print("QuickToggle self-test passed")
            return true
        }
        failures.forEach { print("QuickToggle self-test failed: \($0)") }
        return false
    }

    private static func checkShortcutRules(_ failures: inout [String]) {
        let valid = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), label: "K")
        let validOption = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey), label: "K")
        let validControl = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey), label: "K")
        let validOpenDisplay = Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey), label: "O")
        let validArrow = Shortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey | optionKey), label: "←")
        let validFunction = Shortcut(keyCode: UInt32(kVK_F1), modifiers: UInt32(controlKey | shiftKey), label: "F1")
        let tooFew = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), label: "K")
        let noCommandOrControl = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | shiftKey), label: "K")
        let screenCapture = Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), label: "3")
        let voiceOver = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), label: "K")
        let settingsDefault = Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey), label: "3")
        let appNumber = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey), label: "4")
        let unsafeSingleModifier = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), label: "K")
        let functionDigit = Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: fnModifierMask, label: "7")
        let reservedFunctionQ = Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: fnModifierMask, label: "Q")
        let functionFKey = Shortcut(keyCode: UInt32(kVK_F1), modifiers: fnModifierMask, label: "F1")
        let stackedFunction = Shortcut(
            keyCode: UInt32(kVK_ANSI_7),
            modifiers: fnModifierMask | UInt32(cmdKey),
            label: "7"
        )
        let firstID = UUID()
        let bound = AppBinding(
            id: firstID,
            target: TargetApplication(bundleIdentifier: "test.one", name: "One", path: "/One.app"),
            shortcut: valid,
            launchIfNeeded: true
        )

        if [valid, validOption, validControl, validOpenDisplay, validArrow, validFunction]
            .contains(where: { $0.validationError != nil }) {
            failures.append("recommended shortcuts were rejected")
        }
        if tooFew.validationError == nil { failures.append("single modifier was accepted") }
        if noCommandOrControl.validationError == nil { failures.append("shortcut without Command or Control was accepted") }
        if screenCapture.validationError == nil { failures.append("screen capture shortcut was accepted") }
        if voiceOver.validationError == nil { failures.append("VoiceOver shortcut was accepted") }
        if appNumber.validationError != nil { failures.append("Command-number app shortcut was rejected") }
        if settingsDefault.settingsValidationError != nil { failures.append("default settings shortcut was rejected") }
        if unsafeSingleModifier.settingsValidationError == nil { failures.append("unsafe single-modifier settings shortcut was accepted") }
        if functionDigit.validationError != nil || functionDigit.settingsValidationError != nil
            || functionDigit.displayName != "fn7" {
            failures.append("fn+digit was not accepted and displayed")
        }
        if reservedFunctionQ.validationError == nil {
            failures.append("reserved fn+Q was accepted")
        }
        if functionFKey.validationError?.contains("标准功能键") != true {
            failures.append("fn+F1 did not explain the function-key mode overlap")
        }
        if stackedFunction.validationError == nil {
            failures.append("fn+digit stacked with another modifier was accepted")
        }
        if functionDigit.riskWarning?.contains("无法检测所有") != true {
            failures.append("fn+digit did not disclose undetectable conflicts")
        }
        let functionEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "7",
            charactersIgnoringModifiers: "7",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_7)
        )
        if functionEvent.flatMap(Shortcut.from(event:)) != functionDigit {
            failures.append("shortcut recorder did not preserve NSEvent.function")
        }
        if !shortcutIsUsed(valid, in: [bound], excluding: UUID()) {
            failures.append("duplicate app shortcut was not detected")
        }
        if shortcutIsUsed(valid, in: [bound], excluding: firstID) {
            failures.append("binding conflicted with its own shortcut")
        }
    }

    private static func checkSystemKeyboardOverlap(_ failures: inout [String]) {
        if UInt64(fnModifierMask) != CGEventFlags.maskSecondaryFn.rawValue {
            failures.append("persisted fn modifier did not match CGEventFlags.maskSecondaryFn")
        }
        if SystemKeyboardOverlap.globePressAction(from: NSNumber(value: 0)) != .none
            || SystemKeyboardOverlap.globePressAction(from: NSNumber(value: 1)) != .switchInputSource
            || SystemKeyboardOverlap.globePressAction(from: NSNumber(value: 2)) != .emojiAndSymbols
            || SystemKeyboardOverlap.globePressAction(from: NSNumber(value: 3)) != .dictation
            || SystemKeyboardOverlap.globePressAction(from: NSNumber(value: 9)) != .unknown(9) {
            failures.append("Globe press action preference mapping was incomplete")
        }
        if !SystemKeyboardOverlap.standardFunctionKeyModeDescription(from: NSNumber(value: true))
            .contains("已开启")
            || !SystemKeyboardOverlap.standardFunctionKeyModeDescription(from: NSNumber(value: false))
            .contains("已关闭") {
            failures.append("standard function-key preference mapping was incomplete")
        }
        if !FunctionHotKeyCenter.hasExactFunctionModifier(.maskSecondaryFn)
            || FunctionHotKeyCenter.hasExactFunctionModifier([.maskSecondaryFn, .maskCommand])
            || FunctionHotKeyCenter.hasExactFunctionModifier(.maskCommand) {
            failures.append("fn event-tap modifier matching was not exact")
        }
    }

    private static func checkTransaction(_ failures: inout [String]) {
        var unregistered: [Int] = []
        var rolledBack: [Int] = []
        let occupied: Result<Int, HotKeyFailure> = RegistrationTransaction.replace(
            current: 1,
            registerCandidate: { .failure(.occupied) },
            unregister: { unregistered.append($0); return .success(()) },
            rollbackCandidate: { rolledBack.append($0) }
        )
        if occupied != .failure(.occupied) || !unregistered.isEmpty || !rolledBack.isEmpty {
            failures.append("candidate failure removed the old hot key")
        }

        let success: Result<Int, HotKeyFailure> = RegistrationTransaction.replace(
            current: 1,
            registerCandidate: { .success(2) },
            unregister: { unregistered.append($0); return .success(()) },
            rollbackCandidate: { rolledBack.append($0) }
        )
        if success != .success(2) || unregistered != [1] || !rolledBack.isEmpty {
            failures.append("successful replacement was not transactional")
        }

        let unregisterFailure: Result<Int, HotKeyFailure> = RegistrationTransaction.replace(
            current: 3,
            registerCandidate: { .success(4) },
            unregister: { _ in .failure(.failed) },
            rollbackCandidate: { rolledBack.append($0) }
        )
        if unregisterFailure != .failure(.failed) || rolledBack != [4] {
            failures.append("candidate was not rolled back after old unregistration failed")
        }
    }

    private static func checkHotKeyPressState(_ failures: inout [String]) {
        var state = HotKeyPressState()
        if !state.acceptPress() {
            failures.append("first physical hot key press was rejected")
        }
        if state.acceptPress() {
            failures.append("repeated hot key press was accepted before release")
        }
        state.release()
        if !state.acceptPress() {
            failures.append("hot key press was not accepted after release")
        }
        state.reset()
        if state.isPressed || !state.acceptPress() {
            failures.append("hot key press state did not reset on rebind")
        }

        var generations = HotKeyGenerationState()
        let first = generations.nextGeneration
        generations.activate(first)
        let second = generations.nextGeneration
        generations.activate(second)
        if generations.accepts(first) || !generations.accepts(second) {
            failures.append("stale fn event-tap callback survived a newer registration")
        }
        generations.invalidate()
        if generations.accepts(second) {
            failures.append("fn event-tap callback survived registration invalidation")
        }
    }

    private static func checkLaunchAttemptState(_ failures: inout [String]) {
        var state = LaunchAttemptState()
        let first = state.begin()
        if !state.isLaunching {
            failures.append("launch attempt did not enter the launching state")
        }
        if state.complete(first + 1) || !state.isLaunching {
            failures.append("stale launch completion changed the active attempt")
        }
        if !state.invalidate(first) || state.isLaunching || state.complete(first) {
            failures.append("timed-out launch completion was not invalidated")
        }
        let second = state.begin()
        if state.complete(first) || !state.isLaunching {
            failures.append("old launch completion replaced a newer attempt")
        }
        if !state.complete(second) || state.isLaunching {
            failures.append("current launch completion was not accepted")
        }
        _ = state.invalidate()
        if state.isLaunching {
            failures.append("cancelled launch attempt remained active")
        }
    }

    private static func checkStateMachine(_ failures: inout [String]) {
        func decide(
            original: OriginalStateKind,
            sameProcess: Bool = true,
            frontmost: Bool = false,
            active: Bool = false,
            hidden: Bool = false,
            foreign: Bool = false,
            fresh: Bool = false,
            minimized: Bool? = nil
        ) -> RestoreDecision {
            RestorePlanner.decide(
                original: original,
                sameProcess: sameProcess,
                targetIsFrontmost: frontmost,
                targetIsActive: active,
                targetIsHidden: hidden,
                foreignAppIsFrontmost: foreign,
                sessionIsFresh: fresh,
                restoredWindowIsMinimized: minimized
            )
        }

        let hidden = decide(original: .hidden, frontmost: true)
        let minimized = decide(original: .minimized, frontmost: true, minimized: false)
        let visible = decide(original: .visible, frontmost: true)
        let userChangedState = decide(original: .hidden, foreign: true)
        let activateRace = decide(original: .hidden, foreign: true, fresh: true)
        let accessory = decide(original: .visible)
        let processRestarted = decide(original: .hidden, sameProcess: false, frontmost: true)
        let alreadyHidden = decide(original: .hidden, hidden: true)
        let hideFailedShouldNotReveal = RestorePlanner.shouldRevealAfter(.hideTarget)
        let minimizeFailedShouldNotReveal = RestorePlanner.shouldRevealAfter(.minimizeExactWindow)

        if hidden != .hideTarget { failures.append("hidden branch did not restore hiding") }
        if minimized != .minimizeExactWindow { failures.append("minimized branch did not target the restored window") }
        if visible != .hideTarget { failures.append("visible branch did not hide on the second press") }
        if userChangedState != .none { failures.append("manual state change was not protected") }
        if !RestorePlanner.shouldRevealAfter(userChangedState) {
            failures.append("manual state change did not fall through to a fresh reveal")
        }
        if RestorePlanner.shouldRevealAfter(hidden) {
            failures.append("valid restore unexpectedly fell through to reveal")
        }
        if activateRace != .hideTarget {
            failures.append("fresh second press did not hide before activate settled")
        }
        if accessory != .hideTarget {
            failures.append("non-frontmost session did not hide accessory-style apps")
        }
        if processRestarted != .none || !RestorePlanner.shouldRevealAfter(processRestarted) {
            failures.append("restarted target did not fall through to a fresh reveal")
        }
        if alreadyHidden != .none || !RestorePlanner.shouldRevealAfter(alreadyHidden) {
            failures.append("already-hidden target did not fall through to a fresh reveal")
        }
        if hideFailedShouldNotReveal {
            failures.append("failed hide unexpectedly fell through to reveal")
        }
        if minimizeFailedShouldNotReveal {
            failures.append("failed minimize unexpectedly fell through to reveal")
        }
    }

    private static func checkApplicationScanner(_ failures: inout [String]) {
        let finder = ApplicationScanner.visibleApplications(excluding: [])
            .filter { $0.bundleIdentifier == "com.apple.finder" }
        if finder.count != 1 || finder.first?.name != "访达" {
            failures.append("Finder must be discoverable once under its Chinese display name")
        }
        if ApplicationScanner.visibleApplications(excluding: ["com.apple.finder"])
            .contains(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            failures.append("already-added Finder was not excluded from the picker")
        }
        if !ApplicationScanner.isExcludedPath("/Applications/Foo.app/Contents/Helpers/Bar.app") {
            failures.append("helper path was accepted")
        }
        if !ApplicationScanner.isExcludedPath("/Applications/Foo.app/Contents/XPCServices/Service.app") {
            failures.append("xpc path was accepted")
        }
        if !ApplicationScanner.isExcludedPath("/Applications/Foo.app/Contents/Frameworks/Plug.app") {
            failures.append("framework path was accepted")
        }
        if ApplicationScanner.isExcludedPath("/Applications/Safari.app") {
            failures.append("normal app path was excluded")
        }
        if !ApplicationScanner.isInvisibleInfo(["LSUIElement": true]) {
            failures.append("LSUIElement app was accepted")
        }
        if !ApplicationScanner.isInvisibleInfo(["LSBackgroundOnly": 1]) {
            failures.append("LSBackgroundOnly app was accepted")
        }
        if ApplicationScanner.isInvisibleInfo(["CFBundleName": "Safari"]) {
            failures.append("visible app info was treated as invisible")
        }
        if let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           ApplicationScanner.shouldInclude(url: safariURL) {
            let scanned = ApplicationScanner.visibleApplications(excluding: [])
            if !scanned.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
                failures.append("installed Safari was not scanned")
            }
            if ApplicationScanner.visibleApplications(excluding: ["com.apple.Safari"])
                .contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
                failures.append("excluded bundle was not filtered")
            }
        }
    }

    private static func checkConfirmedShortcuts(_ failures: inout [String]) {
        if !ConfirmedAppShortcuts.entries(for: "com.unknown.madeup").isEmpty {
            failures.append("unknown app shortcuts were invented")
        }
        if ConfirmedAppShortcuts.entries(for: "com.google.Chrome").isEmpty {
            failures.append("confirmed Chrome shortcuts were missing")
        }
        if ConfirmedAppShortcuts.entries(for: "com.openai.codex").isEmpty {
            failures.append("confirmed Codex shortcuts were missing")
        }
        let wechat = VerifiedLaunchHotKeys.shortcut(for: "com.tencent.xinWeChat")
        if wechat?.displayName != "⇧⌘W" {
            failures.append("verified WeChat launch shortcut was missing")
        }
        if VerifiedLaunchHotKeys.shortcut(for: "com.unknown.madeup") != nil {
            failures.append("unverified launch shortcut was invented")
        }
        if VerifiedLaunchHotKeys.shortcut(for: "com.apple.ActivityMonitor") != nil
            || VerifiedLaunchHotKeys.shortcut(for: "com.apple.Terminal") != nil {
            failures.append("utility apps were given invented native launch shortcuts")
        }
        let activity = SuggestedToggleApps.shortcut(for: "com.apple.ActivityMonitor")
        let terminal = SuggestedToggleApps.shortcut(for: "com.apple.Terminal")
        if activity?.displayName != "⇧⌘A" {
            failures.append("Activity Monitor suggested shortcut was not ⇧⌘A")
        }
        if terminal?.displayName != "⇧⌘T" {
            failures.append("Terminal suggested shortcut was not ⇧⌘T")
        }
        let offshoot = SuggestedToggleApps.shortcut(for: "nl.syncfactory.Hedge.Mac")
        if offshoot?.displayName != "⇧⌘O" {
            failures.append("OffShoot suggested shortcut was not ⇧⌘O")
        }
        let feishu = SuggestedToggleApps.shortcut(for: "com.bytedance.macos.feishu")
        if feishu?.displayName != "⇧⌘F" {
            failures.append("Feishu suggested shortcut was not ⇧⌘F")
        }
        if !ConfirmedAppShortcuts.entries(for: "com.bytedance.macos.feishu").isEmpty {
            failures.append("Feishu in-app shortcuts were invented")
        }
        if SuggestedToggleApps.shortcut(for: "com.unknown.madeup") != nil {
            failures.append("unrequested suggested shortcut was invented")
        }
        if ConfirmedAppShortcuts.entries(for: "com.apple.Safari").isEmpty {
            failures.append("confirmed Safari shortcuts were missing")
        }
        if ConfirmedAppShortcuts.entries(for: "com.apple.Terminal").isEmpty {
            failures.append("confirmed Terminal shortcuts were missing")
        }
        if !ConfirmedAppShortcuts.entries(for: "com.apple.ActivityMonitor").isEmpty {
            failures.append("Activity Monitor in-app shortcuts were invented")
        }
        let occupiedSummary = OccupiedHotKeys.summary(of: OccupiedHotKeys.seed)
        if !occupiedSummary.contains("Aident ⌘1") || !occupiedSummary.contains("Wi‑Fi") {
            failures.append("occupied hotkey summary lost verified local conflicts")
        }
        checkShortcutProbe(&failures)
    }

    private static func checkShortcutProbe(_ failures: inout [String]) {
        let commandOne = Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), label: "1")
        let commandTwo = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey), label: "2")
        let wechat = Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), label: "W")
        let feishu = Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey), label: "F")
        if OccupiedHotKeys.owner(of: commandOne, in: OccupiedHotKeys.seed) != "Aident" {
            failures.append("⌘1 was not flagged as Aident")
        }
        if OccupiedHotKeys.owner(of: commandTwo, in: OccupiedHotKeys.seed) != "Wi‑Fi 菜单" {
            failures.append("⌘2 was not flagged as Wi-Fi menu")
        }
        if OccupiedHotKeys.owner(of: wechat, in: OccupiedHotKeys.seed) != "微信" {
            failures.append("⇧⌘W was not flagged as WeChat")
        }
        if OccupiedHotKeys.owner(of: feishu, in: OccupiedHotKeys.seed) != nil {
            failures.append("⇧⌘F was treated as locally occupied")
        }

        let boundID = UUID()
        let bound = AppBinding(
            id: boundID,
            target: TargetApplication(bundleIdentifier: "test.one", name: "One", path: "/One.app"),
            shortcut: feishu,
            launchIfNeeded: true
        )
        let aident = ShortcutProbe.inspect(
            commandOne,
            appName: "One",
            bundleIdentifier: "com.apple.Safari",
            path: "/Applications/Safari.app",
            bindings: [bound],
            excluding: UUID(),
            asSettings: false,
            occupied: OccupiedHotKeys.seed
        )
        if aident != .occupiedLocally("Aident") {
            failures.append("shortcut probe missed Aident occupancy")
        }
        let duplicate = ShortcutProbe.inspect(
            feishu,
            appName: "Two",
            bundleIdentifier: "com.apple.Safari",
            path: "/Applications/Safari.app",
            bindings: [bound],
            excluding: UUID(),
            asSettings: false,
            occupied: []
        )
        if duplicate != .usedByQuickToggle {
            failures.append("shortcut probe missed an in-app duplicate")
        }
        let missing = ShortcutProbe.inspect(
            feishu,
            appName: "Missing",
            bundleIdentifier: "com.quicktoggle.missing.app",
            path: "/Applications/DoesNotExist.app",
            bindings: [],
            excluding: UUID(),
            asSettings: false,
            occupied: []
        )
        if case .missingApp = missing {
        } else {
            failures.append("shortcut probe missed a missing app")
        }
        let ready = ShortcutProbe.inspect(
            feishu,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            path: "/Applications/Safari.app",
            bindings: [bound],
            excluding: boundID,
            asSettings: false,
            occupied: []
        )
        if ready != .ready {
            failures.append("free shortcut was not ready after local probe")
        }
    }

    private static func checkLaunchPolicy(_ failures: inout [String]) {
        if !LaunchPolicy.allowsReveal(isRunning: true, launchIfNeeded: false) {
            failures.append("running target was blocked by launch preference")
        }
        if !LaunchPolicy.allowsReveal(isRunning: false, launchIfNeeded: true) {
            failures.append("automatic launch was not allowed")
        }
        if LaunchPolicy.allowsReveal(isRunning: false, launchIfNeeded: false) {
            failures.append("disabled automatic launch was ignored")
        }
    }

    private static func checkRevealPolicy(_ failures: inout [String]) {
        if !RevealPolicy.shouldHideImmediately(targetIsFrontmost: true, onScreenWindowCount: 1) {
            failures.append("frontmost app with a visible window was not hidden immediately")
        }
        if RevealPolicy.shouldHideImmediately(targetIsFrontmost: true, onScreenWindowCount: 0) {
            failures.append("frontmost app without an on-screen window was hidden instead of reopened")
        }
        if !RevealPolicy.shouldReopen(windowCount: 0) {
            failures.append("windowless running app did not use application reopen")
        }
        if RevealPolicy.shouldReopen(windowCount: 1) {
            failures.append("visible app was reopened unnecessarily")
        }
    }

    private static func checkWindowPresence(_ failures: inout [String]) {
        let pid: pid_t = 4242
        let usable: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["Width": CGFloat(800), "Height": CGFloat(600)]
        ]
        let tiny: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["Width": CGFloat(16), "Height": CGFloat(16)]
        ]
        let menuLayer: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 25,
            kCGWindowBounds as String: ["Width": CGFloat(800), "Height": CGFloat(600)]
        ]
        if !WindowPresence.isUsableWindow(usable, pid: pid) {
            failures.append("on-screen app window was ignored")
        }
        if WindowPresence.isUsableWindow(tiny, pid: pid) {
            failures.append("tiny helper surface was treated as a usable window")
        }
        if WindowPresence.isUsableWindow(menuLayer, pid: pid) {
            failures.append("menu/status surface was treated as a usable window")
        }
        if WindowPresence.isUsableWindow(usable, pid: pid + 1) {
            failures.append("another process window was attributed to the target")
        }
    }

    private static func checkHotKeyRouting(_ failures: inout [String]) {
        let first = HotKeyManager()
        let second = HotKeyManager()
        defer {
            first.close()
            second.close()
        }
        if first.routingSignature == second.routingSignature {
            failures.append("hot key managers reused the same routing signature")
        }
        if !HotKeyManager.routes(eventSignature: first.routingSignature, to: first.routingSignature) {
            failures.append("hot key event did not reach its owner")
        }
        if HotKeyManager.routes(eventSignature: first.routingSignature, to: second.routingSignature) {
            failures.append("hot key event leaked to another manager")
        }
        let reservedFunction = Shortcut(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: fnModifierMask,
            label: "Q"
        )
        let reservedResult = first.replace(with: reservedFunction)
        if case .failure(.failed) = reservedResult {
            // Expected: even imported or stale persisted data cannot bypass validation.
        } else {
            failures.append("hot key manager registered a reserved non-digit fn combination")
        }
        if first.isActive { failures.append("rejected fn combination left a registration active") }
    }

    private static func checkRecorderGate(_ failures: inout [String]) {
        if !ShortcutRecorderButton.shouldCapture(isRecording: true, windowIsKey: true) {
            failures.append("key window recording was rejected")
        }
        if ShortcutRecorderButton.shouldCapture(isRecording: true, windowIsKey: false) {
            failures.append("background window captured a shortcut")
        }
    }

    private static func checkHotKeyRebind(_ failures: inout [String]) {
        let manager = HotKeyManager()
        defer { manager.close() }
        let candidates = [
            Shortcut(keyCode: UInt32(kVK_F12), modifiers: UInt32(controlKey | shiftKey), label: "F12"),
            Shortcut(keyCode: UInt32(kVK_F11), modifiers: UInt32(cmdKey | controlKey), label: "F11"),
            Shortcut(keyCode: UInt32(kVK_F10), modifiers: UInt32(cmdKey | optionKey), label: "F10"),
            Shortcut(keyCode: UInt32(kVK_F9), modifiers: UInt32(cmdKey | controlKey | shiftKey), label: "F9")
        ]
        var registered: Shortcut?
        for shortcut in candidates {
            if case .success = manager.replace(with: shortcut) {
                registered = shortcut
                break
            }
        }
        guard let registered else {
            // A concurrently running QuickToggle or another utility may own every
            // probe combination. Registration failures are covered by the model;
            // avoid making the self-check disturb existing user hot keys.
            return
        }
        if case .failure = manager.rebind(registered) {
            failures.append("rebinding the same hot key failed")
        }
        if !manager.isActive {
            failures.append("rebound hot key was not active")
        }
    }

    private static func checkMultiBindingPreferences(_ failures: inout [String]) {
        let suiteName = "com.quicktoggle.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failures.append("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferenceStore(defaults: defaults)
        let target = TargetApplication(bundleIdentifier: "test.one", name: "One", path: "/Applications/One.app")
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), label: "K")
        let settingsShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey), label: "4")
        store.target = target
        store.shortcut = shortcut
        store.settingsShortcut = settingsShortcut
        store.launchIfNeeded = false

        if store.settingsShortcut != settingsShortcut {
            failures.append("settings shortcut was not persisted")
        }

        let migrated = store.loadBindings()
        if migrated.count != 1 || migrated[0].target != target || migrated[0].shortcut != shortcut || migrated[0].launchIfNeeded {
            failures.append("single-app preferences were not migrated")
            return
        }
        if store.shortcut != nil {
            failures.append("legacy shortcut was not removed after migration")
        }

        let second = AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.two", name: "Two", path: "/Applications/Two.app"),
            shortcut: nil,
            launchIfNeeded: true
        )
        store.saveBindings([migrated[0], second])
        if store.loadBindings().count != 2 {
            failures.append("multiple app bindings were not persisted")
        }
    }

    private static func checkShortcutConflictKnowledge(_ failures: inout [String]) {
        let suiteName = "com.quicktoggle.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failures.append("could not create isolated conflict knowledge defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferenceStore(defaults: defaults)
        if !store.loadShortcutConflictKnowledge().isEmpty {
            failures.append("fresh conflict knowledge base was not empty")
        }

        let shortcut = Shortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey),
            label: "K"
        )
        let record = ShortcutConflictRecord(
            application: "TestApp",
            command: "Test Command",
            applicationVersion: "1.0",
            macOSVersion: "test",
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            result: "verified test fixture"
        )
        let knowledge = [ShortcutConflictKnowledgeBase.key(for: shortcut): [record]]
        store.saveShortcutConflictKnowledge(knowledge)
        let loaded = store.loadShortcutConflictKnowledge()
        if loaded != knowledge {
            failures.append("conflict knowledge was not persisted")
        }
        if ShortcutConflictKnowledgeBase.records(for: shortcut, in: loaded) != [record] {
            failures.append("conflict knowledge lookup missed its shortcut")
        }
        if ShortcutConflictKnowledgeBase.warning(for: shortcut, in: loaded)
            != "此组合在 TestApp 中是 Test Command 功能。" {
            failures.append("conflict knowledge warning lost its app command")
        }
        let otherShortcut = Shortcut(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(cmdKey | shiftKey),
            label: "J"
        )
        if ShortcutConflictKnowledgeBase.warning(for: otherShortcut, in: loaded) != nil {
            failures.append("conflict knowledge leaked across shortcuts")
        }
    }

    private static func checkOccupiedHotKeys(_ failures: inout [String]) {
        let suiteName = "com.quicktoggle.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failures.append("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferenceStore(defaults: defaults)

        if !store.loadOccupiedHotKeys().isEmpty {
            failures.append("fresh install was seeded with another machine's occupied hot keys")
        }
        if !store.loadOccupiedHotKeys().isEmpty {
            failures.append("fresh occupied hot key state was not persisted")
        }

        let legacySuite = "com.quicktoggle.selftest.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else {
            failures.append("could not create isolated legacy defaults")
            return
        }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        let legacyStore = PreferenceStore(defaults: legacyDefaults)
        legacyStore.saveBindings([AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.one", name: "One", path: "/One.app"),
            shortcut: nil,
            launchIfNeeded: true
        )])
        if legacyStore.loadOccupiedHotKeys() != OccupiedHotKeys.seed {
            failures.append("legacy install was not migrated to the seeded occupied list")
        }

        let custom = [OccupiedHotKeyEntry(
            name: "测试工具",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey), label: "9")
        )]
        store.saveOccupiedHotKeys(custom)
        if store.loadOccupiedHotKeys() != custom {
            failures.append("custom occupied hot key list was not persisted")
        }

        if !OccupiedHotKeys.summary(of: []).contains("暂无") {
            failures.append("empty occupied summary lost its guidance")
        }
        if OccupiedHotKeys.owner(of: custom[0].shortcut, in: custom) != "测试工具" {
            failures.append("custom occupied entry did not resolve its owner")
        }

        let inspected = ShortcutProbe.inspect(
            custom[0].shortcut,
            bindings: [],
            excluding: UUID(),
            asSettings: true,
            occupied: custom
        )
        if inspected != .occupiedLocally("测试工具") {
            failures.append("shortcut probe missed a custom occupied entry")
        }

        let functionOccupied = OccupiedHotKeyEntry(
            name: "Fn 工具",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: fnModifierMask, label: "5")
        )
        if OccupiedHotKeys.owner(of: functionOccupied.shortcut, in: [functionOccupied]) != "Fn 工具" {
            failures.append("fn occupied shortcut did not resolve its owner")
        }
        let functionInspected = ShortcutProbe.inspect(
            functionOccupied.shortcut,
            bindings: [],
            excluding: UUID(),
            asSettings: false,
            occupied: [functionOccupied]
        )
        if functionInspected != .occupiedLocally("Fn 工具") {
            failures.append("shortcut probe missed an occupied fn combination")
        }
    }

    private static func checkShortcutSuggester(_ failures: inout [String]) {
        let settings = Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey), label: "3")

        let fresh = ShortcutSuggester.nextFreeCommandDigit(
            bindings: [], occupied: [], settingsShortcut: settings
        )
        if fresh?.keyCode != UInt32(kVK_ANSI_1) || fresh?.label != "1" {
            failures.append("fresh install did not start with Cmd+1")
        }

        let withSeed = ShortcutSuggester.nextFreeCommandDigit(
            bindings: [], occupied: OccupiedHotKeys.seed, settingsShortcut: settings
        )
        if withSeed?.keyCode != UInt32(kVK_ANSI_4) || withSeed?.label != "4" {
            failures.append("occupied seed and settings shortcut did not push the suggestion to Cmd+4")
        }

        let shiftedOne = Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey), label: "1")
        let binding = AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.one", name: "One", path: "/One.app"),
            shortcut: shiftedOne,
            launchIfNeeded: true
        )
        let notBlocked = ShortcutSuggester.nextFreeCommandDigit(
            bindings: [binding], occupied: [], settingsShortcut: settings
        )
        if notBlocked?.keyCode != UInt32(kVK_ANSI_1) {
            failures.append("a Shift+Cmd+1 binding wrongly blocked the Cmd+1 suggestion")
        }

        var all: [AppBinding] = []
        for (index, digit) in ShortcutSuggester.commandDigits.enumerated()
        where digit.keyCode != UInt32(kVK_ANSI_3) {
            all.append(AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.\(index)",
                    name: "App\(index)",
                    path: "/App\(index).app"
                ),
                shortcut: Shortcut(keyCode: digit.keyCode, modifiers: UInt32(cmdKey), label: digit.label),
                launchIfNeeded: true
            ))
        }
        if ShortcutSuggester.nextFreeCommandDigit(bindings: all, occupied: [], settingsShortcut: settings) != nil {
            failures.append("a fully allocated keyboard still suggested a command digit")
        }

        let functionFallback = ShortcutSuggester.nextFreeRecommendedDigit(
            bindings: all,
            occupied: [],
            settingsShortcut: settings
        )
        if functionFallback?.displayName != "fn1" {
            failures.append("exhausted command digits did not fall back to fn+1")
        }

        let functionOneOccupied = OccupiedHotKeyEntry(
            name: "Fn One",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: fnModifierMask, label: "1")
        )
        let functionTwoBinding = AppBinding(
            id: UUID(),
            target: TargetApplication(bundleIdentifier: "test.fn2", name: "Fn2", path: "/Fn2.app"),
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: fnModifierMask, label: "2"),
            launchIfNeeded: true
        )
        let functionThreeSettings = Shortcut(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: fnModifierMask,
            label: "3"
        )
        let functionFour = ShortcutSuggester.nextFreeFunctionDigit(
            bindings: [functionTwoBinding],
            occupied: [functionOneOccupied],
            settingsShortcut: functionThreeSettings
        )
        if functionFour?.displayName != "fn4" {
            failures.append("fn suggestion did not skip occupied, bound, and settings combinations")
        }

        let firstNineFunctionBindings = ShortcutSuggester.functionDigits.dropLast().enumerated().map {
            index, digit in
            AppBinding(
                id: UUID(),
                target: TargetApplication(
                    bundleIdentifier: "test.fn.\(index)",
                    name: "FnApp\(index)",
                    path: "/FnApp\(index).app"
                ),
                shortcut: Shortcut(keyCode: digit.keyCode, modifiers: fnModifierMask, label: digit.label),
                launchIfNeeded: true
            )
        }
        if ShortcutSuggester.nextFreeFunctionDigit(
            bindings: firstNineFunctionBindings,
            occupied: [],
            settingsShortcut: nil
        )?.displayName != "fn0" {
            failures.append("fn digit fallback did not include fn+0")
        }
    }

    private static func checkBindingOrder(_ failures: inout [String]) {
        func binding(
            _ name: String,
            keyCode: UInt32? = nil,
            modifiers: UInt32 = UInt32(cmdKey),
            label: String = ""
        ) -> AppBinding {
            AppBinding(
                id: UUID(),
                target: TargetApplication(bundleIdentifier: "test.\(name)", name: name, path: "/\(name).app"),
                shortcut: keyCode.map { Shortcut(keyCode: $0, modifiers: modifiers, label: label) },
                launchIfNeeded: true
            )
        }
        let mixed: [AppBinding] = [
            binding("Safari", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), label: "S"),
            binding("Nine", keyCode: UInt32(kVK_ANSI_9), label: "9"),
            binding("None"),
            binding("Four", keyCode: UInt32(kVK_ANSI_4), label: "4"),
            binding("FnTwo", keyCode: UInt32(kVK_ANSI_2), modifiers: fnModifierMask, label: "2"),
            binding("Apple", keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), label: "A"),
            binding("Zero", keyCode: UInt32(kVK_ANSI_0), label: "0")
        ]
        let ordered = BindingOrder.sorted(mixed).map(\.target.name)
        if ordered != ["Zero", "Four", "Nine", "FnTwo", "Apple", "Safari", "None"] {
            failures.append("bindings were not sorted command-digits first: \(ordered)")
        }

        let tie = BindingOrder.sorted([
            binding("B9", keyCode: UInt32(kVK_ANSI_9), label: "9"),
            binding("A9", keyCode: UInt32(kVK_ANSI_9), label: "9")
        ]).map(\.target.name)
        if tie != ["A9", "B9"] {
            failures.append("equal shortcuts did not fall back to a stable name order: \(tie)")
        }

        let shiftedDigit = binding("Shift4", keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), label: "4")
        let letters = BindingOrder.sorted([
            binding("Zed", keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey), label: "Z"),
            shiftedDigit
        ]).map(\.target.name)
        if letters != ["Shift4", "Zed"] {
            failures.append("shifted digits did not sort with letter shortcuts by label: \(letters)")
        }

        let occupiedOne = OccupiedHotKeyEntry(
            name: "Aident",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), label: "1")
        )
        let occupiedWeChat = OccupiedHotKeyEntry(
            name: "微信",
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), label: "W")
        )
        let mixedRows = BindingOrder.sorted([
            .occupied(occupiedWeChat),
            .binding(binding("Four", keyCode: UInt32(kVK_ANSI_4), label: "4")),
            .occupied(occupiedOne),
            .binding(binding("Zed", keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey), label: "Z"))
        ])
        let rowNames = mixedRows.map { row -> String in
            switch row {
            case .binding(let b): return b.target.name
            case .occupied(let e): return e.name
            }
        }
        if rowNames != ["Aident", "Four", "微信", "Zed"] {
            failures.append("occupied entries did not interleave by shortcut order: \(rowNames)")
        }
    }

    private static func checkConfigurationExchange(_ failures: inout [String]) {
        let safari = AppBinding(
            id: UUID(),
            target: TargetApplication(
                bundleIdentifier: "com.apple.Safari",
                name: "Safari",
                path: "/Applications/Safari.app"
            ),
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), label: "S"),
            launchIfNeeded: true
        )
        let ghost = AppBinding(
            id: UUID(),
            target: TargetApplication(
                bundleIdentifier: "com.quicktoggle.missing.app",
                name: "Ghost",
                path: "/Applications/Ghost.app"
            ),
            shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey), label: "G"),
            launchIfNeeded: false
        )
        let payload = ConfigurationExchange.makePayload(
            bindings: [safari, ghost],
            settingsShortcut: Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey), label: "3"),
            enabled: true,
            launchIfNeeded: false,
            importedVerifiedLaunchIDs: ["com.tencent.xinWeChat"],
            importedSuggestedAppIDs: ["com.apple.Terminal"],
            occupiedHotKeys: OccupiedHotKeys.seed,
            appVersion: "test",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        if payload.formatVersion != ConfigurationExchange.formatVersion {
            failures.append("backup payload carried the wrong format version")
        }
        guard let data = ConfigurationExchange.encode(payload),
              let decoded = ConfigurationExchange.decode(data) else {
            failures.append("backup payload did not round-trip")
            return
        }
        if decoded != payload {
            failures.append("backup payload changed across a round-trip")
        }
        if ConfigurationExchange.decode(Data("[not json".utf8)) != nil {
            failures.append("corrupt backup data was accepted")
        }
        var foreign = payload
        foreign.formatVersion = ConfigurationExchange.formatVersion + 99
        if let foreignData = ConfigurationExchange.encode(foreign),
           ConfigurationExchange.decode(foreignData) != nil {
            failures.append("backup with a foreign format version was accepted")
        }

        let (importable, missing) = ConfigurationExchange.partitionImportable([safari, ghost])
        if importable.map(\.id) != [safari.id] || missing != ["Ghost"] {
            failures.append("import filter did not drop missing apps")
        }

        let diagnostic = QuickToggleModel(diagnosticMode: true)
        if diagnostic.applyImportedConfiguration(payload) {
            failures.append("diagnostic mode applied an imported configuration")
        }
    }

    private static func checkStatusPolicy(_ failures: inout [String]) {
        let sticky = Date().addingTimeInterval(10)
        if !StatusPolicy.shouldKeepCurrent(current: .error, incoming: .info, stickyUntil: sticky) {
            failures.append("sticky failure was overwritten by runtime info")
        }
        if StatusPolicy.shouldKeepCurrent(current: .error, incoming: .error, stickyUntil: sticky) {
            failures.append("new failure was blocked by an old failure")
        }
        if StatusPolicy.shouldKeepCurrent(current: .warning, incoming: .info, stickyUntil: sticky) == false {
            failures.append("sticky warning was overwritten by runtime info")
        }
        if StatusPolicy.shouldKeepCurrent(current: .info, incoming: .info, stickyUntil: sticky) {
            failures.append("info status was treated as sticky")
        }
        if StatusPolicy.shouldKeepCurrent(current: .error, incoming: .info, stickyUntil: .distantPast) {
            failures.append("expired sticky failure still blocked info")
        }
    }

    private static func checkLoginAtLaunch(_ failures: inout [String]) {
        if LoginItemStatus.off.isOn {
            failures.append("off login item was treated as enabled")
        }
        if !LoginItemStatus.on.isOn {
            failures.append("enabled login item was treated as off")
        }
        if LoginItemStatus.needsApproval.isOn {
            failures.append("needs-approval login item was treated as enabled")
        }
        if !LoginItemStatus.off.helpText.contains("默认关闭") {
            failures.append("login item help lost the default-off copy")
        }
        if LoginAtLaunch.status == .on {
            // User may already have enabled it; never register or unregister here.
            return
        }
        if LoginAtLaunch.status != .off && LoginAtLaunch.status != .needsApproval && LoginAtLaunch.status != .unavailable {
            failures.append("unexpected login item status \(String(describing: LoginAtLaunch.status))")
        }
    }

    private static func checkIconNormalizer(_ failures: inout [String]) {
        let canvas = NSSize(width: 32, height: 32)
        let fullBleed = IconNormalizer.drawingRect(
            content: NSSize(width: 128, height: 128),
            canvas: canvas
        )
        let padded = IconNormalizer.drawingRect(
            content: NSSize(width: 88, height: 88),
            canvas: canvas
        )
        if abs(fullBleed.width - padded.width) > 0.01 || abs(fullBleed.height - padded.height) > 0.01 {
            failures.append("padded app icon did not fill the same square as a full-bleed icon")
        }
        let expected = 32 - 32 * IconNormalizer.contentInsetRatio * 2
        if abs(fullBleed.width - expected) > 0.05 {
            failures.append("normalized icon did not fill the inset square")
        }

        let samples: [(String, String)] = [
            ("wechat", "/Applications/WeChat.app"),
            ("chrome", "/Applications/Google Chrome.app"),
            ("codex", "/Applications/ChatGPT.app"),
            ("grok", "/Applications/Grok.app"),
            ("gemini", "/Applications/Gemini.app")
        ]
        var dumpDir: URL?
        if let raw = ProcessInfo.processInfo.environment["QUICKTOGGLE_DUMP_ICONS"], !raw.isEmpty {
            dumpDir = URL(fileURLWithPath: raw)
            try? FileManager.default.createDirectory(at: dumpDir!, withIntermediateDirectories: true)
        }
        for (name, path) in samples where FileManager.default.fileExists(atPath: path) {
            let icon = sizedApplicationIcon(at: path, pointSize: 32)
            if icon.size != canvas {
                failures.append("normalized \(name) icon size was \(icon.size)")
            }
            if let dumpDir,
               let tiff = icon.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dumpDir.appendingPathComponent("\(name)-32.png"))
            }
        }
    }

    private static func checkDiagnosticSummary(_ failures: inout [String]) {
        let model = QuickToggleModel(diagnosticMode: true)
        let summary = model.diagnosticSummary
        if !summary.contains("0 个应用") || !summary.contains("全部停用") {
            failures.append("runtime diagnostic summary lost binding or registration state")
        }
        if !summary.contains("辅助功能") {
            failures.append("runtime diagnostic summary lost accessibility state")
        }
        if !summary.contains("Fn 通道未使用") {
            failures.append("runtime diagnostic summary lost fn event-tap state")
        }
    }

    private static func checkApplicationFiltering(_ failures: inout [String]) {
        let key = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey), label: "4")
        let app = AppBinding(id: UUID(), target: TargetApplication(bundleIdentifier: "test.hidden.codex", name: "Visual Editor", path: "/fixture.app"), shortcut: key, launchIfNeeded: true)
        let pending = AppBinding(id: UUID(), target: TargetApplication(bundleIdentifier: "test.chat", name: "聊天", path: "/fixture.app"), shortcut: nil, launchIfNeeded: true)
        let occupied = OccupiedHotKeyEntry(name: "系统组合", shortcut: key)
        let bindings = [app, pending]
        let cases: [(ApplicationListScope, String, Int)] = [
            (.all, "", 2), (.all, "  vISual   ⌘4  ", 1), (.all, "聊天", 1),
            (.all, "codex", 0), (.all, "absent", 0), (.needsShortcut, "", 1),
            (.needsShortcut, "Editor", 0), (.occupied, "系统", 1), (.occupied, "聊天", 0)
        ]
        for (scope, query, expected) in cases {
            if ApplicationListFilter.rows(bindings: bindings, occupied: [occupied], scope: scope, query: query).count != expected {
                failures.append("application filter failed: \(scope), \(query)")
            }
        }
        let preview = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { preview.close() }
        preview.toggleEnabled()
        preview.handleHotKey(app.id)
        preview.recoverHotKeys()
        if preview.registeredShortcutCount != 0 || preview.shortcutState(for: app).text != "预览" {
            failures.append("preview acquired live registrations or mislabeled its state")
        }
        if preview.shortcutState(for: pending).text != "待设置" {
            failures.append("pending shortcut lost its state in preview")
        }
    }

    static func runInterfaceSmoke() -> Bool {
        let bindings = (1...20).map { index in
            AppBinding(id: UUID(), target: TargetApplication(bundleIdentifier: "test.ui.\(index)", name: "应用 \(index) · A long application title", path: "/fixture.app"),
                       shortcut: nil, launchIfNeeded: true)
        }
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: bindings)
        defer { model.close() }
        let controller = SettingsController(model: model)
        let failures = controller.interfaceLayoutFailures()
        failures.forEach { print("FAIL: \($0)") }
        print(failures.isEmpty ? "Interface layout smoke passed (560/640/1080 widths)" : "Interface layout smoke failed")
        let welcomePassed = checkFirstUseWelcomeCard()
        return failures.isEmpty && welcomePassed
    }

    private static func checkFirstUseWelcomeCard() -> Bool {
        let model = QuickToggleModel(diagnosticMode: true, previewMode: true, previewBindings: [])
        defer { model.close() }
        let controller = SettingsController(model: model)
        let button = descendantButton(in: controller.bindingsStack, titled: "添加第一个应用…")
        var passed = button != nil
        if let button {
            passed = passed
                && !button.isHidden
                && button.target as? NSObject === controller
                && button.action == #selector(SettingsController.chooseApplication)
        }
        print(passed ? "First-use welcome call-to-action passed" : "First-use welcome call-to-action failed")
        return passed && renderWelcomeCardIfRequested(controller: controller)
    }

    private static func renderWelcomeCardIfRequested(controller: SettingsController) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["QUICKTOGGLE_RENDER_DIR"], !raw.isEmpty,
              let root = controller.window.contentView else { return true }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            controller.window.setContentSize(NSSize(width: 760, height: 690))
            for (name, appearance) in [("welcome-light", NSAppearance.Name.aqua), ("welcome-dark", NSAppearance.Name.darkAqua)] {
                controller.window.appearance = NSAppearance(named: appearance)
                root.layoutSubtreeIfNeeded()
                var imageData: Data?
                controller.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    imageData = bitmap.representation(using: .png, properties: [:])
                }
                if let imageData { try imageData.write(to: directory.appendingPathComponent("layout-\(name).png")) }
                else { return false }
            }
            return true
        } catch { return false }
    }

    private static func descendantButton(in view: NSView, titled title: String) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.title == title { return button }
            if let match = descendantButton(in: subview, titled: title) { return match }
        }
        return nil
    }
}

private let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--theme-gallery") {
    _ = NSApplication.shared
    exit(SelfTest.renderThemeGallery() ? 0 : 1)
}
if arguments.contains("--ui-smoke-test") {
    _ = NSApplication.shared
    exit(SelfTest.runInterfaceSmoke() ? 0 : 1)
}
if arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}
if arguments.contains("--smoke-test") {
    exit(SelfTest.runComponentSmoke() ? 0 : 1)
}
if arguments.contains("--perf-benchmark") {
    _ = NSApplication.shared
    SelfTest.runPerfBenchmark()
    exit(0)
}
if arguments.contains("--idle-measure") {
    SelfTest.runIdleMeasure()
    exit(0)
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
