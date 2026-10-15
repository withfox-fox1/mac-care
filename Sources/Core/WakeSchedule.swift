import Foundation
import IOKit.pwr_mgt

/// フルスキャン前にスリープから復帰させるための pmset 繰り返しスケジュール
enum WakeSchedule {
    /// フルスキャン時刻の何分前に起こすか
    static let leadMinutes = 2

    /// 起床時刻（"HH:MM:SS"）。0:00 のスキャンなら前日 23:58:00。
    static func wakeTime(hour: Int, minute: Int) -> String {
        let total = ((hour * 60 + minute - leadMinutes) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d:00", total / 60, total % 60)
    }

    static func applyArguments(hour: Int, minute: Int) -> [String] {
        ["repeat", "wake", "MTWRFSU", wakeTime(hour: hour, minute: minute)]
    }
    static let cancelArguments = ["repeat", "cancel"]

    /// 管理者権限で pmset を実行する AppleScript（引数は固定の英数字のみで組み立てる）
    static func appleScript(arguments: [String]) -> String {
        "do shell script \"/usr/bin/pmset \(arguments.joined(separator: " "))\" with administrator privileges"
    }

    struct RepeatingEvent: Equatable {
        var kind: String       // wake / wakepoweron / sleep / shutdown ...
        var time: String       // "HH:MM:SS"
        var days: String       // 原文
    }

    /// `pmset -g sched` の「Repeating power events」を解析する
    static func parseRepeating(_ output: String) -> [RepeatingEvent] {
        var inSection = false
        var out: [RepeatingEvent] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("power events:") { inSection = line.hasPrefix("Repeating"); continue }
            guard inSection, !line.isEmpty, let atR = line.range(of: " at ") else { continue }
            let kind = String(line[..<atR.lowerBound])
            let rest = String(line[atR.upperBound...])
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let t = parts.first, let time = normalize(t) else { continue }
            out.append(RepeatingEvent(kind: kind, time: time, days: parts.count > 1 ? parts[1] : ""))
        }
        return out
    }

    /// "11:58PM" / "23:58:00" → "23:58:00"
    static func normalize(_ s: String) -> String? {
        let up = s.uppercased()
        let pm = up.hasSuffix("PM"), am = up.hasSuffix("AM")
        let core = up.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "")
        let c = core.split(separator: ":").compactMap { Int($0) }
        guard c.count >= 2 else { return nil }
        var h = c[0]
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        guard (0..<24).contains(h), (0..<60).contains(c[1]) else { return nil }
        return String(format: "%02d:%02d:%02d", h, c[1], c.count > 2 ? c[2] : 0)
    }

    enum Existing: Equatable {
        case none
        case ours
        case foreign([RepeatingEvent])
    }

    /// 既存の繰り返しスケジュールが MacCare 設定（ourTime）のものだけか、別のものがあるか
    static func classify(_ events: [RepeatingEvent], ourTime: String?) -> Existing {
        if events.isEmpty { return .none }
        if let ourTime, events.allSatisfy({ $0.kind.hasPrefix("wake") && $0.time == ourTime }) { return .ours }
        return .foreign(events)
    }
}

/// 管理者権限での pmset 実行（ユーザーの明示操作からのみ呼ぶ）
enum WakeScheduler {
    static func currentEvents() async -> [WakeSchedule.RepeatingEvent] {
        let r = try? await Shell.run("/usr/bin/pmset", ["-g", "sched"])
        return WakeSchedule.parseRepeating(r?.stdout ?? "")
    }

    /// 戻り値: nil=成功、文字列=エラー内容（キャンセル含む）
    static func run(arguments: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var err: NSDictionary?
                let script = NSAppleScript(source: WakeSchedule.appleScript(arguments: arguments))
                _ = script?.executeAndReturnError(&err)
                if let err { cont.resume(returning: (err[NSAppleScript.errorMessage] as? String) ?? "pmset の実行に失敗しました") }
                else { cont.resume(returning: nil) }
            }
        }
    }
}

/// フルスキャン中にスリープさせないための電源アサーション
final class SleepGuard {
    private var ids: [IOPMAssertionID] = []

    init(reason: String) {
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess {
                ids.append(id)
            }
        }
    }
    var isActive: Bool { !ids.isEmpty }
    func release() { ids.forEach { IOPMAssertionRelease($0) }; ids = [] }
    deinit { release() }
}
