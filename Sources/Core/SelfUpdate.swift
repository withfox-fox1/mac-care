import Foundation
import Observation
import AppKit

/// ビルド時に Info.plist へ埋め込まれた情報
enum BuildInfo {
    static func string(_ key: String) -> String? {
        let v = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (v?.isEmpty == false) ? v : nil
    }
    /// ビルドに使ったソースの git チェックアウト
    static var sourceDir: String? { string("MCSourceDir") }
    static var commit: String? { string("MCBuildCommit") }
    static var version: String { string("CFBundleShortVersionString") ?? "?" }
    /// 表示用: 0.1.0（abc1234）
    static var display: String { version + (commit.map { "（\($0)）" } ?? "") }
}

struct UpdateCommit: Equatable, Codable {
    var hash: String
    var subject: String
}

enum UpdateState: Equatable {
    case unknown
    case upToDate
    case available(count: Int, commits: [UpdateCommit])
    /// 更新できない状態（ローカル変更・分岐など）。理由を表示する
    case blocked(String)
    /// 確認できない（ソースなし・オフラインなど）。理由を表示する
    case unavailable(String)
}

/// git から得た事実（判定を純粋関数にするための入力）
struct RepoFacts: Equatable {
    var isRepo = true
    var dirty = false
    var branch: String? = "main"
    var behind = 0
    var ahead = 0
    var commits: [UpdateCommit] = []
}

enum SelfUpdate {
    static let git = "/usr/bin/git"
    static let maxCommits = 10
    static var logURL: URL { Storage.baseDir.appendingPathComponent("update.log") }
    static var pendingURL: URL { Storage.baseDir.appendingPathComponent("update-pending.json") }
    static var stateURL: URL { Storage.baseDir.appendingPathComponent("update-state.json") }
    static let exitMarker = "MACCARE_UPDATE_EXIT="

    // MARK: 解析・判定（純粋関数）

    /// `git rev-list --count` の出力
    static func parseCount(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `git log --oneline` の出力（"hash subject"）。最大 maxCommits 件
    static func parseLog(_ s: String, limit: Int = maxCommits) -> [UpdateCommit] {
        var out: [UpdateCommit] = []
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let sp = t.firstIndex(of: " ") {
                out.append(UpdateCommit(hash: String(t[..<sp]), subject: String(t[t.index(after: sp)...])))
            } else { out.append(UpdateCommit(hash: t, subject: "")) }
            if out.count >= limit { break }
        }
        return out
    }

    static func decide(_ f: RepoFacts) -> UpdateState {
        guard f.isRepo else { return .unavailable("ソースフォルダが git リポジトリではありません。") }
        if f.behind == 0 {
            if f.ahead > 0 { return .blocked("手元に origin/main へ未反映のコミットが \(f.ahead) 件あります。取り込む更新はありません。") }
            return .upToDate
        }
        if f.branch != "main" { return .blocked("ソースの作業ブランチが main ではありません（\(f.branch ?? "不明")）。自動更新は行いません。") }
        if f.dirty { return .blocked("ソースフォルダに未コミットの変更があるため、自動更新は行いません。変更を退避してから実行してください。") }
        if f.ahead > 0 { return .blocked("手元のコミットが origin/main と分岐しています（手元 +\(f.ahead) / 更新 +\(f.behind)）。自動更新は行いません。") }
        return .available(count: f.behind, commits: f.commits)
    }

    /// 1 日 1 回の自動確認が必要か
    static func isCheckDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let d = now.timeIntervalSince(last)
        return d < 0 || d >= 86400
    }

    // MARK: 再起動後の結果判定

    struct Pending: Codable, Equatable {
        var fromCommit: String?
        var startedAt: Date
    }
    enum Outcome: Equatable {
        case none                 // 保留なし／進行中
        case success(String?)     // 新しいコミット
        case failed(String)       // 理由
    }
    /// 保留中の更新と現在のコミット・ログから結果を決める
    static func evaluate(pending: Pending, currentCommit: String?, log: String, now: Date) -> Outcome {
        if let c = currentCommit, c != pending.fromCommit { return .success(c) }
        if let r = log.range(of: exitMarker, options: .backwards) {
            let code = log[r.upperBound...].prefix { $0.isNumber || $0 == "-" }
            if let n = Int(code), n != 0 { return .failed("インストール処理が失敗しました（終了コード \(n)）。") }
            return .none
        }
        if now.timeIntervalSince(pending.startedAt) > 15 * 60 { return .failed("更新処理が完了しませんでした。") }
        return .none
    }

    // MARK: git 実行

    private static func run(_ dir: String, _ args: [String]) async throws -> ShellResult {
        // 認証を待って固まらないよう GIT_TERMINAL_PROMPT=0 を付ける
        try await Shell.run("/usr/bin/env", ["GIT_TERMINAL_PROMPT=0", git, "-C", dir] + args)
    }

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
            defer { g.cancelAll() }
            guard let first = try await g.next(), let v = first else { throw ShellError.launchFailed("タイムアウト") }
            return v
        }
    }

    /// 取得（fetch）して origin/main と比較する。読み取り専用（作業ツリーは変更しない）
    static func check(dir: String?) async -> UpdateState {
        guard let dir, !dir.isEmpty else { return .unavailable("ソースフォルダの情報がありません。install.sh でビルドしたアプリのみ更新できます。") }
        guard FileManager.default.fileExists(atPath: dir) else { return .unavailable("ソースフォルダが見つかりません: \(dir)") }
        do {
            guard let xs = try? await Shell.run("/usr/bin/xcode-select", ["-p"]), xs.exitCode == 0 else {
                return .unavailable("Xcode Command Line Tools（git）が見つかりません。xcode-select --install を実行してください。")
            }
            let inside = try await run(dir, ["rev-parse", "--is-inside-work-tree"])
            guard inside.exitCode == 0, inside.stdout.contains("true") else {
                return .unavailable("ソースフォルダが git リポジトリではありません: \(dir)")
            }
            let fetch = try await withTimeout(60) { try await run(dir, ["fetch", "--quiet", "origin"]) }
            guard fetch.exitCode == 0 else {
                let why = fetch.stderr.split(separator: "\n").first.map(String.init) ?? "終了コード \(fetch.exitCode)"
                return .unavailable("origin に接続できません（オフラインの可能性があります）: \(why)")
            }
            let behindR = try await run(dir, ["rev-list", "--count", "HEAD..origin/main"])
            let aheadR = try await run(dir, ["rev-list", "--count", "origin/main..HEAD"])
            guard behindR.exitCode == 0, aheadR.exitCode == 0,
                  let behind = parseCount(behindR.stdout), let ahead = parseCount(aheadR.stdout) else {
                return .unavailable("origin/main を参照できません: \(behindR.stderr.split(separator: "\n").first.map(String.init) ?? "")")
            }
            var facts = RepoFacts(isRepo: true, dirty: false, branch: nil, behind: behind, ahead: ahead, commits: [])
            let st = try await run(dir, ["status", "--porcelain"])
            facts.dirty = !st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let br = try await run(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
            facts.branch = br.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if behind > 0 {
                let log = try await run(dir, ["log", "--oneline", "-n", "\(maxCommits)", "HEAD..origin/main"])
                facts.commits = parseLog(log.stdout)
            }
            return decide(facts)
        } catch is CancellationError {
            return .unknown
        } catch {
            return .unavailable("確認に失敗しました: \(error)")
        }
    }

    // MARK: 更新の実行（切り離して起動）

    /// 実行するシェルスクリプト。ソースのパスとログのパスは引数（$1, $2）で渡し、文字列に埋め込まない。
    static let script = """
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin; export PATH
    ( ( echo "== MacCare update $(date)"; cd "$1" && git pull --ff-only && ./install.sh --app-only; echo "\(exitMarker)$?" ) >> "$2" 2>&1 & )
    """

    /// `git pull --ff-only` → `./install.sh --app-only` を MacCare から切り離して起動する。
    /// install が MacCare を終了・再起動しても処理が続くよう、孫プロセスを launchd 配下へ移す。
    /// （Shell.run / ChildRegistry は使わない: アプリ終了時の子プロセス掃除の対象外にするため）
    static func startUpdate(dir: String, log: URL = logURL, pending: URL = pendingURL, fromCommit: String? = BuildInfo.commit) throws {
        try Storage.ensureDir()
        try Data().write(to: log)
        let p = Pending(fromCommit: fromCommit, startedAt: Date())
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(p).write(to: pending, options: .atomic)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "sh", dir, log.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    static func loadPending(_ url: URL = pendingURL) -> Pending? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Pending.self, from: d)
    }
}

/// 最後の確認結果（再起動後も表示するため保存する）
struct UpdateSnapshot: Codable, Equatable {
    var lastCheck: Date?
    var behind: Int = 0
    var commits: [UpdateCommit] = []
    var message: String? = nil

    static func load(_ url: URL = SelfUpdate.stateURL) -> UpdateSnapshot {
        guard let d = try? Data(contentsOf: url) else { return UpdateSnapshot() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(UpdateSnapshot.self, from: d)) ?? UpdateSnapshot()
    }
    func save(_ url: URL = SelfUpdate.stateURL) {
        try? Storage.ensureDir()
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(self) { try? d.write(to: url, options: .atomic) }
    }
}

@MainActor @Observable
final class UpdateModel {
    var state: UpdateState = .unknown
    var checking = false
    var lastCheck: Date? = nil
    var started = false
    /// 更新結果のお知らせ（再起動後に一度だけ表示）。isError なら失敗
    var notice: (text: String, isError: Bool)? = nil
    private var loop: Task<Void, Never>?

    init() {
        let snap = UpdateSnapshot.load()
        lastCheck = snap.lastCheck
        if snap.behind > 0 { state = .available(count: snap.behind, commits: snap.commits) }
        else if snap.lastCheck != nil { state = .upToDate }
    }

    var availableCount: Int { if case .available(let n, _) = state { return n } else { return 0 } }

    func check() async {
        guard !checking else { return }
        checking = true
        let s = await SelfUpdate.check(dir: BuildInfo.sourceDir)
        checking = false
        guard s != .unknown else { return }
        state = s
        lastCheck = Date()
        var snap = UpdateSnapshot(lastCheck: lastCheck)
        switch s {
        case .available(let n, let c): snap.behind = n; snap.commits = c
        case .blocked(let m), .unavailable(let m): snap.message = m
        default: break
        }
        // 更新ありのまま確認できなくなった場合は、直前の「更新あり」を保持しない（誤案内を避ける）
        snap.save()
    }

    /// 1 日 1 回のバックグラウンド確認（自動インストールはしない）
    func startDailyCheck() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
            while !Task.isCancelled, let me = self {
                if SelfUpdate.isCheckDue(last: me.lastCheck, now: Date()) { await me.check() }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    /// 起動時: 前回の更新処理の結果を反映する
    func resolvePending() {
        guard let p = SelfUpdate.loadPending() else { return }
        let log = (try? String(contentsOf: SelfUpdate.logURL, encoding: .utf8)) ?? ""
        switch SelfUpdate.evaluate(pending: p, currentCommit: BuildInfo.commit, log: log, now: Date()) {
        case .success:
            notice = ("バージョン \(BuildInfo.display) に更新しました", false)
            try? FileManager.default.removeItem(at: SelfUpdate.pendingURL)
            UpdateSnapshot().save(); state = .upToDate
        case .failed(let why):
            notice = ("更新に失敗しました。\(why) ログ: \(SelfUpdate.logURL.path)", true)
            try? FileManager.default.removeItem(at: SelfUpdate.pendingURL)
        case .none: break
        }
    }

    /// 確認ダイアログ（非破壊）のあと、切り離して更新を開始する
    func confirmAndStart() {
        guard let dir = BuildInfo.sourceDir, case .available(let n, _) = state else { return }
        let a = NSAlert()
        a.messageText = "MacCare をアップデートしますか？"
        a.informativeText = "\(n) 件の更新を取り込み、アプリを再ビルドして再起動します（数分かかります）。ログ: \(SelfUpdate.logURL.path)"
        a.addButton(withTitle: "アップデートする")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SelfUpdate.startUpdate(dir: dir)
            notice = ("アップデートを開始しました。完了すると MacCare が自動で再起動します。", false)
        } catch {
            notice = ("アップデートを開始できませんでした: \(error.localizedDescription)", true)
        }
    }
}
