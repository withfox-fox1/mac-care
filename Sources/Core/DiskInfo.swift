import Foundation

struct DiskInfo {
    var total: Int64
    var available: Int64

    /// ボリューム名（取得できなければ「ディスク」）
    static var volumeName: String {
        (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "ディスク"
    }

    static func current() -> DiskInfo? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity,
              let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskInfo(total: Int64(total), available: avail)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false   // "Zero KB" を避ける
    return f.string(fromByteCount: bytes)
}
