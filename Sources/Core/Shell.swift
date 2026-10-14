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
        if started && process.isRunning { process.terminate() }
    }
}

enum Shell {
    /// 絶対パスの実行ファイルを引数配列で実行する（シェルは経由しない）。
    /// Task がキャンセルされるとプロセスを terminate する。
    /// onLine を渡すと stdout を1行ずつ通知する（バックグラウンドスレッドから呼ばれる）。
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        onLine: (@Sendable (String) -> Void)? = nil
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
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    var outData = Data()
                    var pending = Data()
                    let nl = UInt8(ascii: "\n")
                    let handle = outPipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        outData.append(chunk)
                        guard let onLine else { continue }
                        pending.append(chunk)
                        while let idx = pending.firstIndex(of: nl) {
                            let line = String(decoding: pending[pending.startIndex..<idx], as: UTF8.self)
                            pending.removeSubrange(pending.startIndex...idx)
                            onLine(line)
                        }
                    }
                    if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                    group.wait()
                    p.waitUntilExit()
                    cont.resume(returning: ShellResult(
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self),
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
