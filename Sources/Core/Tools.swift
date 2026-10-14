import Foundation

/// 外部ツールの検出（Homebrew の標準インストール先のみ探索）
struct ToolInfo: Identifiable {
    let name: String
    let path: String?
    var id: String { name }
    var isAvailable: Bool { path != nil }
}

enum Tools {
    static let names = ["yara", "yarac", "clamscan", "freshclam", "ffmpeg", "ffprobe", "brew"]
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let installHint = "brew install yara clamav ffmpeg"

    static func locate(_ name: String) -> String? {
        for dir in searchDirs {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func all() -> [ToolInfo] {
        names.map { ToolInfo(name: $0, path: locate($0)) }
    }

    static func path(_ name: String) -> String? { locate(name) }
}
