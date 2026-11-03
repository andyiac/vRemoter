import AppKit
import CoreAudio
import Foundation

/// Reads the selected input method's real CoreAudio capture state.
///
/// This is deliberately independent from the remote-button state machine.
/// `kAudioProcessPropertyIsRunningInput` is the source of truth for whether
/// the input method is currently recording, and `kAudioProcessPropertyDevices`
/// tells us which input device it actually opened.
final class InputMethodAudioStateMonitor {
    enum State: String {
        case unavailable
        case inactive
        case active
    }

    struct Snapshot: Equatable {
        let state: State
        let pid: pid_t?
        let processObjectID: AudioObjectID?
        let inputDeviceIDs: [AudioDeviceID]
        let inputDeviceNames: [String]

        var isRecording: Bool { state == .active }

        var deviceSummary: String {
            inputDeviceNames.isEmpty
                ? "无"
                : inputDeviceNames.joined(separator: "、")
        }
    }

    private static let targetDeviceName = "vRemoteDr 2ch"

    private var target: InputMethodTarget
    private var started = false
    private var processObjectID = AudioObjectID(kAudioObjectUnknown)
    private var processPID: pid_t?
    private var lastSnapshot: Snapshot?

    var onSnapshotChanged: ((Snapshot) -> Void)?

    init(target: InputMethodTarget = AppStorage.inputMethodTarget) {
        self.target = target
    }

    /// Switch the monitored input method. The old process binding is dropped
    /// immediately so a stale Doubao/WeChat process can never keep the voice
    /// session open after the user changes targets.
    func setTarget(_ target: InputMethodTarget) {
        guard self.target != target else { return }
        self.target = target
        guard started else { return }
        unbindProcessObject()
        lastSnapshot = nil
        refreshBindingAndPublish(force: true)
    }

    private lazy var processListListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.refreshBindingAndPublish(force: false)
        }
    }

    private lazy var inputStateListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.publishCurrentSnapshot(force: false)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
        if status != noErr {
            print("[IME-STATE] 无法监听音频进程列表: \(Self.describe(status))")
        }
        refreshBindingAndPublish(force: true)
    }

    func stop() {
        guard started else { return }
        started = false
        unbindProcessObject()

        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
        lastSnapshot = nil
    }

    /// Synchronous pre-event snapshot. The event tap calls this before the key
    /// event reaches the input method, so the returned value is the old state
    /// that the trigger press is about to toggle.
    func snapshotNow() -> Snapshot {
        refreshBindingIfNeeded()
        return readCurrentSnapshot()
    }

    private func refreshBindingAndPublish(force: Bool) {
        refreshBindingIfNeeded()
        publishCurrentSnapshot(force: force)
    }

    private func refreshBindingIfNeeded() {
        let binding = Self.inputMethodBinding(for: target)

        guard let binding else {
            if processObjectID != kAudioObjectUnknown {
                unbindProcessObject()
            }
            processPID = nil
            return
        }

        let pid = binding.pid
        let translated = binding.processObject
        guard translated != kAudioObjectUnknown else {
            if processObjectID != kAudioObjectUnknown {
                unbindProcessObject()
            }
            processPID = pid
            return
        }

        guard translated != processObjectID else {
            processPID = pid
            return
        }

        unbindProcessObject()
        processObjectID = translated
        processPID = pid

        var runningAddress = Self.runningInputAddress
        let runningStatus = AudioObjectAddPropertyListenerBlock(
            translated,
            &runningAddress,
            .main,
            inputStateListener
        )

        var devicesAddress = Self.inputDevicesAddress
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            translated,
            &devicesAddress,
            .main,
            inputStateListener
        )

        print(
            "[IME-STATE] 已绑定 target=\(target.rawValue) pid=\(pid) " +
            "audioProcess=\(translated) " +
            "listeners=\(Self.describe(runningStatus))/\(Self.describe(devicesStatus))"
        )
    }

    private func unbindProcessObject() {
        guard processObjectID != kAudioObjectUnknown else { return }
        var runningAddress = Self.runningInputAddress
        AudioObjectRemovePropertyListenerBlock(
            processObjectID,
            &runningAddress,
            .main,
            inputStateListener
        )
        var devicesAddress = Self.inputDevicesAddress
        AudioObjectRemovePropertyListenerBlock(
            processObjectID,
            &devicesAddress,
            .main,
            inputStateListener
        )
        processObjectID = AudioObjectID(kAudioObjectUnknown)
        processPID = nil
    }

    private func publishCurrentSnapshot(force: Bool) {
        guard started else { return }
        let snapshot = readCurrentSnapshot()
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        print(
            "[IME-STATE] target=\(target.rawValue) state=\(snapshot.state.rawValue) " +
            "pid=\(snapshot.pid.map(String.init) ?? "-") " +
            "devices=\(snapshot.deviceSummary)"
        )
        if snapshot.isRecording,
           !snapshot.inputDeviceNames.contains(Self.targetDeviceName)
        {
            print(
                "[IME-STATE] ⚠️ \(target.shortName)正在录音，但实际输入不是 " +
                Self.targetDeviceName
            )
        }
        onSnapshotChanged?(snapshot)
    }

    private func readCurrentSnapshot() -> Snapshot {
        guard processObjectID != kAudioObjectUnknown else {
            return Snapshot(
                state: .unavailable,
                pid: processPID,
                processObjectID: nil,
                inputDeviceIDs: [],
                inputDeviceNames: []
            )
        }

        guard let running = Self.uint32Property(
            object: processObjectID,
            selector: kAudioProcessPropertyIsRunningInput,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return Snapshot(
                state: .unavailable,
                pid: processPID,
                processObjectID: processObjectID,
                inputDeviceIDs: [],
                inputDeviceNames: []
            )
        }

        let deviceIDs = Self.objectListProperty(
            object: processObjectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeInput
        )
        let names = deviceIDs.map(Self.deviceName)
        return Snapshot(
            state: running == 0 ? .inactive : .active,
            pid: processPID,
            processObjectID: processObjectID,
            inputDeviceIDs: deviceIDs,
            inputDeviceNames: names
        )
    }

    private struct InputMethodBinding {
        let pid: pid_t
        let processObject: AudioObjectID
    }

    private static func inputMethodBinding(
        for target: InputMethodTarget
    ) -> InputMethodBinding? {
        // Prefer the CoreAudio process list: it finds the process object even
        // when the input method captures audio from a helper process. If more
        // than one process matches, prefer the one that is actually recording.
        var fallback: InputMethodBinding?
        for object in objectListProperty(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) {
            guard let bundleID = stringProperty(
                object: object,
                selector: kAudioProcessPropertyBundleID,
                scope: kAudioObjectPropertyScopeGlobal
            ) else { continue }
            let matchesTarget = target.audioBundleIDs.contains(bundleID)
                || (target == .wechat
                    && (bundleID.hasPrefix("com.tencent.inputmethod.wetype.")
                        || bundleID.hasPrefix("com.tencent.wetype.")))
            guard matchesTarget else { continue }
            guard let rawPID = uint32Property(
                object: object,
                selector: kAudioProcessPropertyPID,
                scope: kAudioObjectPropertyScopeGlobal
            ) else { continue }
            let binding = InputMethodBinding(
                pid: pid_t(rawPID),
                processObject: object
            )
            let running = uint32Property(
                object: object,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? 0
            if running != 0 {
                return binding
            }
            if fallback == nil {
                fallback = binding
            }
        }
        if let fallback {
            return fallback
        }

        // The input method may be running without an audio process yet. Fall
        // back to NSRunningApplication so an idle-but-installed IME is still
        // reported as inactive rather than unavailable.
        guard let app = runningInputMethodApplication(for: target) else {
            return nil
        }
        let pid = app.processIdentifier
        return InputMethodBinding(
            pid: pid,
            processObject: processObject(for: pid)
        )
    }

    private static func runningInputMethodApplication(
        for target: InputMethodTarget
    ) -> NSRunningApplication? {
        for bundleID in target.audioBundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &size,
                &result
            )
        }
        return status == noErr ? result : AudioObjectID(kAudioObjectUnknown)
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func objectListProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            object,
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else { return [] }

        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &values
        ) == noErr else { return [] }
        return values
    }

    private static func stringProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                object,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        return status == noErr ? value as String : nil
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        stringProperty(
            object: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "设备 \(deviceID)"
    }

    private static func describe(_ status: OSStatus) -> String {
        status == noErr ? "OK" : String(status)
    }

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var runningInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var inputDevicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
