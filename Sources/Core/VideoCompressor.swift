import Foundation
import Observation

enum VideoPreset: String, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var quality: Int { self == .standard ? 50 : 60 }
    var label: String { self == .standard ? "標準 (-q:v 50)" : "高画質 (-q:v 60)" }
}

struct MediaInfo: Equatable {
    var duration: Double
    var videoCodec: String?
    var hasAudio: Bool
}

enum CompressOutcome: Equatable {
    case done(saved: Int64, output: URL)
    case skipped(String)
    case failed(String)
    case cancelled
}

/// 実行中の ffmpeg の一時停止/再開用
final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32 = 0
    func setPID(_ p: Int32) { lock.lock(); pid = p; lock.unlock() }
    func pause() { lock.lock(); if pid > 0 { kill(pid, SIGSTOP) }; lock.unlock() }
    func resume() { lock.lock(); if pid > 0 { kill(pid, SIGCONT) }; lock.unlock() }
}

enum VideoCompressor {
    static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v"]
    typealias Verifier = (_ input: MediaInfo, _ inputSize: Int64, _ output: MediaInfo, _ outputSize: Int64) -> String?

    static func probe(_ url: URL, ffprobe: String) async throws -> MediaInfo {
        let r = try await Shell.run(ffprobe, ["-v", "error", "-show_entries",
                                              "stream=codec_type,codec_name:format=duration",
                                              "-of", "json", url.path])
        guard r.exitCode == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        else { throw ShellError.launchFailed("ffprobe 失敗: \(r.stderr)") }
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let dur = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        return MediaInfo(duration: dur, videoCodec: video?["codec_name"] as? String,
                         hasAudio: streams.contains { $0["codec_type"] as? String == "audio" })
    }

    static func shouldSkip(_ info: MediaInfo) -> Bool { info.videoCodec == "hevc" }

    /// 出力名: <名前>.mp4。既にあれば <名前> (圧縮).mp4（以降 (圧縮 2) …）
    static func outputURL(for input: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var cand = dir.appendingPathComponent("\(stem).mp4")
        var n = 1
        while exists(cand) {
            cand = dir.appendingPathComponent(n == 1 ? "\(stem) (圧縮).mp4" : "\(stem) (圧縮 \(n)).mp4")
            n += 1
        }
        return cand
    }

    /// 検証。問題なければ nil、あれば理由。
    static func verify(input: MediaInfo, inputSize: Int64, output: MediaInfo, outputSize: Int64) -> String? {
        if output.videoCodec == nil { return "出力に映像ストリームがありません" }
        if input.hasAudio != output.hasAudio { return "音声ストリームの有無が元と一致しません" }
        if abs(input.duration - output.duration) > 1.0 { return "長さが元と1秒を超えて異なります" }
        if outputSize >= inputSize { return "出力が元のファイルより小さくなりませんでした" }
        return nil
    }

    /// 1ファイルの圧縮。失敗・中止時は作成した出力のみゴミ箱へ（SafeTrash 経由）。
    static func compress(input: URL, preset: VideoPreset, ffmpeg: String, ffprobe: String,
                         trashRoots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())],
                         control: JobControl = JobControl(),
                         verifier: Verifier = { verify(input: $0, inputSize: $1, output: $2, outputSize: $3) },
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> CompressOutcome {
        let fm = FileManager.default
        guard let inAttr = try? fm.attributesOfItem(atPath: input.path),
              let inSize = (inAttr[.size] as? NSNumber)?.int64Value else { return .failed("入力ファイルを読めません") }
        let inInfo: MediaInfo
        do { inInfo = try await probe(input, ffprobe: ffprobe) }
        catch is CancellationError { return .cancelled }
        catch { return .failed("解析に失敗しました: \(error)") }
        if inInfo.videoCodec == nil { return .failed("映像ストリームがありません") }
        if shouldSkip(inInfo) { return .skipped("HEVC 変換済み") }

        let out = outputURL(for: input)
        let outDir = out.deletingLastPathComponent()
        // 自分が作った出力ファイルだけをゴミ箱へ送る
        func discardOutput() {
            if fm.fileExists(atPath: out.path) { try? SafeTrash.trash(out, allowedRoots: [outDir]) }
        }
        let dur = inInfo.duration
        let args = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a?",
                    "-c:v", "hevc_videotoolbox", "-q:v", "\(preset.quality)", "-tag:v", "hvc1",
                    "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
                    "-progress", "pipe:1", "-nostats", out.path]
        let res: ShellResult
        do {
            res = try await Shell.run(ffmpeg, args, onLine: { line in
                if dur > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                    progress(min(1, max(0, us / 1_000_000 / dur)))
                }
            }, onStart: { control.setPID($0) })
        } catch is CancellationError {
            control.setPID(0); discardOutput(); return .cancelled
        } catch {
            control.setPID(0); discardOutput(); return .failed("ffmpeg を起動できません: \(error)")
        }
        control.setPID(0)
        if res.exitCode != 0 {
            discardOutput()
            let last = res.stderr.split(separator: "\n").last.map(String.init) ?? ""
            return .failed("ffmpeg が失敗しました (\(res.exitCode)): \(last)")
        }
        let outSize = ((try? fm.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let outInfo: MediaInfo
        do { outInfo = try await probe(out, ffprobe: ffprobe) }
        catch is CancellationError { discardOutput(); return .cancelled }
        catch { discardOutput(); return .failed("出力の検証に失敗しました: \(error)") }
        if let reason = verifier(inInfo, inSize, outInfo, outSize) {
            discardOutput()
            return .failed("検証失敗（元ファイルは残しました）: \(reason)")
        }
        // 日付を引き継ぐ
        var attrs: [FileAttributeKey: Any] = [:]
        if let d = inAttr[.creationDate] { attrs[.creationDate] = d }
        if let d = inAttr[.modificationDate] { attrs[.modificationDate] = d }
        try? fm.setAttributes(attrs, ofItemAtPath: out.path)
        do { try SafeTrash.trash(input, allowedRoots: trashRoots) }
        catch { return .failed("圧縮は成功しましたが元ファイルをゴミ箱へ移動できませんでした: \(error)") }
        let saved = inSize - outSize
        try? History.append(HistoryEntry(date: Date(), kind: .compress, target: input.path, bytes: saved,
                                         result: "ok", detail: "出力: \(out.path)"))
        return .done(saved: saved, output: out)
    }
}

@MainActor @Observable
final class CompressQueue {
    enum Status: Equatable {
        case waiting, running, paused
        case done(saved: Int64), skipped(String), failed(String), cancelled
    }
    struct Job: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .waiting
        var progress: Double = 0
        var startedAt: Date? = nil
        var eta: TimeInterval? = nil
    }

    var jobs: [Job] = []
    var preset: VideoPreset = .standard
    var isRunning = false
    var isPaused = false
    var message: String? = nil

    private let control = JobControl()
    private var currentTask: Task<CompressOutcome, Never>?
    private var stopRequested = false
    private var pausedAt: Date? = nil

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls where VideoCompressor.supportedExtensions.contains(u.pathExtension.lowercased()) {
            if jobs.contains(where: { $0.url == u && ($0.status == .waiting || $0.status == .running) }) { continue }
            jobs.append(Job(url: u)); n += 1
        }
        return n
    }

    func start() {
        guard !isRunning else { return }
        guard let ffmpeg = Tools.path("ffmpeg"), let ffprobe = Tools.path("ffprobe") else {
            message = "ffmpeg が見つかりません。\(Tools.installHint) を実行してください。"; return
        }
        message = nil; isRunning = true; stopRequested = false
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "動画圧縮中")
        Task { [weak self] in
            while let me = self, !me.stopRequested,
                  let idx = me.jobs.firstIndex(where: { $0.status == .waiting }) {
                await me.run(index: idx, ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
            ProcessInfo.processInfo.endActivity(activity)
            self?.isRunning = false; self?.isPaused = false
        }
    }

    private func run(index: Int, ffmpeg: String, ffprobe: String) async {
        let id = jobs[index].id, url = jobs[index].url
        jobs[index].status = .running; jobs[index].startedAt = Date(); jobs[index].progress = 0
        let preset = self.preset, control = self.control
        let model = self
        let t = Task.detached { () -> CompressOutcome in
            await VideoCompressor.compress(input: url, preset: preset, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                           control: control, progress: { p in
                Task { @MainActor in model.updateProgress(id, p) }
            })
        }
        currentTask = t
        let outcome = await t.value
        currentTask = nil
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .done(let saved, _): jobs[i].status = .done(saved: saved); jobs[i].progress = 1
        case .skipped(let r): jobs[i].status = .skipped(r)
        case .failed(let r): jobs[i].status = .failed(r)
        case .cancelled: jobs[i].status = .cancelled
        }
        jobs[i].eta = nil
    }

    private func updateProgress(_ id: UUID, _ p: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .running else { return }
        jobs[i].progress = p
        if let s = jobs[i].startedAt, p > 0.01 { jobs[i].eta = Date().timeIntervalSince(s) * (1 - p) / p }
    }

    func togglePause() {
        guard isRunning, let i = jobs.firstIndex(where: { $0.status == .running || $0.status == .paused }) else { return }
        if isPaused {
            control.resume(); isPaused = false
            if let p = pausedAt, let s = jobs[i].startedAt { jobs[i].startedAt = s.addingTimeInterval(Date().timeIntervalSince(p)) }
            jobs[i].status = .running
        } else {
            control.pause(); isPaused = true; pausedAt = Date(); jobs[i].status = .paused
        }
    }

    /// キュー全体を中止（実行中のジョブは中止し、未処理は待機のまま残す）
    func abort() {
        stopRequested = true
        currentTask?.cancel()
        isPaused = false
    }

    func clearFinished() {
        jobs.removeAll { if case .waiting = $0.status { return false }; return $0.status != .running && $0.status != .paused }
    }
}
