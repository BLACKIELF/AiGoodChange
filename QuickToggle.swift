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
    let target: TargetApplication
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
        case .info: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }
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
            return "登录后自动运行轻唤，快捷键才会在开机后可用。"
        case .needsApproval:
            return "请在“系统设置 > 通用 > 登录项与扩展”中允许轻唤。"
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
        FileManager.default.displayName(atPath: url.path)
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
            return "本机已占用：暂无记录。把其他软件占用的组合加进来，轻唤录制时会自动避开。"
        }
        let body = entries.map { "\($0.name) \($0.shortcut.displayName)" }.joined(separator: "，")
        return "本机已占用：\(body)。不要再录进轻唤。"
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
            title: "轻唤热键",
            body: binding.shortcut?.displayName ?? "尚未为这个应用录制轻唤热键。"
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
                body: "本机已验证为 \(native.displayName)。轻唤改不了微信设置里的那一项；若该组合正被微信占用，点本行录制按钮改成其他组合，保存后立即由轻唤接管。"
            ))
        }

        stack.addArrangedSubview(section(
            title: "如何修改轻唤热键",
            body: "点本行右侧的录制按钮，按下新组合即可。Esc 取消，Delete 清除。改完马上生效，不必退出轻唤。"
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

        let hint = NSTextField(labelWithString: "双击或回车添加，按 ↓ 进入列表；自动分配可用快捷键。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let diskButton = NSButton(title: "从磁盘选择…", target: self, action: #selector(chooseFromDisk))
        diskButton.bezelStyle = .rounded
        diskButton.setAccessibilityLabel("从磁盘选择应用")
        diskButton.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "添加", target: self, action: #selector(addSelected))
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

    func reload(excluding excludedBundleIDs: Set<String>) {
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
            emptyLabel.stringValue = "没有可添加的可视应用。"
            countLabel.stringValue = "0 个待添加"
        } else if filtered.isEmpty {
            emptyLabel.stringValue = "没有匹配的应用。"
            countLabel.stringValue = "0 / \(applications.count)"
        } else {
            countLabel.stringValue = "\(filtered.count) 个待添加"
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
    static let latestRelease = URL(string: "https://api.github.com/repos/BLACKIELF/QuickToggle/releases/latest")!
    static let releasePage = URL(string: "https://github.com/BLACKIELF/QuickToggle/releases/latest")!
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
    static func fetchLatestTag(completion: @escaping (Result<String, Failure>) -> Void) {
        var request = URLRequest(url: UpdateCheckEndpoints.latestRelease, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, Failure>
            if let urlError = error as? URLError {
                result = .failure(.transport(Self.transportDescription(for: urlError)))
            } else if error != nil {
                result = .failure(.transport("网络错误"))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(.status(http.statusCode))
            } else if let data,
                      let payload = try? JSONDecoder().decode(LatestReleasePayload.self, from: data),
                      !payload.tagName.isEmpty {
                result = .success(payload.tagName)
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

        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
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
    private(set) var statusMessage = "添加应用后，轻唤会自动分配快捷键。"
    private(set) var statusTone: StatusTone = .info
    private(set) var updateCheckState: UpdateCheckState = .idle
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
            bindings = store.loadBindings()
            occupiedHotKeys = store.loadOccupiedHotKeys()
            shortcutConflictKnowledge = store.loadShortcutConflictKnowledge()
            isEnabled = store.enabled
            settingsShortcut = store.settingsShortcut ?? Self.defaultSettingsShortcut
            // Restore a previously found update so the menu keeps showing it
            // even when the next automatic check is still outside its 24h window.
            if let known = store.knownAvailableUpdate {
                if ReleaseVersion.isCurrent(appVersion, behind: known) == true {
                    updateCheckState = .available(latest: known)
                } else {
                    store.knownAvailableUpdate = nil
                }
            }
            importVerifiedLaunchApps()
            importSuggestedToggleApps()
        }

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

    func addTarget(url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            reportStatus("所选项目不是有效的 macOS 应用。", tone: .error)
            return false
        }
        guard identifier != Bundle.main.bundleIdentifier else {
            reportStatus("不能把轻唤本身设为目标应用。", tone: .warning)
            return false
        }
        guard !bindings.contains(where: { $0.target.bundleIdentifier == identifier }) else {
            reportStatus("这个应用已经在列表里。", tone: .warning)
            return false
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
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
        if let suggested = nextFreeRecommendedDigit {
            if applyShortcut(suggested, for: bindingID) {
                if previewMode {
                    reportStatus("预览：为 \(displayName) 分配 \(suggested.displayName)，本次预览关闭后不保留。")
                    return true
                }
                let message = "已为 \(displayName) 分配 \(suggested.displayName)：按一下呼出，再按一下藏回。点行内按钮可换键。"
                if let warning = shortcutWarning(for: suggested) {
                    reportStatus(message + " " + warning, tone: .warning)
                } else {
                    reportStatus(message)
                }
                return true
            }
            return true
        }
        reportStatus("已添加 \(displayName)，请为它录制快捷键。")
        return true
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
            reportStatus("已探测：该组合已用于轻唤其他应用。\(preservedShortcut)", tone: .warning)
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
            reportStatus("预览：打开轻唤的快捷键改为 \(candidate.displayName)。")
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
        reportStatus("已请求辅助功能权限；授权后可精确恢复窗口并使用 fn/🌐 热键，返回轻唤即可刷新状态。")
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
                ? "已打开登录时启动；下次登录会自动运行轻唤。"
                : "已关闭登录时启动。"
        )
    }

    func close() {
        hotKeys.values.forEach { $0.close() }
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
            guard addTarget(url: url) else { continue }
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
                details.append("\(occupied.joined(separator: "、")) 正被应用自己占用，点右侧改成其他组合后立即由轻唤接管。")
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
            guard addTarget(url: url) else { continue }
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
            reportStatus("该组合已是轻唤的热键，无需再标记占用。", tone: .warning)
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
        isCheckingForUpdate = true
        updateCheckState = .checking
        preferences?.lastUpdateCheckDate = Date()
        if userInitiated {
            reportStatus("正在检查更新…")
        } else {
            onChange?()
        }
        UpdateCheckService.fetchLatestTag { [weak self] result in
            guard let self else { return }
            self.isCheckingForUpdate = false
            switch result {
            case .failure(let failure):
                self.updateCheckState = .failed(reason: failure.userDescription)
                if userInitiated {
                    self.reportStatus("检查更新失败：\(failure.userDescription)。", tone: .warning)
                }
            case .success(let tag):
                self.applyUpdateTag(tag, userInitiated: userInitiated)
            }
            self.onChange?()
        }
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

    private func applyUpdateTag(_ rawTag: String, userInitiated: Bool) {
        let tag = String(rawTag.prefix(32))
        switch ReleaseVersion.isCurrent(appVersion, behind: tag) {
        case .some(true):
            updateCheckState = .available(latest: tag)
            preferences?.knownAvailableUpdate = tag
            reportStatus("发现新版本 \(tag)，当前 v\(appVersion)。可在菜单栏或“设置与帮助”里打开发行页。")
        case .some(false):
            updateCheckState = .upToDate
            preferences?.knownAvailableUpdate = nil
            if userInitiated {
                reportStatus("已是最新版本 v\(appVersion)。")
            }
        case .none:
            updateCheckState = .failed(reason: "无法识别版本号 “\(tag)”")
            if userInitiated {
                reportStatus("检查完成，但无法识别发行版本 “\(tag)”，请到发行页确认。", tone: .warning)
            }
        }
    }

    private static func updateCheckTimeDescription(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func reportStatus(_ message: String, tone: StatusTone = .info) {
        let displayed = previewMode && !message.hasPrefix("预览") ? "预览：" + message : message
        applyStatus(displayed, tone: tone, preserveStickyFailure: false)
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

private final class ShortcutRecorderButton: NSButton {
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
        bezelColor = nil
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 10
        borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        fillColor = reduced
            ? .windowBackgroundColor
            : .controlBackgroundColor.withAlphaComponent(dark ? 0.58 : 0.76)
        borderColor = .separatorColor.withAlphaComponent(dark ? 0.55 : 0.38)
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
    var onPress: (() -> Void)?
    var onRequestDelete: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var keyboardFocused = false

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
    private func updateRowColors() {
        borderColor = keyboardFocused ? .controlAccentColor : .clear
        fillColor = hovered ? .controlAccentColor.withAlphaComponent(0.06) : .clear
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
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
        if modifiers.isEmpty && isActivateKey {
            if !event.isARepeat { onPress?() }
        } else if modifiers.isEmpty && isDeleteKey, onRequestDelete != nil, !event.isARepeat {
            onRequestDelete?()
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

private final class SettingsController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    let window: QuickToggleWindow
    private let model: QuickToggleModel
    fileprivate let bindingsStack = FlippedStackView()
    private let listScroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private let generalStatus = NSTextField(wrappingLabelWithString: "")
    private let preferencesStatus = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
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
    private let searchField = NSSearchField()
    private let scopeControl = NSSegmentedControl()
    private let listTitle = NSTextField(labelWithString: "我的应用")
    private let preferencesButton = NSButton()
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkUpdateButton = NSButton()
    private let releasePageButton = NSButton()
    private let dailyUpdateCheckButton = NSButton()
    private var preferencesPanel: QuickToggleWindow?
    private var rowStatusLabels: [UUID: NSTextField] = [:]
    private var lastRenderedBindings: [AppBinding]?
    private var guideExpanded = false
    private var appGuideExpanded = false
    private let helpPopover = NSPopover()
    private let addPopover = NSPopover()
    private let pendingPicker = PendingApplicationPickerController()
    private let occupiedNameField = NSTextField()
    private let occupiedRecorder = ShortcutRecorderButton(frame: .zero)
    private var lastRenderedOccupied: [OccupiedHotKeyEntry]?

    init(model: QuickToggleModel) {
        self.model = model
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let height = min(690, max(500, visible.height - 48))
        window = QuickToggleWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(760, visible.width - 48), height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = model.previewMode ? "轻唤 · \(appVersion) 预览" : "轻唤 · QuickToggle"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 600, height: 500)
        window.delegate = self
        window.onFind = { [weak self] in self?.focusSearch() }
        window.onAdd = { [weak self] in self?.chooseApplication() }
        window.onPreferences = { [weak self] in self?.showPreferences() }
        window.isReleasedWhenClosed = false
        applyAccessibilityChrome()
        window.center()
        buildInterface()
        refresh()
    }

    func show() {
        applyAccessibilityChrome()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.recalculateKeyViewLoop()
    }

    func refresh() {
        if lastRenderedBindings != model.bindings || lastRenderedOccupied != model.occupiedHotKeys {
            lastRenderedBindings = model.bindings
            lastRenderedOccupied = model.occupiedHotKeys
            rebuildBindingRows()
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
        rowStatusLabels.forEach { id, label in
            guard let binding = model.bindings.first(where: { $0.id == id }) else { return }
            let state = model.shortcutState(for: binding)
            label.stringValue = state.text
            label.textColor = state.color
        }
        statusBanner.layer?.backgroundColor = model.statusTone == .info
            ? NSColor.clear.cgColor
            : model.statusTone.color.withAlphaComponent(0.14).cgColor
        permissionIcon.contentTintColor = Accessibility.isTrusted ? .systemGreen : .secondaryLabelColor
        permissionButton.isHidden = Accessibility.isTrusted
        permissionButton.isEnabled = !model.previewMode
        loginButton.isEnabled = !model.previewMode
        updateStatusLabel.stringValue = model.updateCheckSummary
        checkUpdateButton.isEnabled = !model.previewMode && !model.isUpdateCheckInProgress
        checkUpdateButton.title = model.isUpdateCheckInProgress ? "正在检查…" : "检查更新…"
        releasePageButton.isHidden = !model.isUpdateAvailable
        dailyUpdateCheckButton.state = model.dailyUpdateCheckEnabled ? .on : .off
        dailyUpdateCheckButton.isEnabled = !model.previewMode
    }

    private func buildInterface() {
        let material = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        material.autoresizingMask = [.width, .height]
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        window.contentView = material

        let title = NSTextField(labelWithString: "轻唤")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let productIdentity = NSTextField(labelWithString: model.previewMode ? "\(appVersion) 预览" : "QuickToggle")
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
        settingsShortcutRecorder.setAccessibilityLabel("轻唤设置窗口快捷键")
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

        let settingsShortcutLabel = NSTextField(labelWithString: "打开轻唤")
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
        let listHeader = horizontalStack([listTitle, countLabel, listHeaderSpacer, addButton], spacing: 8)
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
        bindingsStack.spacing = 5
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

        let applicationsStack = verticalStack([listHeader, filterRow, listScroll], spacing: 12)
        pin(applicationsStack, inside: applicationsCard, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
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
        loginButton.setAccessibilityLabel("登录时启动轻唤")
        loginButton.setAccessibilityHelp("默认关闭。打开后由 macOS 在登录时启动轻唤，不会新增后台进程。")
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
        let updateStack = verticalStack([updateRow, updateStatusLabel], spacing: 8)
        let updateCard = GlassCardView(frame: .zero)
        updateCard.setAccessibilityLabel("更新检查")
        pin(updateStack, inside: updateCard, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        [updateRow, updateStatusLabel].forEach {
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

        let nativeNote = NSTextField(wrappingLabelWithString:
            "这些由 macOS 自己处理，轻唤不会注册或覆盖。可在“系统设置 > 键盘 > 键盘快捷键”中修改。"
        )
        nativeNote.font = .systemFont(ofSize: 11.5)
        nativeNote.textColor = .secondaryLabelColor
        nativeNote.maximumNumberOfLines = 2

        let customGuide = NSTextField(wrappingLabelWithString:
            "优先推荐未占用的 ⌘0–9；⌘ 数字用尽后推荐 fn/🌐0–9（需辅助功能授权）。单按 Globe 的系统动作会警告；fn/🌐+F1–F12 受“将 F1、F2 等键用作标准功能键”影响，本版不注册。macOS 无法检测所有系统、应用或键盘固件冲突。"
        )
        customGuide.font = .systemFont(ofSize: 11.5)
        customGuide.textColor = .tertiaryLabelColor
        customGuide.maximumNumberOfLines = 3

        let guideContent = verticalStack([shortcutGrid, nativeNote, customGuide], spacing: 10)
        [shortcutGrid, nativeNote, customGuide].forEach {
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
            self?.addPopover.performClose(nil)
            if self?.model.addTarget(url: url) == true { self?.resetListFilter() }
        }
        pendingPicker.onChooseFromDisk = { [weak self] in
            self?.addPopover.performClose(nil)
            self?.chooseApplicationFromDisk()
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
            ? "配置副本 · 预览不会更改实际快捷键"
            : "点应用呼出 · 点快捷键改键 · ⌘F 搜索")
        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = .secondaryLabelColor
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = horizontalStack([footerHint, footerSpacer, preferencesButton], spacing: 10)
        footer.alignment = .centerY
        buildPreferencesPanel(views: [runtimeCard, updateCard, guideButton, guideCard, appGuideButton, appGuideCard])

        let rootStack = verticalStack([header, applicationsCard, statusBanner, footer], spacing: 12)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(rootStack)
        header.setContentHuggingPriority(.required, for: .vertical)
        statusBanner.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        guideButton.setContentHuggingPriority(.required, for: .vertical)
        appGuideButton.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: material.topAnchor, constant: 42),
            rootStack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -14),
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
        let title = NSTextField(labelWithString: "按你的习惯使用轻唤")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "普通快捷键添加后即可使用；需要 fn 快捷键或恢复最小化窗口时，再开启辅助功能。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        preferencesStatus.font = .systemFont(ofSize: 11.5)
        preferencesStatus.maximumNumberOfLines = 3
        let done = NSButton(title: "完成", target: self, action: #selector(closePreferences))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let version = NSTextField(labelWithString: "QuickToggle · \(appVersion)\(model.previewMode ? " · 预览" : "")")
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
        guard let container = panel.contentView else { return }
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

    @objc private func changeScope() {
        rebuildBindingRows()
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    @objc private func resetListFilter() {
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

    private func rebuildBindingRows() {
        helpPopover.performClose(nil)
        addPopover.performClose(nil)
        bindingsStack.arrangedSubviews.forEach {
            bindingsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowStatusLabels.removeAll()
        let scope = ApplicationListScope(rawValue: scopeControl.selectedSegment) ?? .all
        addButton.title = scope == .occupied ? "添加占用…" : "添加应用…"
        addButton.setAccessibilityLabel(scope == .occupied ? "添加占用记录" : "添加目标应用")
        addButton.setAccessibilityHelp(scope == .occupied ? "记录其他软件已占用的组合，自动分配时会避开。" : "打开已安装应用列表；添加后自动分配一个可用的数字快捷键。")
        let rows = ApplicationListFilter.rows(bindings: model.bindings, occupied: model.occupiedHotKeys, scope: scope, query: searchField.stringValue)
        listTitle.stringValue = scope == .occupied ? "占用记录" : (scope == .needsShortcut ? "待设置快捷键" : "我的应用")
        let total = scope == .occupied ? model.occupiedHotKeys.count : model.bindings.count
        countLabel.stringValue = rows.count == total ? "\(total) 项" : "\(rows.count) / \(total) 项"
        if rows.isEmpty {
            let isFirstUse = scope == .all && model.bindings.isEmpty && searchField.stringValue.isEmpty
            bindingsStack.addArrangedSubview(isFirstUse ? makeWelcomeCard() : makeFilteredEmptyState(scope: scope))
        }
        rows.forEach { row in
            switch row {
            case .binding(let binding):
                bindingsStack.addArrangedSubview(makeBindingRow(binding))
            case .occupied(let entry):
                bindingsStack.addArrangedSubview(makeOccupiedInlineRow(entry))
            }
        }
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        bindingsStack.addArrangedSubview(bottomSpacer)

        bindingsStack.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: bindingsStack.widthAnchor).isActive = true
        }
        window.recalculateKeyViewLoop()
    }

    private func makeWelcomeCard() -> NSView {
        let emptyState = NSView()

        let title = NSTextField(labelWithString: "先添加一个常用应用")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let hasFreeDigit = model.nextFreeRecommendedDigit != nil
        let message = hasFreeDigit
            ? "轻唤会自动分配可用的数字快捷键：按一下呼出，再按一下藏回。"
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

        let hint = NSTextField(labelWithString: "之后点行内快捷键可换键，点行本身即可呼出应用。")
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

    private func makeBindingRow(_ binding: AppBinding) -> NSView {
        let row = BindingActionRow()
        row.onPress = { [weak self] in self?.model.handleHotKey(binding.id) }
        row.boxType = .custom
        row.cornerRadius = 8
        row.borderWidth = 1
        row.borderColor = .clear
        row.fillColor = .clear
        row.heightAnchor.constraint(equalToConstant: 64).isActive = true
        row.setAccessibilityLabel("\(binding.target.name) 快捷键设置")
        row.setAccessibilityHelp("点图标、名称或空白处呼出或恢复应用；聚焦这一行后也可按空格或回车，按删除键移除（会先确认）。")
        row.toolTip = "呼出或恢复 \(binding.target.name)，等同按它的快捷键"
        row.onRequestDelete = { [weak self] in self?.confirmRemoval(of: binding) }

        let icon = NSImageView()
        icon.image = sizedApplicationIcon(at: binding.target.path, pointSize: 32)
        icon.imageScaling = .scaleNone
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        icon.setAccessibilityLabel("\(binding.target.name) 图标")

        let name = NSTextField(labelWithString: binding.target.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = binding.target.name

        let autoOpen = NSButton(checkboxWithTitle: "未运行时打开", target: self, action: #selector(toggleLaunchIfNeeded(_:)))
        autoOpen.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
        autoOpen.state = binding.launchIfNeeded ? .on : .off
        autoOpen.controlSize = .mini
        autoOpen.font = .systemFont(ofSize: 11)
        autoOpen.setAccessibilityLabel("\(binding.target.name) 未运行时自动打开")
        let state = model.shortcutState(for: binding)
        let registration = NSTextField(labelWithString: state.text)
        registration.font = .systemFont(ofSize: 10.5)
        registration.textColor = state.color
        registration.setAccessibilityLabel("\(binding.target.name) 快捷键状态")
        rowStatusLabels[binding.id] = registration
        let secondary = horizontalStack([registration, autoOpen], spacing: 9)
        secondary.alignment = .centerY
        let labels = verticalStack([name, secondary], spacing: 3)

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
        recorder.widthAnchor.constraint(equalToConstant: 108).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        recorder.setAccessibilityLabel("\(binding.target.name) 快捷键录制")
        if let native = VerifiedLaunchHotKeys.shortcut(for: binding.target.bundleIdentifier) {
            recorder.toolTip = "应用自带 \(native.displayName)。点此改成轻唤热键，改完立即生效。"
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

        let helpButton = NSButton()
        helpButton.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: "说明"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        helpButton.bezelStyle = .inline
        helpButton.isBordered = false
        helpButton.contentTintColor = .secondaryLabelColor
        helpButton.target = self
        helpButton.action = #selector(showBindingHelp(_:))
        helpButton.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
        helpButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        helpButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        helpButton.setAccessibilityLabel("\(binding.target.name) 的快捷键说明")
        helpButton.setAccessibilityHelp("查看轻唤热键、已确认的应用快捷键，以及如何自行查看。")
        helpButton.setAccessibilityRole(.button)
        helpButton.toolTip = "查看这个应用的快捷键说明"

        let deleteButton = NSButton()
        deleteButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "删除"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteBinding(_:))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(binding.id.uuidString)
        deleteButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        deleteButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        deleteButton.setAccessibilityLabel("移除 \(binding.target.name)")

        let rowStack = horizontalStack([icon, labels, spacer, recorder, helpButton, deleteButton], spacing: 10)
        rowStack.alignment = .centerY
        pin(
            rowStack,
            inside: row.contentView ?? row,
            insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        )
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
        var excluded = Set(model.bindings.map(\.target.bundleIdentifier))
        if let selfID = Bundle.main.bundleIdentifier { excluded.insert(selfID) }
        pendingPicker.reload(excluding: excluded)
        addPopover.contentSize = NSSize(width: 300, height: 336)
        addPopover.show(relativeTo: addButton.bounds, of: addButton, preferredEdge: .maxY)
    }

    private func chooseApplicationFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "添加要呼出的应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.addTarget(url: url) { resetListFilter() }
    }

    @objc private func showBindingHelp(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let binding = model.bindings.first(where: { $0.id == id }) else { return }
        if helpPopover.isShown {
            helpPopover.performClose(nil)
            return
        }
        let controller = NSViewController()
        controller.view = BindingHelpContent.view(for: binding)
        helpPopover.contentViewController = controller
        helpPopover.contentSize = controller.view.fittingSize
        helpPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }

    @objc private func toggleLaunchIfNeeded(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue, let id = UUID(uuidString: rawValue) else { return }
        model.toggleLaunchIfNeeded(for: id)
    }

    @objc private func deleteBinding(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let binding = model.bindings.first(where: { $0.id == id }) else { return }
        confirmRemoval(of: binding)
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
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        window.isOpaque = reduced
        window.backgroundColor = reduced ? .windowBackgroundColor : .clear
        if let material = window.contentView as? NSVisualEffectView {
            material.state = reduced ? .inactive : .active
            material.material = reduced ? .contentBackground : .underWindowBackground
        }
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
        for size in [NSSize(width: 600, height: 500), NSSize(width: 760, height: 690), NSSize(width: 1080, height: 760)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let root = window.contentView else { continue }
            for (name, view) in [("search", searchField as NSView), ("add", addButton), ("feedback", statusBanner), ("preferences", preferencesButton)] {
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
    private var previousApplication: NSRunningApplication?
    private var lastHotKeyRecovery = Date.distantPast
    private var updateCheckTimer: Timer?

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
        addMenuItem("打开轻唤", action: #selector(showSettingsAction), key: ",", to: appMenu)
        addMenuItem("退出轻唤", action: #selector(quitAction), key: "q", to: appMenu)
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
    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        model.close()
    }

    func menuWillOpen(_ menu: NSMenu) {
        recoverHotKeysIfNeeded()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "轻唤")
            button.image?.isTemplate = true
            button.toolTip = "轻唤"
        }
        statusItem = item
        refreshMenu()
    }

    private func refreshInterface() {
        settings?.refresh()
        refreshMenu()
    }

    private static let displayVersion: String = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(appVersion) (build \(build))"
    }()

    private func refreshMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        addMenuItem("打开轻唤", action: #selector(showSettingsAction), key: ",", to: menu)
        let state = NSMenuItem(title: model.previewMode ? "界面预览 · 配置副本" : (model.isEnabled ? "\(model.registeredShortcutCount) 个应用快捷键已注册" : "应用快捷键已暂停"), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let version = NSMenuItem(title: "轻唤 \(Self.displayVersion)", action: nil, keyEquivalent: "")
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
        for text in [model.statusMessage, model.diagnosticSummary, "打开轻唤：\(model.settingsShortcut.displayName)"] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            details.addItem(item)
        }
        detailsItem.submenu = details
        menu.addItem(detailsItem)
        menu.addItem(.separator())
        addMenuItem("退出", action: #selector(quitAction), key: "q", to: menu)
        menu.delegate = self
        statusItem.menu = menu
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
        if settings == nil { settings = SettingsController(model: model) }
        settings?.show()
    }

    private func toggleSettings() {
        guard let window = settings?.window, window.isVisible else {
            showSettings()
            return
        }

        let shouldRestoreFocus = NSApp.isActive
        window.orderOut(nil)
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
        panel.title = "导出轻唤配置"
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
        panel.title = "导入轻唤配置"
        panel.message = "选择此前导出的 JSON 备份；导入会替换当前绑定。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            model.reportStatus("导入失败：无法读取所选文件。", tone: .error)
            return
        }
        guard let payload = ConfigurationExchange.decode(data) else {
            model.reportStatus("导入失败：这不是有效的轻唤配置备份。", tone: .error)
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
        return checkBindingRowInteraction() && checkUpdateCheckLogic() && passed
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
        print(passed ? "Binding row mouse/control/keyboard/accessibility routing passed" : "Binding row interaction failed")
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
        print(failures.isEmpty ? "Interface layout smoke passed (600/760/1080 widths)" : "Interface layout smoke failed")
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
if arguments.contains("--idle-measure") {
    SelfTest.runIdleMeasure()
    exit(0)
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
