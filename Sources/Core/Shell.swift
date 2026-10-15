import Foundation

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellError: Error {
    case launchFailed(String)
}

/// プロセスの起動とキャンセルを排他制御する
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        started = true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if started && process.isRunning {
            process.terminate()
            // SIGSTOP 中のプロセスは SIGTERM を処理できないため再開させる
            kill(process.processIdentifier, SIGCONT)
        }
    }
}

/// 起動中の子プロセス（アプリ終了時に停止させる）
enum ChildRegistry {
    private static let lock = NSLock()
    private static var pids = Set<Int32>()
    static func add(_ p: Int32) { lock.lock(); pids.insert(p); lock.unlock() }
    static func remove(_ p: Int32) { lock.lock(); pids.remove(p); lock.unlock() }
    /// 一時停止中のものも含め、すべての子プロセスを終了させる
    static func terminateAll() {
        lock.lock(); let all = pids; lock.unlock()
        for p in all { kill(p, SIGCONT); kill(p, SIGTERM) }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum Shell {
    /// 絶対パスの実行ファイルを引数配列で実行する（シェルは経由しない）。
    /// Task がキャンセルされるとプロセスを terminate する。
    /// onLine を渡すと stdout を1行ずつ通知する（バックグラウンドスレッドから呼ばれる）。
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        onLine: (@Sendable (String) -> Void)? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> ShellResult {
        try Task.checkCancellation()
        let box = ProcessBox()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        let result: ShellResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global().async {
                    do { try box.start() } catch let e as CancellationError {
                        cont.resume(throwing: e); return
                    } catch {
                        cont.resume(throwing: ShellError.launchFailed("\(executable): \(error.localizedDescription)"))
                        return
                    }
                    onStart?(p.processIdentifier)
                    ChildRegistry.add(p.processIdentifier)
                    let outC = Collector(), errC = Collector()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        while true {
                            let c = errPipe.fileHandleForReading.availableData
                            if c.isEmpty { break }
                            errC.append(c)
                        }
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        var pending = Data()
                        let nl = UInt8(ascii: "\n")
                        let handle = outPipe.fileHandleForReading
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            outC.append(chunk)
                            guard let onLine else { continue }
                            pending.append(chunk)
                            while let idx = pending.firstIndex(of: nl) {
                                let line = String(decoding: pending[pending.startIndex..<idx], as: UTF8.self)
                                pending.removeSubrange(pending.startIndex...idx)
                                onLine(line)
                            }
                        }
                        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                        group.leave()
                    }
                    p.waitUntilExit()
                    ChildRegistry.remove(p.processIdentifier)
                    // 孫プロセスがパイプを保持していても固まらないよう、終了後の読み取り待ちには上限を設ける
                    _ = group.wait(timeout: .now() + 2)
                    cont.resume(returning: ShellResult(
                        stdout: String(decoding: outC.snapshot, as: UTF8.self),
                        stderr: String(decoding: errC.snapshot, as: UTF8.self),
                        exitCode: p.terminationStatus))
                }
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
