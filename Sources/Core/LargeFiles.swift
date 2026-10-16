import Foundation
import CoreServices
import Observation
import AVFoundation

struct LargeFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let lastUsed: Date
    let kind: String
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
    var isVideo: Bool { VideoCompressor.supportedExtensions.contains(url.pathExtension.lowercased()) }
    /// 映像が HEVC（圧縮済み）か。スキャン後に判定する
    var isHEVC = false
    /// 圧縮の提案対象（HEVC 以外の動画）
    var needsCompression: Bool { isVideo && !isHEVC }
}

enum LargeFileScanner {
    /// 閾値以上のファイルを列挙する。~/Library・隠し項目・パッケージ内・node_modules は除外。
    static func scan(roots: [URL], thresholdBytes: Int64, library: URL? = nil,
                     progress: ((Int) -> Void)? = nil) -> [LargeFile] {
        let lib = (library ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .localizedTypeDescriptionKey]
        var out: [LargeFile] = []
        var seen = 0
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in en {
                guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    if u.lastPathComponent == "node_modules" || u.standardizedFileURL.path == lib {
                        en.skipDescendants()
                    }
                    continue
                }
                seen += 1
                if seen % 20000 == 0 { progress?(seen) }
                guard v.isRegularFile == true, let s = v.totalFileAllocatedSize, Int64(s) >= thresholdBytes else { continue }
                out.append(LargeFile(url: u, size: Int64(s),
                                     lastUsed: lastUsed(u) ?? v.contentModificationDate ?? .distantPast,
                                     kind: v.localizedTypeDescription ?? "ファイル"))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Spotlight の kMDItemLastUsedDate
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let v = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return v as? Date
    }
}

@MainActor @Observable
final class LargeFilesModel {
    var files: [LargeFile] = []
    var scanning = false
    var hasScanned = false
    var lastScannedAt: Date? = nil
    var info = ""
    var message: String? = nil

    private var scanTask: Task<Void, Never>?

    /// 実行中のスキャンがあれば完了を待つ
    func scan(settings: Settings) async {
        if let t = scanTask { await t.value; return }
        let t = Task { await self.performScan(settings: settings) }
        scanTask = t
        await t.value
        scanTask = nil
    }

    private func performScan(settings: Settings) async {
        scanning = true; message = nil
        let roots = settings.largeFileRoots.map { URL(fileURLWithPath: $0) }
        let threshold = Int64(settings.largeFileThresholdMB) * 1_000_000
        let start = Date()
        let r = await Task.detached(priority: .userInitiated) {
            LargeFileScanner.scan(roots: roots, thresholdBytes: threshold)
        }.value
        var marked = r
        for i in marked.indices where marked[i].isVideo {
            marked[i].isHEVC = await VideoCodec.isHEVC(marked[i].url)
        }
        files = marked
        hasScanned = true; lastScannedAt = Date(); scanning = false
        info = "\(r.count) 件 / 合計 \(formatBytes(r.reduce(0) { $0 + $1.size })) （\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）"
    }

    /// スナップショットされたファイルのみをゴミ箱へ。許可範囲は呼び出し側が渡す（設定の検索範囲）。
    func trash(_ targets: [LargeFile], roots: [URL]) async {
        let (failed, movedBytes) = await Task.detached { () -> (Int, Int64) in
            var f = 0
            var b: Int64 = 0
            for t in targets { do { try SafeTrash.trash(t.url, allowedRoots: roots); b += t.size } catch { f += 1 } }
            return (f, b)
        }.value
        let gone = Set(targets.map(\.id))
        files.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        message = failed > 0 ? "\(failed) 件をゴミ箱へ移動できませんでした（検索範囲外、または保護対象）。" : nil
        TrashNotice.post(TrashOutcome(moved: targets.count - failed, failed: failed, bytes: movedBytes))
    }
}

/// 動画のコーデック判定（AVFoundation。外部ツール不要）
enum VideoCodec {
    static let hevcSubTypes: Set<FourCharCode> = [kCMVideoCodecType_HEVC, 0x68657631]   // 'hvc1', 'hev1'

    static func isHEVC(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descs = try? await track.load(.formatDescriptions) else { return false }
        return descs.contains { hevcSubTypes.contains(CMFormatDescriptionGetMediaSubType($0)) }
    }
}
