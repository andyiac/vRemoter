// BLEBridge: CoreBluetooth connection to one ATVV-capable voice remote. It
// runs the voice-stream handshake and pumps decoded mono Int16 PCM into the
// AudioPipe.
//
// State machine (matches mi-ao's ATVV flow, simplified):
//   disconnected → connect → discoverServices → discoverChars
//   → send getCapabilities → wait for capabilities
//   → on .startSearch (voice-key press from remote): send micOpen
//   → audio frames flow on TX char → ADPCM decode → AudioPipe.feed

import CoreBluetooth
import Foundation

final class BLEBridge: NSObject {
    // ATVV service / characteristic UUIDs (Google Android TV Remote protocol).
    static let serviceUUID  = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let commandUUID  = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")  // host writes commands to remote
    static let audioUUID    = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")  // remote sends voice data to host (notify)
    static let controlUUID  = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")  // control events from remote

    // This V2 bridge owns one X6 ATVV connection.
    private let nameHint: String?
    private let savedUUIDPath: String
    private let recordingPrefix: String
    private let logTag: String
    private let resetSessionOnConnect: Bool

    /// Where we persist a previously-discovered peripheral UUID so the next
    /// launch can attempt `retrievePeripherals` directly without scanning.
    private static let appSupportDirectory = NSString(
        string: "~/Library/Application Support/vRemote"
    ).expandingTildeInPath

    /// Called whenever the bridge produces or stops producing audio (true = streaming).
    var onStreamingChanged: ((Bool, Int /* sampleRate */) -> Void)?
    /// Raw ATVV session edges. Unlike `onStreamingChanged`, these preserve
    /// the protocol reason so X6 can distinguish a native hold-to-talk stream
    /// from a host-requested persistent stream.
    var onAudioStarted: ((UInt8 /* reason */, Int /* sampleRate */) -> Void)?
    var onAudioStopped: ((UInt8 /* reason */) -> Void)?
    var onMicrophoneOpenFailed: ((UInt16 /* code */) -> Void)?
    /// Called when the device connection state changes.
    var onConnectionChanged: ((Bool) -> Void)?
    /// Called when the remote still holds a stale bond with this Mac, so the
    /// user has to forget it in System Settings and pair again.
    var onPairingRequired: (() -> Void)?
    /// Audio level meter update; arg is dBFS in [-60, 0].
    var onLevel: ((Double, Int /* peak */) -> Void)?

    private var central: CBCentralManager!
    private var isStarted = false
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var commandChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var atvvCharsComplete = false
    private var capabilitiesRequested = false
    private var connectedPeripheralID: UUID?
    private var connectTimeout: DispatchWorkItem?
    private var scanRetryTimer: Timer?
    private var healthTimer: Timer?
    private var capsRetryWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var nextReconnectAt = Date.distantPast
    private var capsAttempts = 0
    private var isScanning = false
    private var lastAudioFrameAt = Date.distantPast
    private var pairingRequiredNotified = false

    private let protocolHandler = ATVVProtocol()
    private var streamID: UInt8 = 0
    private var isStreaming = false
    private var levelSumSq: Int64 = 0
    private var levelCount: Int = 0
    private var levelPeak: Int = 0
    private var levelLogAt = Date.distantPast
    private var diagFrameCount = 0
    private var streamFrameCount = 0
    private var streamSampleCount = 0
    private var streamPeak = 0
    private var streamSumSquares: Int64 = 0
    private var streamClippedSampleCount = 0
    private var pendingAudioSyncCount = 0
    private var streamAudioSyncCount = 0
    private var wavRecorder: WavRecorder?
    // Verbose PCM diagnostics are off unless explicitly requested.
    private static let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["MIA_DIAGNOSTICS"] == "1"
    private var lastStartSearchAt = Date.distantPast
    private var lastMicOpenAt = Date.distantPast
    private var closeTimeoutWorkItem: DispatchWorkItem?
    private var hasResetSessionForConnection = false

    init(
        nameHint: String?,
        savedUUIDFilename: String,
        recordingPrefix: String,
        logTag: String,
        resetSessionOnConnect: Bool
    ) {
        self.nameHint = nameHint
        self.savedUUIDPath = URL(
            fileURLWithPath: Self.appSupportDirectory
        ).appendingPathComponent(savedUUIDFilename).path
        self.recordingPrefix = recordingPrefix
        self.logTag = logTag
        self.resetSessionOnConnect = resetSessionOnConnect
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        isStarted = true
        reconnectAttempts = 0
        nextReconnectAt = .distantPast
        if central.state == .poweredOn {
            attemptConnection()
        } else {
            print("[\(logTag)] 等待蓝牙就绪…")
        }
    }

    func stop() {
        isStarted = false
        closeTimeoutWorkItem?.cancel()
        closeTimeoutWorkItem = nil
        cancelCapsRetry()
        stopKeepAliveTimer()
        stopHealthTimer()
        stopScanRetryTimer()
        if isStreaming {
            if let close = try? protocolHandler.micCloseCommand(streamID: streamID) {
                writeCommand(close)
                print("[\(logTag)] TX micClose before shutdown")
            }
            finishAudioStreamLocally(reason: 0xFD)
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central.stopScan()
        isScanning = false
        self.peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        atvvCharsComplete = false
        capabilitiesRequested = false
        capsAttempts = 0
    }

    func setRecordingEnabled(_ enabled: Bool) {
        AppStorage.recordingEnabled = enabled
        if enabled, isStreaming, wavRecorder == nil {
            wavRecorder = WavRecorder.createNext(prefix: recordingPrefix)
        } else if !enabled, let recorder = wavRecorder {
            recorder.close()
            wavRecorder = nil
        }
    }

    @discardableResult
    func openMicrophone(
        bypassDebounce: Bool = false
    ) -> RemoteMicrophoneOpenResult {
        guard !isStreaming else { return .alreadyStreaming }
        guard peripheral != nil, commandChar != nil else {
            print("[\(logTag)] micOpen waiting for writable characteristic")
            return .retryAfter(0.15)
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMicOpenAt)
        guard bypassDebounce || elapsed >= 0.35 else {
            print("[\(logTag)] micOpen duplicate suppressed")
            return .retryAfter(max(0.01, 0.35 - elapsed))
        }
        do {
            protocolHandler.prepareForAudioStream()
            pendingAudioSyncCount = 0
            guard writeCommand(try protocolHandler.micOpenCommand()) else {
                return .retryAfter(0.15)
            }
            lastMicOpenAt = now
            print("[\(logTag)] TX micOpen requested by gesture")
            return .sent
        } catch {
            print(
                "[\(logTag)] micOpen gesture error: " +
                error.localizedDescription
            )
            return .failed(error.localizedDescription)
        }
    }

    func closeMicrophone(force: Bool = false) {
        // `isStreaming` is driven by the remote's AUDIO_START/AUDIO_STOP
        // notifications.  A lost stop packet must not make the close action
        // a no-op: the remote can still be sending frames and keep-alives.
        guard force || isStreaming else {
            print("[\(logTag)] micClose ignored; local stream already idle")
            return
        }
        if !isStreaming {
            // Keep the UI and AudioPipe honest even when the peripheral's
            // start/stop notifications were lost and only a forced reset is
            // available.
            onLevel?(-120, 0)
        }
        // Stop extending the session as soon as the user finishes a gesture.
        // X6 does not reliably stop ATVV by itself; leaving keep-alive active
        // saturates its BLE link and delays/drops ordinary HID keyboard data.
        stopKeepAliveTimer()
        do {
            writeCommand(
                try protocolHandler.micCloseCommand(streamID: streamID)
            )
            print("[\(logTag)] TX micClose requested by gesture")
            closeTimeoutWorkItem?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isStreaming else { return }
                print("[\(self.logTag)] AUDIO_STOP timeout; forcing local cleanup")
                self.finishAudioStreamLocally(reason: 0xFE)
            }
            closeTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
        } catch {
            print(
                "[\(logTag)] micClose gesture error: " +
                error.localizedDescription
            )
        }
    }

    func clearRecordings() {
        if let recorder = wavRecorder {
            recorder.close()
            wavRecorder = nil
        }
        AppStorage.clearFiles(in: AppStorage.recordingsDirectory)
    }

    /// Public entry point for external wake-up signals (HID reconnect, voice
    /// key press). Resets the backoff so a user action always gets an
    /// immediate attempt instead of waiting out the retry delay.
    func kickReconnect() {
        guard isStarted else { return }
        reconnectAttempts = 0
        nextReconnectAt = .distantPast
        // A link that is up (or a handshake already in flight) is handled by
        // the capabilities watchdog and the health timer; do not tear it down
        // just because the user pressed a key during negotiation.
        guard connectedPeripheralID == nil, connectTimeout == nil else { return }
        print("[\(logTag)] 收到唤醒信号，立即重连")
        attemptConnection()
        startScanRetryTimer()
    }

    /// Called after the Mac wakes from sleep. A BLE link can survive `sleep`
    /// as "connected" while it is actually dead, so force a clean session.
    func handleSystemWake() {
        guard isStarted else { return }
        print("[\(logTag)] 系统唤醒，检查遥控器连接")
        reconnectAttempts = 0
        nextReconnectAt = .distantPast
        if connectedPeripheralID != nil {
            recoverConnection(reason: "系统唤醒")
        } else {
            attemptConnection()
            startScanRetryTimer()
        }
    }

    func handleSystemSleep() {
        guard isStarted else { return }
        // Keep the BLE link: macOS may preserve it across sleep. Only settle
        // any local stream state so the UI is not left showing "recording".
        if isStreaming,
           let close = try? protocolHandler.micCloseCommand(streamID: streamID) {
            writeCommand(close)
        }
        finishAudioStreamLocally(reason: 0xFD)
    }

    /// One recovery attempt, biased toward peripherals that macOS can already
    /// see. Scanning is the fallback because a HID-paired remote does not
    /// advertise until its HID link is gone.
    private func attemptConnection() {
        guard isStarted, connectedPeripheralID == nil,
              connectTimeout == nil else { return }
        guard central.state == .poweredOn else {
            print("[\(logTag)] 蓝牙未就绪，等待状态恢复")
            return
        }
        // Prefer the currently connected physical device over a persisted
        // UUID. This makes same-model replacement remotes work without
        // manually deleting x6-uuid.txt from the previous unit.
        guard let known = knownPeripheral() else {
            beginScan()
            return
        }
        if known.fromSavedUUID {
            print("[\(logTag)] 已存 UUID 直接 connect: \(known.peripheral.identifier)")
        } else {
            print(
                "[\(logTag)] ATVV 已连接设备直接 connect: " +
                "\(known.peripheral.name ?? "(no name)") \(known.peripheral.identifier)"
            )
        }
        connect(
            to: known.peripheral,
            allowTimeoutFallback: known.fromSavedUUID
        )
    }

    /// A device that macOS already holds a connection to (HID pairing) or
    /// remembers from a previous run. Both cases are invisible to
    /// `scanForPeripherals`, so they are the only way back after a timeout.
    private func knownPeripheral() -> (peripheral: CBPeripheral, fromSavedUUID: Bool)? {
        let connected = central.retrieveConnectedPeripherals(
            withServices: [Self.serviceUUID]
        )
        if let candidate = connected.first(where: matches) {
            return (candidate, false)
        }

        guard let uuidString = try? String(
            contentsOfFile: savedUUIDPath,
            encoding: .utf8
        ),
            let uuid = UUID(
                uuidString: uuidString.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        else {
            return nil
        }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let candidate = known.first, matches(candidate) {
            return (candidate, true)
        }
        return nil
    }

    private func beginScan() {
        guard isStarted else { return }
        if !isScanning {
            print("[\(logTag)] 扫描中（按名字 \(nameHint ?? "?") + ATVV service 过滤）")
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            isScanning = true
        }
        startScanRetryTimer()
    }

    /// Runs while disconnected. It covers the cases advertisement scans
    /// cannot: a HID-paired remote stops advertising, and a saved UUID is
    /// invisible to scanning until macOS wakes the device. It also rate-limits
    /// direct attempts with exponential backoff so an absent remote does not
    /// hammer the radio.
    private func startScanRetryTimer() {
        guard scanRetryTimer == nil else { return }
        let timer = Timer(
            timeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            self?.reconnectTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        scanRetryTimer = timer
    }

    private func stopScanRetryTimer() {
        scanRetryTimer?.invalidate()
        scanRetryTimer = nil
    }

    private func reconnectTick() {
        guard isStarted, connectedPeripheralID == nil,
              connectTimeout == nil else { return }
        guard Date() >= nextReconnectAt else { return }
        attemptConnection()
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard isStarted else { return }
        nextReconnectAt = Date().addingTimeInterval(delay)
        if connectedPeripheralID == nil, connectTimeout == nil {
            beginScan()
        }
    }

    private func noteConnectFailure(_ reason: String) {
        reconnectAttempts += 1
        let delay = min(5.0 * Double(reconnectAttempts), 30.0)
        print(
            "[\(logTag)] 连接失败（\(reason)），" +
            "\(Int(delay.rounded())) 秒后重试（第 \(reconnectAttempts) 次）"
        )
        scheduleReconnect(after: delay)
    }

    /// Tear down a link that is up but unusable (lost notifications or a dead
    /// ATVV handshake) and start over. Without this a half-open link can look
    /// connected forever while voice input silently does nothing.
    private func recoverConnection(reason: String) {
        print("[\(logTag)] \(reason)，重建连接")
        cancelCapsRetry()
        finishAudioStreamLocally(reason: 0xFB)
        connectedPeripheralID = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        let oldPeripheral = peripheral
        peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        atvvCharsComplete = false
        capabilitiesRequested = false
        capsAttempts = 0
        stopHealthTimer()
        if let oldPeripheral {
            central.cancelPeripheralConnection(oldPeripheral)
        }
        onConnectionChanged?(false)
        reconnectAttempts = 0
        // Give the pending cancellation time to reach the controller before
        // reconnecting to the same identifier.
        scheduleReconnect(after: 1.0)
    }

    private func startHealthTimer() {
        stopHealthTimer()
        let timer = Timer(
            timeInterval: 20.0,
            repeats: true
        ) { [weak self] _ in
            self?.checkConnectionHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func checkConnectionHealth() {
        guard isStarted, connectedPeripheralID != nil else { return }
        guard let peripheral, peripheral.state == .connected else {
            recoverConnection(reason: "健康检查发现连接已断开")
            return
        }
        let controlReady = controlChar?.isNotifying == true
        let commandReady = commandChar?.isNotifying == true
        guard controlReady || commandReady else {
            recoverConnection(reason: "健康检查发现通知通道失效")
            return
        }
        checkStreamHealth()
    }

    /// A live ATVV stream sends a frame every 20–40 ms, even in silence. A
    /// multi-second gap means the notification channel is dead even if
    /// CoreBluetooth has not reported a disconnect.
    private func checkStreamHealth() {
        guard isStreaming else { return }
        guard Date().timeIntervalSince(lastAudioFrameAt) > 6.0 else { return }
        print("[\(logTag)] 语音流 6 秒无数据，结束本地流")
        if let close = try? protocolHandler.micCloseCommand(streamID: streamID) {
            writeCommand(close)
        }
        finishAudioStreamLocally(reason: 0xF9)
    }

    fileprivate func saveUUID(_ id: UUID) {
        let path = savedUUIDPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? id.uuidString.write(to: url, atomically: true, encoding: .utf8)
        print("[\(logTag)] 已保存 UUID: \(id.uuidString)")
    }

    fileprivate func connect(
        to p: CBPeripheral,
        allowTimeoutFallback: Bool = false
    ) {
        guard matches(p) else { return }
        guard connectedPeripheralID != p.identifier else { return }
        connectTimeout?.cancel()
        stopScanRetryTimer()
        isScanning = false
        peripheral = p
        connectedPeripheralID = nil
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)
        saveUUID(p.identifier)
        print("[\(logTag)] 连接 \(p.name ?? "(no name)") (\(p.identifier))…")

        // CoreBluetooth does not always deliver didFailToConnect, especially
        // when the peripheral still advertises but the bond is gone. Without a
        // timeout the bridge can sit in "connecting" forever and never retry,
        // which looks like a dead remote in the UI.
        let id = p.identifier
        let interval: TimeInterval = allowTimeoutFallback ? 4.0 : 6.0
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, self.isStarted,
                  self.connectedPeripheralID != id,
                  self.peripheral?.identifier == id else { return }
            print("[\(self.logTag)] 连接超时")
            if let p {
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
            self.connectTimeout = nil
            self.audioChar = nil
            self.commandChar = nil
            self.controlChar = nil
            self.atvvCharsComplete = false
            self.capabilitiesRequested = false
            self.noteConnectFailure("超时")
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// True when macOS still has a bond entry but the remote dropped its side
    /// of it (typical after pairing the same remote to another host). The
    /// connect attempt can never succeed until the user re-pairs.
    private func isPairingInformationLost(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == CBErrorDomain
            && error.code == CBError.Code.peerRemovedPairingInformation.rawValue
    }

    private func notePairingInformationLost() {
        // The cached UUID is not the problem, but dropping it keeps the next
        // launch from trying a peripheral that needs a fresh pairing anyway.
        try? FileManager.default.removeItem(atPath: savedUUIDPath)
        guard !pairingRequiredNotified else { return }
        pairingRequiredNotified = true
        print(
            "[\(logTag)] 配对信息已失效：请在系统设置 → 蓝牙中移除并重新配对 " +
            "\(nameHint ?? "遥控器")"
        )
        onPairingRequired?()
    }

    private func matches(_ candidate: CBPeripheral) -> Bool {
        guard let nameHint else { return true }
        return candidate.name?.localizedCaseInsensitiveContains(nameHint)
            == true
    }

    @discardableResult
    private func writeCommand(_ data: Data) -> Bool {
        guard let p = peripheral, let c = commandChar else { return false }
        if c.properties.contains(.write) {
            p.writeValue(data, for: c, type: .withResponse)
            return true
        } else if c.properties.contains(.writeWithoutResponse) {
            p.writeValue(data, for: c, type: .withoutResponse)
            return true
        } else {
            print("[\(logTag)] command characteristic is not writable")
            return false
        }
    }

    /// Send an ATVV keep-alive. Should be called every ~4 seconds while
    /// streaming to keep the device's audio stream open during long
    /// voice-key holds.
    private func sendKeepAlive() {
        guard isStreaming, let s = protocolHandler.codec else { return }
        do {
            let cmd = try protocolHandler.keepAliveCommand(streamID: streamID)
            writeCommand(cmd)
            // Quiet log; user only needs levels to debug.
        } catch {
            print("[\(logTag)] keep-alive error: \(error.localizedDescription)")
        }
        _ = s
    }

    /// Start a periodic timer that keeps the ATVV voice stream alive while
    /// the remote thinks the user is holding the voice button.
    private var keepAliveTimer: Timer?
    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        let timer = Timer(
            timeInterval: 4.0,
            repeats: true
        ) { [weak self] _ in
            self?.sendKeepAlive()
            self?.checkStreamHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }
    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func notifyStreaming(_ on: Bool) {
        let sr = (protocolHandler.codec == .adpcm16k) ? 16_000 : 8_000
        onStreamingChanged?(on, sr)
    }

    /// Completes the local side of an ATVV stream even when the peripheral
    /// drops the matching AUDIO_STOP notification.  This is deliberately
    /// idempotent so an eventual late AUDIO_STOP is harmless.
    private func finishAudioStreamLocally(reason: UInt8) {
        closeTimeoutWorkItem?.cancel()
        closeTimeoutWorkItem = nil
        let wasStreaming = isStreaming
        isStreaming = false
        protocolHandler.endAudioStream()
        stopKeepAliveTimer()
        if wasStreaming {
            notifyStreaming(false)
            onAudioStopped?(reason)
        }
        levelSumSq = 0
        levelCount = 0
        levelPeak = 0
        onLevel?(-120, 0)
        diagFrameCount = 0
        if let w = wavRecorder {
            w.close()
            print("[WAV] closed \(w.filename)")
            wavRecorder = nil
        }
        // Only report a stream that actually existed. Remotes replay late
        // AUDIO_STOP notifications, and logging a summary for every repeat
        // buried the useful lines and rotated the log file prematurely.
        guard wasStreaming else { return }
        let streamRMS = streamSampleCount > 0
            ? sqrt(Double(streamSumSquares) / Double(streamSampleCount))
            : 0
        let streamDB = streamRMS > 0
            ? 20.0 * log10(streamRMS / 32768.0)
            : -120
        print(
            "[\(logTag)] AUDIO_SUMMARY streamID=\(streamID) " +
            "frames=\(streamFrameCount) samples=\(streamSampleCount) " +
            "peak=\(streamPeak) rms=\(Int(streamRMS.rounded())) " +
            "db=\(Int(streamDB.rounded())) " +
            "clipped=\(streamClippedSampleCount) syncs=\(streamAudioSyncCount)"
        )
        print("[\(logTag)] AUDIO_STOP reason=0x\(String(reason, radix: 16))")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isStarted else { return }
        switch central.state {
        case .poweredOn:
            print("[\(logTag)] 蓝牙已就绪")
            reconnectAttempts = 0
            nextReconnectAt = .distantPast
            attemptConnection()
        case .poweredOff:
            print("[\(logTag)] 蓝牙未开启")
            cancelCapsRetry()
            stopHealthTimer()
            stopScanRetryTimer()
            connectTimeout?.cancel()
            connectTimeout = nil
            isScanning = false
            connectedPeripheralID = nil
            peripheral = nil
            audioChar = nil
            commandChar = nil
            controlChar = nil
            atvvCharsComplete = false
            capabilitiesRequested = false
            finishAudioStreamLocally(reason: 0xFC)
            onConnectionChanged?(false)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let n = peripheral.name ?? "(no name)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        let short = services.map { String($0.uuidString.prefix(8)) }
        // Match the configured device name as well as the shared ATVV service;
        // multiple voice remotes can advertise the same service UUID.
        guard matches(peripheral), connectedPeripheralID == nil,
              connectTimeout == nil else { return }
        print("[\(logTag)] 候选: \(n) (\(peripheral.identifier)), services=\(short), rssi=\(RSSI)")
        reconnectAttempts = 0
        nextReconnectAt = .distantPast
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // A late callback for a link we already abandoned; do not resurrect it.
        guard self.peripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectTimeout?.cancel()
        connectTimeout = nil
        connectedPeripheralID = peripheral.identifier
        isScanning = false
        reconnectAttempts = 0
        nextReconnectAt = .distantPast
        hasResetSessionForConnection = false
        pairingRequiredNotified = false
        // Every GATT session needs its own subscriptions and capabilities
        // handshake. Leaving these set from the previous session left the
        // bridge "connected" with no negotiated codec after a reconnect.
        audioChar = nil
        commandChar = nil
        controlChar = nil
        atvvCharsComplete = false
        capabilitiesRequested = false
        capsAttempts = 0
        print("[\(logTag)] 已连接")
        onConnectionChanged?(true)
        startHealthTimer()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        connectedPeripheralID = nil
        self.peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        atvvCharsComplete = false
        capabilitiesRequested = false
        print("[\(logTag)] 连接失败: \(error?.localizedDescription ?? "unknown")")
        let pairingLost = isPairingInformationLost(error)
        if pairingLost {
            notePairingInformationLost()
            // Retrying immediately just spins through scan → connect → fail
            // until the user re-pairs.
            scheduleReconnect(after: 10)
        } else {
            noteConnectFailure(error?.localizedDescription ?? "unknown")
        }
        onConnectionChanged?(false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Ignore disconnects from a peripheral that recoverConnection already
        // replaced; otherwise it would cancel the fresh connection's state.
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        closeTimeoutWorkItem?.cancel()
        closeTimeoutWorkItem = nil
        cancelCapsRetry()
        stopHealthTimer()
        connectedPeripheralID = nil
        self.peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        atvvCharsComplete = false
        capabilitiesRequested = false
        print("[\(logTag)] 断开: \(error?.localizedDescription ?? "ok")")
        let pairingLost = isPairingInformationLost(error)
        if pairingLost {
            notePairingInformationLost()
        }
        onConnectionChanged?(false)
        finishAudioStreamLocally(reason: 0xFC)
        if pairingLost {
            scheduleReconnect(after: 10)
        } else {
            // Usually the remote just went to sleep. Retry almost immediately;
            // subsequent failures back off exponentially.
            nextReconnectAt = Date().addingTimeInterval(1)
            beginScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("[\(logTag)] 服务发现失败: \(error?.localizedDescription ?? "?")")
            return
        }
        print("[\(logTag)] 发现 \(services.count) 个 service")
        for s in services {
            let tag = s.uuid == Self.serviceUUID ? " ←ATVV" : ""
            print("[\(logTag)]   svc \(s.uuid.uuidString.prefix(8))…\(tag)")
            // Discover ALL characteristics on every service so we can also
            // see HOGP (HID-over-GATT) button channels if they exist.
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars {
            let props = describeProperties(c.properties)
            let isATVV = service.uuid == Self.serviceUUID
            print("[\(logTag)]   char \(c.uuid.uuidString.prefix(8)) [\(props)]")
            switch c.uuid {
            case Self.audioUUID:
                audioChar = c
                peripheral.setNotifyValue(true, for: c)
                print("[\(logTag)]   → audio subscribed; isNotifying=\(c.isNotifying)")
                if isATVV { atvvCharsComplete = true }
            case Self.commandUUID:
                commandChar = c
                print("[\(logTag)]   → command stored")
                if c.properties.contains(.notify)
                    || c.properties.contains(.indicate)
                {
                    peripheral.setNotifyValue(true, for: c)
                    print(
                        "[\(logTag)]   → command response subscribed; " +
                        "isNotifying=\(c.isNotifying)"
                    )
                }
            case Self.controlUUID:
                controlChar = c
                peripheral.setNotifyValue(true, for: c)
                print("[\(logTag)]   → control subscribed; isNotifying=\(c.isNotifying)")
                if isATVV { atvvCharsComplete = true }
            default:
                // Auto-subscribe to any notify-capable characteristic on this
                // service — we may find button events on HOGP here.
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                    print("[\(logTag)]   → auto-subscribed (notify); isNotifying=\(c.isNotifying)")
                }
            }
        }
        if atvvCharsComplete {
            atvvCharsComplete = false
            // Defer the capabilities handshake until a reply-bearing
            // characteristic is actually notifying (see
            // maybeRequestCapabilities). Firing it here — right after
            // setNotifyValue, while isNotifying is still false — drops the
            // reply and stalls ATVV negotiation. This immediate call only
            // sends when a subscription was already active on reconnect.
            maybeRequestCapabilities()
        }
    }

    private func describeProperties(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print(
                "[\(logTag)]   notify state error " +
                "\(characteristic.uuid.uuidString.prefix(8)): " +
                error.localizedDescription
            )
            return
        }
        print(
            "[\(logTag)]   notify ready " +
            "\(characteristic.uuid.uuidString.prefix(8)); " +
            "isNotifying=\(characteristic.isNotifying)"
        )
        maybeRequestCapabilities()
    }

    /// Start the ATVV getCapabilities handshake once a reply-bearing
    /// characteristic is actually notifying. Sending it right after
    /// setNotifyValue — while isNotifying is still false — drops the reply and
    /// stalls negotiation ("尚未完成 ATVV capabilities 协商").
    private func maybeRequestCapabilities() {
        guard !capabilitiesRequested else { return }
        let controlReady = controlChar?.isNotifying == true
        let commandReady = commandChar?.isNotifying == true
        guard controlReady || commandReady else { return }
        capabilitiesRequested = true
        capsAttempts = 0
        sendCapabilitiesRequest()
    }

    /// The remote usually answers getCapabilities, but BLE notification loss
    /// can swallow the reply. Retry a few times and then rebuild the link
    /// instead of leaving the voice key dead until the app is restarted.
    private func sendCapabilitiesRequest() {
        capsAttempts += 1
        guard writeCommand(protocolHandler.getCapabilitiesCommand) else {
            recoverConnection(reason: "capabilities 无法发送")
            return
        }
        print("[\(logTag)] TX getCapabilities (attempt \(capsAttempts))")
        cancelCapsRetry()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectedPeripheralID != nil else { return }
            if self.capsAttempts < 3 {
                print(
                    "[\(self.logTag)] capabilities 超时，" +
                    "重发第 \(self.capsAttempts + 1) 次"
                )
                self.sendCapabilitiesRequest()
            } else {
                self.recoverConnection(reason: "capabilities 协商超时")
            }
        }
        capsRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func cancelCapsRetry() {
        capsRetryWorkItem?.cancel()
        capsRetryWorkItem = nil
    }

    /// Capabilities negotiated: stop the retry chain and clear backoff.
    private func noteCapabilitiesAccepted() {
        cancelCapsRetry()
        capsAttempts = 0
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("[\(logTag)] char update error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let len = data.count
        switch characteristic.uuid {
        case Self.controlUUID:
            handleControl(data)
        case Self.commandUUID:
            // Some ATVV remotes, including X6, return capabilities on the
            // bidirectional command characteristic rather than control.
            handleControl(data)
        case Self.audioUUID:
            handleAudio(data)
        default:
            print("[\(logTag)] unexpected char update \(characteristic.uuid.uuidString.prefix(8)), \(len)B")
        }
    }

    private func handleControl(_ data: Data) {
        let ev = protocolHandler.parseControl(data)
        switch ev {
        case .startSearch:
            // If already streaming, or if START_SEARCH repeats immediately,
            // keep the current session instead of opening it twice.
            let now = Date()
            if isStreaming { return }
            if now.timeIntervalSince(lastStartSearchAt) < 0.5 { return }
            lastStartSearchAt = now
            openMicrophone()
            print("[\(logTag)] TX micOpen (debounced)")
        case .capabilities(let caps):
            do {
                try protocolHandler.acceptCapabilities(caps)
                noteCapabilitiesAccepted()
                print(
                    "[\(logTag)] caps ok v\(caps.version) " +
                    "codec=\(protocolHandler.codec!) " +
                    "interaction=0x\(String(format: "%02x", caps.interactionModel)) " +
                    "frame=\(caps.frameSize)"
                )
                resetStaleSessionIfNeeded()
            } catch {
                print("[\(logTag)] caps error: \(error.localizedDescription)")
            }
        case .audioStart(let reason, let codec, let sid):
            closeTimeoutWorkItem?.cancel()
            closeTimeoutWorkItem = nil
            protocolHandler.beginAudioStream(codec: codec)
            streamID = sid
            isStreaming = true
            lastAudioFrameAt = Date()
            notifyStreaming(true)
            onAudioStarted?(reason, codec.sampleRate)
            diagFrameCount = 0
            streamFrameCount = 0
            streamSampleCount = 0
            streamPeak = 0
            streamSumSquares = 0
            streamClippedSampleCount = 0
            streamAudioSyncCount = pendingAudioSyncCount
            pendingAudioSyncCount = 0
            wavRecorder = AppStorage.recordingEnabled
                ? WavRecorder.createNext(prefix: recordingPrefix)
                : nil
            startKeepAliveTimer()
            print(
                "[\(logTag)] AUDIO_START reason=" +
                String(format: "0x%02x", reason) +
                " streamID=\(sid)"
            )
        case .audioStop(let reason):
            finishAudioStreamLocally(reason: reason)
            /*
            isStreaming = false
            protocolHandler.endAudioStream()
            notifyStreaming(false)
            levelSumSq = 0
            levelCount = 0
            levelPeak = 0
            onLevel?(-120, 0)
            diagFrameCount = 0
            stopKeepAliveTimer()
            if let w = wavRecorder {
                w.close()
                print("[WAV] closed \(w.filename)")
                wavRecorder = nil
            }
            let streamRMS = streamSampleCount > 0
                ? sqrt(Double(streamSumSquares) / Double(streamSampleCount))
                : 0
            let streamDB = streamRMS > 0
                ? 20.0 * log10(streamRMS / 32768.0)
                : -120
            print(
                "[\(logTag)] AUDIO_SUMMARY streamID=\(streamID) " +
                "frames=\(streamFrameCount) samples=\(streamSampleCount) " +
                "peak=\(streamPeak) rms=\(Int(streamRMS.rounded())) " +
                "db=\(String(format: "%.1f", streamDB)) " +
                "clipped=\(streamClippedSampleCount) syncs=\(streamAudioSyncCount)"
            )
            print("[\(logTag)] AUDIO_STOP reason=0x\(String(format: "%02x", reason))")
            */
        case .audioSync(let codec, let sequence, let pred, let stepIndex):
            protocolHandler.applyAudioSync(
                codec: codec,
                sequence: sequence,
                predictor: pred,
                stepIndex: stepIndex
            )
            if isStreaming {
                streamAudioSyncCount += 1
            } else {
                pendingAudioSyncCount += 1
            }
            print(
                "[\(logTag)] AUDIO_SYNC codec=\(codec) sequence=\(sequence) " +
                "predictor=\(pred) step=\(stepIndex) " +
                "phase=\(isStreaming ? "streaming" : "opening")"
            )
        case .micOpenError(let code):
            print("[\(logTag)] MIC_OPEN 错误: 0x\(String(format: "%04x", code))")
            onMicrophoneOpenFailed?(code)
        case .unknown(let d):
            // Capabilities-handshake uses 0x0B on the control char sometimes;
            // absorb instead of failing noisily.
            if data.first == 0x0B {
                if let caps = ATVVProtocol.parseCapabilities(data) {
                    do {
                        try protocolHandler.acceptCapabilities(caps)
                        noteCapabilitiesAccepted()
                        print(
                            "[\(logTag)] caps (fallback) v\(caps.version) " +
                            "codec=\(protocolHandler.codec!) " +
                            "interaction=0x\(String(format: "%02x", caps.interactionModel)) " +
                            "frame=\(caps.frameSize)"
                        )
                        resetStaleSessionIfNeeded()
                    } catch {
                        print("[\(logTag)] caps fallback error: \(error.localizedDescription)")
                    }
                }
            }
            // Silently ignore other unknown events.
            _ = d
        }
    }

    private func resetStaleSessionIfNeeded() {
        guard resetSessionOnConnect, !hasResetSessionForConnection else {
            return
        }
        hasResetSessionForConnection = true
        if let close = try? protocolHandler.micCloseCommand(streamID: 0) {
            writeCommand(close)
            print("[\(logTag)] TX micClose reset")
        }
    }

    private func handleAudio(_ data: Data) {
        guard isStreaming, let frame = protocolHandler.decodeAudio(data) else { return }
        if frame.samples.isEmpty { return }
        lastAudioFrameAt = Date()
        let framePeak = frame.samples.reduce(into: 0) {
            $0 = max($0, abs(Int($1)))
        }
        let frameSumSquares = frame.samples.reduce(into: Int64(0)) {
            $0 += Int64($1) * Int64($1)
        }
        streamFrameCount += 1
        streamSampleCount += frame.samples.count
        streamPeak = max(streamPeak, framePeak)
        streamSumSquares += frameSumSquares
        streamClippedSampleCount += frame.samples.reduce(into: 0) {
            if abs(Int($1)) >= 32_760 { $0 += 1 }
        }
        if streamFrameCount == 1 || streamFrameCount.isMultiple(of: 200) {
            print(
                "[\(logTag)] AUDIO_FRAMES count=\(streamFrameCount) " +
                "samples=\(streamSampleCount) recentPeak=\(framePeak)"
            )
        }

        // Diagnostic: dump first few raw bytes & first few decoded samples
        if Self.diagnosticsEnabled, diagFrameCount < 5 {
            let rawHex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            let samHex = frame.samples.prefix(8).map { String($0) }.joined(separator: ",")
            print("[AUDIO-DIAG] frame#\(diagFrameCount) raw[\(rawHex)] decoded[\(samHex)]")
            diagFrameCount += 1
        }

        // Optional developer-only recording. Production builds never create
        // a WAV because `recordingEnabled` is false.
        if let w = wavRecorder {
            w.appendSamples(frame.samples)
            w.appendRawBytes(data)
        }

        AudioPipe.shared.feed(samples: frame.samples)
        let needsLevel = onLevel != nil || Self.diagnosticsEnabled
        if needsLevel {
            levelSumSq += frame.samples.reduce(into: 0) {
                $0 += Int64($1) * Int64($1)
            }
            levelCount += frame.samples.count
            levelPeak = max(
                levelPeak,
                frame.samples.map { Int(abs(Int($0))) }.max() ?? 0
            )
        }
        if needsLevel, Date().timeIntervalSince(levelLogAt) >= 0.1 {
            let rms = levelCount > 0 ? sqrt(Double(levelSumSq) / Double(levelCount)) : 0
            let peak = levelPeak
            let db = rms > 0 ? 20.0 * log10(rms / 32768.0) : -120
            let bar = meterBar(level: db)
            if Self.diagnosticsEnabled {
                print(String(format: "[LVL] %@ ATVV rms=%.0f peak=%d  %.0f dBFS",
                             bar, rms, peak, db))
            }
            onLevel?(db, peak)
            levelSumSq = 0
            levelCount = 0
            levelPeak = 0
            levelLogAt = Date()
        }
    }

    /// Convert dBFS to a tiny ASCII bar for at-a-glance logs.
    private func meterBar(level: Double) -> String {
        let clamped = max(-60, min(0, level))
        let n = (clamped + 60) / 6   // 0..10 segments
        return "[" + String(repeating: "▓", count: Int(n)) +
                     String(repeating: "░", count: 10 - Int(n)) + "]"
    }
}
