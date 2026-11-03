import Foundation

enum AppStorage {
    static let loggingEnabledKey = "loggingEnabled"
    static let recordingEnabledKey = "recordingEnabled"
    static let macInputEnabledKey = "macInputEnabled"
    static let remoteInputEnabledKey = "remoteInputEnabled"
    static let inputTriggerKeyKey = "inputTriggerKey"
    static let inputMethodTargetKey = "inputMethodTarget"
    static let wechatInputTriggerKeyKey = "wechatInputTriggerKey"

    static let logsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/vRemote", isDirectory: true)
    }()

    static let logFile = logsDirectory.appendingPathComponent("vRemote.log")

    static let applicationSupportDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vRemote", isDirectory: true)
    }()

    static let recordingsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/vRemote/Recordings",
                isDirectory: true
            )
    }()

    static func prepare() {
        // First launch: prefer whichever input method is actually installed.
        // Existing installations keep their saved choice.
        if UserDefaults.standard.string(forKey: inputMethodTargetKey) == nil {
            let installed = InputMethodTarget.installedTargets
            let preferred: InputMethodTarget
            if installed.contains(.doubao) || installed.isEmpty {
                preferred = .doubao
            } else {
                preferred = installed[0]
            }
            UserDefaults.standard.set(
                preferred.rawValue,
                forKey: inputMethodTargetKey
            )
        }

        UserDefaults.standard.register(defaults: [
            loggingEnabledKey: false,
            recordingEnabledKey: false,
            macInputEnabledKey: true,
            remoteInputEnabledKey: true,
            inputTriggerKeyKey: InputMethodTarget.doubao.defaultTriggerKey.rawValue,
            wechatInputTriggerKeyKey: InputMethodTarget.wechat.defaultTriggerKey.rawValue,
            inputMethodTargetKey: InputMethodTarget.doubao.rawValue,
        ])
        ensureDirectory(logsDirectory)
        ensureDirectory(applicationSupportDirectory)
        ensureDirectory(recordingsDirectory)

        // vRemote has its own storage namespace and never touches V1 data.
    }

    static var loggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: loggingEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: loggingEnabledKey) }
    }

    static var recordingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: recordingEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordingEnabledKey) }
    }

    static var macInputEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: macInputEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: macInputEnabledKey) }
    }

    static var remoteInputEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: remoteInputEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: remoteInputEnabledKey) }
    }

    static var inputTriggerKey: InputTriggerKey {
        get {
            let raw = UserDefaults.standard.string(forKey: inputTriggerKeyKey)
            return InputTriggerKey(rawValue: raw ?? "") ?? .option
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: inputTriggerKeyKey)
        }
    }

    static var inputMethodTarget: InputMethodTarget {
        get {
            let raw = UserDefaults.standard.string(forKey: inputMethodTargetKey)
            return InputMethodTarget(rawValue: raw ?? "") ?? .doubao
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: inputMethodTargetKey
            )
        }
    }

    static var wechatInputTriggerKey: InputTriggerKey {
        get {
            let raw = UserDefaults.standard.string(forKey: wechatInputTriggerKeyKey)
            return InputTriggerKey(rawValue: raw ?? "") ?? .function
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: wechatInputTriggerKeyKey
            )
        }
    }

    /// The trigger key for the currently selected input method. Doubao and
    /// WeChat keep independent trigger settings so switching targets never
    /// silently changes the other input method's configuration.
    static var effectiveInputTriggerKey: InputTriggerKey {
        get {
            switch inputMethodTarget {
            case .doubao: inputTriggerKey
            case .wechat: wechatInputTriggerKey
            }
        }
        set {
            switch inputMethodTarget {
            case .doubao: inputTriggerKey = newValue
            case .wechat: wechatInputTriggerKey = newValue
            }
        }
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    static func byteSize(of url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    static func clearFiles(in directory: URL) {
        let fm = FileManager.default
        ensureDirectory(directory)
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }

    static func formattedSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bytes),
            countStyle: .file
        )
    }
}
