import Foundation
import IOKit
import IOKit.ps
import CoreWLAN
import Observation

// すべて読み取り専用。メニューバーパネルの表示中だけ 2 秒間隔で採取する。

// MARK: - 純粋関数（テスト対象）

enum MetricsMath {
    /// kern.memorystatus_level（空きの割合 %）→ メモリプレッシャー（%）
    static func memoryPressure(freeLevel: Int) -> Int { max(0, min(100, 100 - freeLevel)) }

    /// CPU ティック（[user, system, idle, nice] × コア数）の差分から負荷（%）を求める。カウンタの桁あふれも許容。
    static func cpuLoad(prev: [UInt32], cur: [UInt32]) -> Double {
        guard prev.count == cur.count, cur.count >= 4 else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in stride(from: 0, to: cur.count - 3, by: 4) {
            let u = UInt64(cur[i] &- prev[i]), s = UInt64(cur[i + 1] &- prev[i + 1])
            let idle = UInt64(cur[i + 2] &- prev[i + 2]), n = UInt64(cur[i + 3] &- prev[i + 3])
            busy += u + s + n; total += u + s + n + idle
        }
        return total == 0 ? 0 : Double(busy) / Double(total) * 100
    }

    /// 32 ビットのバイトカウンタ差分（桁あふれ考慮）
    static func counterDelta(prev: UInt32, cur: UInt32) -> UInt64 { UInt64(cur &- prev) }

    /// 履歴に追加して末尾 limit 件だけ残す
    static func appended(_ history: [Double], _ v: Double, limit: Int = 30) -> [Double] {
        let h = history + [v]
        return h.count > limit ? Array(h.suffix(limit)) : h
    }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSec / 1_000_000) }
        if bytesPerSec >= 1_000 { return "\(Int((bytesPerSec / 1_000).rounded())) KB/s" }
        return "\(Int(bytesPerSec.rounded())) B/s"
    }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)時間\(m % 60)分" : "\(m)分" }

    /// IOPS の BatteryHealth 表記 → 日本語
    static func batteryCondition(_ s: String?) -> String? {
        switch s {
        case "Good": "正常"
        case "Fair": "まもなく交換"
        case "Poor": "交換を推奨"
        case .some(let v) where !v.isEmpty: v
        default: nil
        }
    }
}

// MARK: - プロセス（ps）

struct ProcEntry: Equatable {
    var pid: Int
    var rssKB: Int
    var cpu: Double
    var path: String
}

struct AppUsage: Equatable {
    var name: String
    var memoryBytes: Int64
    var cpu: Double
}

enum ProcessStats {
    /// `ps -axo pid=,rss=,%cpu=,comm=`（comm は空白を含むため残り全部）
    static func parse(_ output: String) -> [ProcEntry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let rss = Int(parts[1]), let cpu = Double(parts[2]) else { return nil }
            return ProcEntry(pid: pid, rssKB: rss, cpu: cpu, path: String(parts[3]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// "/Applications/Google Chrome.app/Contents/.../Google Chrome Helper" → "Google Chrome"。.app が無ければ末尾の名前
    static func appName(path: String) -> String {
        for comp in path.split(separator: "/") where comp.hasSuffix(".app") {
            return String(comp.dropLast(4))
        }
        return friendlyName((path as NSString).lastPathComponent)
    }

    /// .app に属さないプロセスの表示名（主要なシステムプロセスは役割を併記する）
    static let knownNames: [String: String] = [
        "WindowServer": "WindowServer（画面描画）",
        "kernel_task": "kernel_task（システム）",
        "mds": "Spotlight（索引作成）", "mds_stores": "Spotlight（索引作成）", "mdworker": "Spotlight（索引作成）",
        "mdworker_shared": "Spotlight（索引作成）", "mdsync": "Spotlight（索引作成）",
        "backupd": "Time Machine", "bird": "iCloud Drive（同期）", "cloudd": "iCloud（同期）",
        "photoanalysisd": "写真（解析）", "mediaanalysisd": "写真（解析）",
        "softwareupdated": "ソフトウェア・アップデート", "xprotectd": "XProtect（マルウェア対策）",
        "coreaudiod": "オーディオ", "logd": "ログ記録", "BackgroundShortcutRunner": "ショートカット",
    ]

    /// 逆ドメイン形式（com.vendor.Product.Helper）は vendor を除いた名前にする。WebKit の補助プロセスはまとめる。
    static func friendlyName(_ name: String) -> String {
        if let k = knownNames[name] { return k }
        if name.hasPrefix("com.apple.WebKit.") { return "Web コンテンツ（WebKit）" }
        let parts = name.split(separator: ".")
        if parts.count >= 3, ["com", "org", "io", "net", "jp", "co"].contains(parts[0]) {
            return parts.dropFirst(2).joined(separator: " ")
        }
        return name
    }

    /// アプリ単位（ヘルパー込み）に集計する
    static func aggregate(_ entries: [ProcEntry]) -> [AppUsage] {
        var d: [String: AppUsage] = [:]
        for e in entries {
            let n = appName(path: e.path)
            var u = d[n] ?? AppUsage(name: n, memoryBytes: 0, cpu: 0)
            u.memoryBytes += Int64(e.rssKB) * 1024
            u.cpu += e.cpu
            d[n] = u
        }
        return Array(d.values)
    }
    static func topMemory(_ u: [AppUsage]) -> AppUsage? { u.max { $0.memoryBytes < $1.memoryBytes } }
    static func topCPU(_ u: [AppUsage]) -> AppUsage? { u.max { $0.cpu < $1.cpu } }

    static func snapshot() async -> [AppUsage] {
        guard let r = try? await Shell.run("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="]), r.exitCode == 0 else { return [] }
        return aggregate(parse(r.stdout))
    }
}

// MARK: - メモリ・CPU

enum MemoryMetrics {
    static func pressure() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return MetricsMath.memoryPressure(freeLevel: Int(level))
    }
}

final class CPULoadSampler {
    private var prev: [UInt32]?

    private func ticks() -> [UInt32]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        return (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
    }

    /// 前回採取との差分から負荷（%）。初回は nil
    func sample() -> Double? {
        guard let cur = ticks() else { return nil }
        defer { prev = cur }
        guard let p = prev else { return nil }
        return MetricsMath.cpuLoad(prev: p, cur: cur)
    }
}

// MARK: - バッテリー

struct BatteryInfo: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var minutes: Int?
    var condition: String?
    var cycleCount: Int?

    /// 内蔵バッテリーが無い Mac では nil
    static func read() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let t = d[key] as? Int
            return BatteryInfo(percent: mx > 0 ? cur * 100 / mx : cur, isCharging: charging, onAC: onAC,
                               minutes: (t ?? -1) >= 0 ? t : nil,
                               condition: MetricsMath.batteryCondition(d[kIOPSBatteryHealthKey] as? String),
                               cycleCount: cycleCount())
        }
        return nil
    }

    private static func cycleCount() -> Int? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        return IORegistryEntryCreateCFProperty(svc, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }
}

// MARK: - ネットワーク

struct NetworkCounters {
    var perInterface: [String: (rx: UInt32, tx: UInt32)]
    var date: Date

    static func read() -> NetworkCounters {
        var out: [String: (UInt32, UInt32)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let a = cur.pointee
                if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data,
                   Int32(a.ifa_flags) & IFF_UP != 0, Int32(a.ifa_flags) & IFF_LOOPBACK == 0 {
                    let name = String(cString: a.ifa_name)
                    if name.hasPrefix("en") {
                        let d = data.assumingMemoryBound(to: if_data.self).pointee
                        out[name] = (d.ifi_ibytes, d.ifi_obytes)
                    }
                }
                p = a.ifa_next
            }
            freeifaddrs(ifap)
        }
        return NetworkCounters(perInterface: out, date: Date())
    }

    /// 前回からの (下り, 上り) バイト/秒
    static func throughput(prev: NetworkCounters, cur: NetworkCounters) -> (down: Double, up: Double) {
        let dt = cur.date.timeIntervalSince(prev.date)
        guard dt > 0.1 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, c) in cur.perInterface {
            guard let p = prev.perInterface[name] else { continue }
            rx += MetricsMath.counterDelta(prev: p.rx, cur: c.rx)
            tx += MetricsMath.counterDelta(prev: p.tx, cur: c.tx)
        }
        return (Double(rx) / dt, Double(tx) / dt)
    }
}

enum WiFiInfo {
    /// (Wi-Fi 接続か, SSID)。SSID は位置情報の許可がないと nil になる
    static func current() -> (isWiFi: Bool, ssid: String?) {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return (false, nil) }
        let s = i.ssid()
        return (s != nil || i.serviceActive(), s)
    }
}

enum SpeedTest {
    /// `networkQuality -c` の JSON → (下り, 上り) Mbps
    static func parse(_ json: String) -> (down: Double, up: Double)? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dl = (o["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (o["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return (dl / 1_000_000, ul / 1_000_000)
    }

    static func run() async -> (down: Double, up: Double)? {
        guard let r = try? await Shell.run("/usr/bin/networkQuality", ["-c"]), r.exitCode == 0 else { return nil }
        return parse(r.stdout)
    }
}

enum MachineInfo {
    /// 例: "Mac17,3"
    static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
    /// IODeviceTree:/product の product-name（例: "MacBook Air (13-inch, M5)"）。Apple Silicon で取得できる
    static var productName: String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 製品名から括弧内の仕様を除いた表示名（"MacBook Air (13-inch, M5)" → "MacBook Air"）
    static func shortProductName(_ name: String) -> String {
        let base = name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
        return base.trimmingCharacters(in: .whitespaces)
    }

    /// 機種名。product-name が取れればそれを使い、取れない場合は識別子とバッテリーの有無で推定する
    static var displayName: String {
        if let p = productName, !shortProductName(p).isEmpty { return shortProductName(p) }
        let id = modelIdentifier
        if id.hasPrefix("MacBookAir") { return "MacBook Air" }
        if id.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if id.hasPrefix("Macmini") { return "Mac mini" }
        if id.hasPrefix("iMac") { return "iMac" }
        if id.hasPrefix("MacPro") { return "Mac Pro" }
        return BatteryInfo.read() != nil ? "MacBook" : "Mac"
    }
}

// MARK: - サンプラー（パネル表示中のみ動かす）

@MainActor @Observable
final class MetricsModel {
    var memoryPressure: Int? = nil
    var topMemory: AppUsage? = nil
    var cpuLoad: Double? = nil
    var cpuHistory: [Double] = []
    var topCPU: AppUsage? = nil
    var battery: BatteryInfo? = nil
    var hasBattery = true
    var netDown: Double = 0
    var netUp: Double = 0
    var wifi: (isWiFi: Bool, ssid: String?) = (true, nil)
    var devices: [BluetoothDeviceInfo] = []
    var speedTesting = false
    var speedResult: (down: Double, up: Double)? = nil
    var speedFailed = false

    private let cpu = CPULoadSampler()
    private var prevNet: NetworkCounters? = nil
    private var timer: Timer?
    private var busy = false
    private var tick = 0
    let modelName = MachineInfo.displayName
    var interval: TimeInterval = 2

    var isSampling: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        prevNet = nil; tick = 0
        _ = cpu.sample()   // 基準値
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func sample() {
        memoryPressure = MemoryMetrics.pressure()
        if let l = cpu.sample() { cpuLoad = l; cpuHistory = MetricsMath.appended(cpuHistory, l) }
        battery = BatteryInfo.read(); hasBattery = battery != nil
        let cur = NetworkCounters.read()
        if let p = prevNet { let t = NetworkCounters.throughput(prev: p, cur: cur); netDown = t.down; netUp = t.up }
        prevNet = cur
        if tick % 5 == 0 { wifi = WiFiInfo.current() }   // 10 秒ごと
        let refreshDevices = tick % 5 == 0
        tick += 1
        guard !busy else { return }
        busy = true
        Task {
            let usage = await ProcessStats.snapshot()
            let levels = refreshDevices ? await BluetoothInfo.readLevels() : nil
            self.topMemory = ProcessStats.topMemory(usage)
            self.topCPU = ProcessStats.topCPU(usage)
            if let levels { self.devices = BluetoothInfo.connected(levels: levels) }
            self.busy = false
        }
    }

    func runSpeedTest() {
        guard !speedTesting else { return }
        speedTesting = true; speedFailed = false
        Task {
            let r = await SpeedTest.run()
            speedResult = r; speedFailed = r == nil; speedTesting = false
        }
    }
}
