import Foundation
import Observation
import AVFoundation

/// 圧縮候補 1 本。見込みは目安（hevc_videotoolbox -q:v 50 の実測に基づく）。
struct CompressCandidate: Identifiable, Hashable {
    let url: URL
    let size: Int64
    /// 再生時間（秒）。取得できない場合は nil
    let duration: Double?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }

    var bitrate: Double? { CompressEstimator.bitrate(size: size, duration: duration) }
    var estimatedOutput: Int64? { CompressEstimator.estimatedOutput(size: size, duration: duration) }
    var estimatedSaving: Int64? { CompressEstimator.estimatedSaving(size: size, duration: duration) }
    var isLowBitrate: Bool { CompressEstimator.isLowBitrate(size: size, duration: duration) }
    var defaultSelected: Bool { CompressEstimator.defaultSelected(size: size, duration: duration) }
}

/// 圧縮候補の判定と見込みの計算（純粋関数。テスト対象）
enum CompressEstimator {
    /// 候補とする最小サイズ（100MB）
    static let minBytes: Int64 = 100_000_000
    /// HEVC は同等画質で H.264 よりおおむね 40% 低いビットレートにできる（一般的な目安）。入力に掛ける係数
    static let hevcBitrateFactor: Double = 0.6
    /// 出力ビットレートの上限（実測 1.8〜3.4 Mbps、中央値 約 2.3 Mbps）
    static let outputBitrateCap: Double = 2_500_000
    /// これ未満は低ビットレート（圧縮効果が小さい）
    static let lowBitrateThreshold: Double = 4_000_000

    /// 入力ビットレート（bps）。duration が無い・0 以下なら nil
    static func bitrate(size: Int64, duration: Double?) -> Double? {
        guard let d = duration, d > 0, d.isFinite else { return nil }
        return Double(size) * 8 / d
    }

    static func estimatedOutput(size: Int64, duration: Double?) -> Int64? {
        guard let d = duration, let br = bitrate(size: size, duration: duration) else { return nil }
        return Int64(d * min(br * hevcBitrateFactor, outputBitrateCap) / 8)
    }

    /// 推定削減量（0 未満は 0）
    static func estimatedSaving(size: Int64, duration: Double?) -> Int64? {
        estimatedOutput(size: size, duration: duration).map { max(0, size - $0) }
    }

    /// 削減量の表示（0 は「わずか」）
    static func savingText(_ bytes: Int64) -> String { bytes <= 0 ? "わずか" : "約 \(formatBytes(bytes))" }

    static func isLowBitrate(size: Int64, duration: Double?) -> Bool {
        bitrate(size: size, duration: duration).map { $0 < lowBitrateThreshold } ?? false
    }

    /// 既定のチェック: 長さが取れて、低ビットレートでないもの
    static func defaultSelected(size: Int64, duration: Double?) -> Bool {
        guard let br = bitrate(size: size, duration: duration) else { return false }
        return br >= lowBitrateThreshold
    }

    /// パスのいずれかの構成要素が cache / caches（大文字小文字を無視）ならキャッシュ扱い
    static func isCachePath(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { ["cache", "caches"].contains($0.lowercased()) }
    }

    /// スキャン結果から、HEVC 判定前に絞れる条件（サイズ・拡張子・キャッシュ除外）
    static func isPreCandidate(_ f: LargeFile) -> Bool {
        f.isVideo && f.size >= minBytes && !isCachePath(f.url)
    }

    /// キューに入っている／完了したファイルを除く
    static func visible(_ list: [CompressCandidate], excludingPaths: Set<String>) -> [CompressCandidate] {
        list.filter { !excludingPaths.contains($0.url.path) }
    }

    static func totalSize(_ list: [CompressCandidate]) -> Int64 { list.reduce(0) { $0 + $1.size } }
    /// 見込みが不明のものは 0 として合計
    static func totalSaving(_ list: [CompressCandidate]) -> Int64 { list.reduce(0) { $0 + ($1.estimatedSaving ?? 0) } }

    /// ビットレート表示（例: 12.3 Mbps）
    static func bitrateText(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        return bps >= 1_000_000 ? String(format: "%.1f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }
}

@MainActor @Observable
final class CompressCandidatesModel {
    private(set) var candidates: [CompressCandidate] = []
    /// チェック済みの候補 id（パス）
    var selected: Set<String> = []
    var scanning = false
    var hasScanned = false

    private var scanTask: Task<Void, Never>?

    /// 実行中の検索があれば完了を待つ（二重実行しない）
    func scan(settings: Settings) async {
        if let t = scanTask { await t.value; return }
        let t = Task { await self.performScan(settings: settings) }
        scanTask = t
        await t.value
        scanTask = nil
    }

    private func performScan(settings: Settings) async {
        scanning = true
        let roots = settings.largeFileRoots.map { URL(fileURLWithPath: $0) }
        let found = await Task.detached(priority: .userInitiated) { () -> [LargeFile] in
            LargeFileScanner.scan(roots: roots, thresholdBytes: CompressEstimator.minBytes)
                .filter(CompressEstimator.isPreCandidate)
        }.value
        var out: [CompressCandidate] = []
        for f in found {
            if await VideoCodec.isHEVC(f.url) { continue }
            out.append(CompressCandidate(url: f.url, size: f.size, duration: await Self.duration(of: f.url)))
        }
        candidates = out
        selected = Set(out.filter(\.defaultSelected).map(\.id))
        hasScanned = true; scanning = false
    }

    /// AVFoundation で再生時間を取得（外部ツール不要）。取れなければ nil
    static func duration(of url: URL) async -> Double? {
        guard let t = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let s = CMTimeGetSeconds(t)
        return s.isFinite && s > 0 ? s : nil
    }

    /// キュー追加済みの候補を一覧と選択から外す
    func remove(paths: Set<String>) {
        candidates.removeAll { paths.contains($0.url.path) }
        selected.subtract(paths)
    }
}
