import AppKit
import Foundation

/// The input method whose CoreAudio capture state vRemoter follows and whose
/// voice shortcut the remote voice key drives.
enum InputMethodTarget: String, CaseIterable, Identifiable {
    case doubao
    case wechat

    var id: String { rawValue }

    /// Bundle identifier of the running input-method process. This is also the
    /// identifier used for `NSRunningApplication` and CoreAudio process lookup.
    var bundleID: String {
        switch self {
        case .doubao: "com.bytedance.inputmethod.doubaoime"
        case .wechat: "com.tencent.inputmethod.wetype"
        }
    }

    /// Bundle identifiers that may own the voice-capture process. The main
    /// input-method bundle is enough today; keeping this as a list leaves room
    /// for a helper process without changing the monitor.
    var audioBundleIDs: [String] {
        switch self {
        case .doubao:
            ["com.bytedance.inputmethod.doubaoime"]
        case .wechat:
            [
                "com.tencent.inputmethod.wetype",
                "com.tencent.inputmethod.wetype.pinyin"
            ]
        }
    }

    var displayName: String {
        switch self {
        case .doubao: L10n.text("豆包输入法", "Doubao Input Method")
        case .wechat: L10n.text("微信输入法", "WeChat Input Method")
        }
    }

    var shortName: String {
        switch self {
        case .doubao: L10n.text("豆包", "Doubao")
        case .wechat: L10n.text("微信输入法", "WeChat")
        }
    }

    /// Default modifier for the voice trigger. Doubao toggles on a single
    /// modifier tap; WeChat uses modifier + Space for its hands-free mode.
    var defaultTriggerKey: InputTriggerKey {
        switch self {
        case .doubao: .option
        case .wechat: .function
        }
    }

    /// How the remote voice key should drive this input method.
    var voiceTriggerStyle: VoiceTriggerStyle {
        switch self {
        case .doubao: .singleModifierTap
        case .wechat: .handsFreeChord
        }
    }

    var settingsBundleID: String? {
        switch self {
        case .doubao: "com.bytedance.inputmethod.doubaoime.settings"
        case .wechat: nil
        }
    }

    var settingsAppPaths: [String] {
        switch self {
        case .doubao:
            [
                "/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app",
                "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app"
            ]
        case .wechat:
            [
                "/Library/Input Methods/WeType.app/Contents/MacOS/WeTypeSettings.app"
            ]
        }
    }

    var installPaths: [String] {
        switch self {
        case .doubao: ["/Library/Input Methods/DoubaoIme.app"]
        case .wechat: ["/Library/Input Methods/WeType.app"]
        }
    }

    var isInstalled: Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return true
        }
        if installPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        return audioBundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        } || settingsAppPaths.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    static var installedTargets: [InputMethodTarget] {
        allCases.filter(\.isInstalled)
    }
}

enum VoiceTriggerStyle {
    /// One short modifier click. Used by Doubao's toggle mode.
    case singleModifierTap

    /// Modifier + Space. Used by WeChat's hands-free voice mode.
    case handsFreeChord
}
