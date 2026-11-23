import Foundation

struct BatterySample: Codable, Identifiable {
    let id: UUID
    let remote: String
    let percent: Int
    let timestamp: Date
}

/// Persistent battery readings for both remotes. Readings arrive on connect
/// and every ten minutes afterwards, so the file stays small; anything older
/// than 30 days is pruned on load.
final class BatteryHistoryStore: ObservableObject {
    static let shared = BatteryHistoryStore()

    @Published private(set) var samples: [BatterySample] = []

    private let fileURL: URL
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    private let maximumSamples = 6000
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        fileURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/vRemote/battery-history.json")
        let cutoff = Date().addingTimeInterval(-retention)
        samples = Self.load(from: fileURL).filter { $0.timestamp >= cutoff }
    }

    func record(_ percent: Int, remote: VoiceRemoteID) {
        guard (0...100).contains(percent) else { return }
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            self?.append(percent, remote: remote, at: now)
        }
    }

    func samples(for remote: VoiceRemoteID) -> [BatterySample] {
        samples.filter { $0.remote == remote.rawValue }
    }

    private func append(_ percent: Int, remote: VoiceRemoteID, at date: Date) {
        if let last = samples.last(where: { $0.remote == remote.rawValue }),
           last.percent == percent,
           date.timeIntervalSince(last.timestamp) < 10 * 60 {
            return
        }
        samples.append(BatterySample(
            id: UUID(),
            remote: remote.rawValue,
            percent: percent,
            timestamp: date
        ))
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = samples
        let url = fileURL
        let work = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[BATTERY] 保存电量历史失败: \(error.localizedDescription)")
            }
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 2, execute: work)
    }

    private static func load(from url: URL) -> [BatterySample] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BatterySample].self, from: data)
        else { return [] }
        return decoded.sorted { $0.timestamp < $1.timestamp }
    }
}
