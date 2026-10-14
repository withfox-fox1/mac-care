import Foundation

var failures = 0
var count = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String) {
    count += 1
    if cond() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func expectThrows(_ name: String, _ expected: SafeTrashError? = nil, _ body: () throws -> Void) {
    count += 1
    do { try body(); failures += 1; print("FAIL \(name) (no error)") }
    catch let e as SafeTrashError {
        if expected == nil || expected == e { print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name) (got \(e))") }
    } catch { failures += 1; print("FAIL \(name) (other error \(error))") }
}

let fm = FileManager.default
let home = URL(fileURLWithPath: NSHomeDirectory())
// trashItem が一時領域で使えない場合に備え、ホーム配下に作業ディレクトリを作る
let work = home.appendingPathComponent("Library/Caches/MacCareTests/\(UUID().uuidString)")
let storageDir = work.appendingPathComponent("storage")
Storage.baseDir = storageDir

func mk(_ rel: String, dir: Bool = false) -> URL {
    let u = work.appendingPathComponent(rel)
    if dir { try! fm.createDirectory(at: u, withIntermediateDirectories: true) }
    else {
        try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "x".write(to: u, atomically: true, encoding: .utf8)
    }
    return u
}

// --- SafeTrash ---
let root = mk("a", dir: true)
let f = mk("a/inside-\(UUID().uuidString).txt")
do {
    try SafeTrash.trash(f, allowedRoots: [root])
    check(!fm.fileExists(atPath: f.path), "root 内のファイルがゴミ箱へ移動される")
} catch { check(false, "root 内のファイルがゴミ箱へ移動される: \(error)") }
check(History.readAll().contains { $0.kind == .trash && $0.result == "ok" }, "削除が履歴に記録される")

let outside = mk("outside.txt")
expectThrows("root 外は拒否", .outsideAllowedRoots(outside.path)) { try SafeTrash.trash(outside, allowedRoots: [root]) }
check(fm.fileExists(atPath: outside.path), "root 外のファイルは残る")

let sib = mk("ab/file.txt")   // root=a に対し ab は兄弟（文字列前方一致の罠）
expectThrows("兄弟プレフィックス(a vs ab)は拒否") { try SafeTrash.trash(sib, allowedRoots: [root]) }
check(fm.fileExists(atPath: sib.path), "兄弟プレフィックスのファイルは残る")

expectThrows("root 自体は拒否", .isAllowedRoot(root.path)) { try SafeTrash.trash(root, allowedRoots: [root]) }
check(fm.fileExists(atPath: root.path), "root は残る")

let trav = root.appendingPathComponent("../outside.txt")
expectThrows("..トラバーサルは拒否") { try SafeTrash.trash(trav, allowedRoots: [root]) }
check(fm.fileExists(atPath: outside.path), "トラバーサル先は残る")

let link = root.appendingPathComponent("escape-link")
try! fm.createSymbolicLink(at: link, withDestinationURL: outside)
expectThrows("root 外を指すシンボリックリンクは拒否") { try SafeTrash.trash(link, allowedRoots: [root]) }
check(fm.fileExists(atPath: outside.path), "リンク先の実体は残る")

let dirLink = root.appendingPathComponent("dir-link")
try! fm.createSymbolicLink(at: dirLink, withDestinationURL: work.appendingPathComponent("ab"))
expectThrows("リンク経由の子要素(root外実体)は拒否") {
    try SafeTrash.trash(dirLink.appendingPathComponent("file.txt"), allowedRoots: [root])
}
check(fm.fileExists(atPath: sib.path), "リンク経由の実体は残る")

let missing = root.appendingPathComponent("nope.txt")
expectThrows("存在しないパスは notFound") { try SafeTrash.trash(missing, allowedRoots: [root]) }

// 拒否リスト（許可ルートを "/" にしても拒否される。いずれも実削除は起きない）
let slash = [URL(fileURLWithPath: "/")]
for p in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private",
          NSHomeDirectory(), NSHomeDirectory() + "/Library",
          NSHomeDirectory() + "/Library/Application Support/Claude/vm_bundles",
          NSHomeDirectory() + "/Library/Application Support/Claude/vm_bundles/x/y",
          NSHomeDirectory() + "/voicevox_engine",
          NSHomeDirectory() + "/voicevox_engine/models/a.bin",
          NSHomeDirectory() + "/Library/Application Support/Claude"] {
    expectThrows("拒否リスト: \(p)") { try SafeTrash.trash(URL(fileURLWithPath: p), allowedRoots: slash) }
}
expectThrows("許可ルート '/' 自体は拒否") { try SafeTrash.trash(URL(fileURLWithPath: "/"), allowedRoots: slash) }
check(SafeTrash.isInside(URL(fileURLWithPath: "/a/b/c"), of: URL(fileURLWithPath: "/a/b")), "isInside: 配下")
check(!SafeTrash.isInside(URL(fileURLWithPath: "/a/bc"), of: URL(fileURLWithPath: "/a/b")), "isInside: /a/bc は /a/b の外")

// --- Storage ---
var s = Settings()
check(s.largeFileThresholdMB == 500 && s.nodeModulesStaleDays == 90 && s.scanIntervalDays == 7
      && s.scheduledScanEnabled && s.lastScheduledRun == nil && s.largeFileRoots == [NSHomeDirectory()], "Settings 既定値")
s.largeFileThresholdMB = 1234
s.lastScheduledRun = Date(timeIntervalSince1970: 1_700_000_000)
s.largeFileRoots = ["/tmp/x"]
try! s.save()
check(Settings.load() == s, "Settings の保存→読込が一致")
try! "{\"scanIntervalDays\": 3}".write(to: Storage.settingsURL, atomically: true, encoding: .utf8)
check(Settings.load().scanIntervalDays == 3 && Settings.load().largeFileThresholdMB == 500, "Settings 欠損キーは既定値で補う")
try! "broken".write(to: Storage.settingsURL, atomically: true, encoding: .utf8)
check(Settings.load() == Settings(), "Settings 破損時は既定値")

// --- History ---
try? fm.removeItem(at: Storage.historyURL)
check(History.readAll().isEmpty, "History 初期は空")
let e1 = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .cleanup, target: "/x", bytes: 10, result: "ok", detail: "d1")
let e2 = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_100), kind: .scan, target: "/y", bytes: 0, result: "clean", detail: "")
try! History.append(e1); try! History.append(e2)
check(History.readAll() == [e1, e2], "History 追記→読込が順序通り")
let lines = try! String(contentsOf: Storage.historyURL, encoding: .utf8).split(separator: "\n")
check(lines.count == 2, "History は1エントリ1行")
let fh = try! FileHandle(forWritingTo: Storage.historyURL); try! fh.seekToEnd(); try! fh.write(contentsOf: Data("garbage\n".utf8)); try! fh.close()
check(History.readAll().count == 2, "History 破損行は読み飛ばす")

// --- Shell ---
final class LineBox: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var lines: [String] { l.lock(); defer { l.unlock() }; return v }
}
func runShell() async {
    let r = try? await Shell.run("/bin/echo", ["hello"])
    check(r?.stdout == "hello\n" && r?.exitCode == 0, "Shell: echo の出力と終了コード")
    let r2 = try? await Shell.run("/usr/bin/false")
    check(r2?.exitCode == 1, "Shell: 非0終了コード")
    let box = LineBox()
    _ = try? await Shell.run("/bin/sh", ["-c", "echo a; echo b"], onLine: { box.add($0) })
    check(box.lines == ["a", "b"], "Shell: 行ストリーミング")
    let t = Task { try await Shell.run("/bin/sleep", ["30"]) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let start = Date()
    t.cancel()
    _ = await t.result
    check(Date().timeIntervalSince(start) < 5, "Shell: キャンセルでプロセス終了")
}
let sem = DispatchSemaphore(value: 0)
Task { await runShell(); sem.signal() }
sem.wait()

try? fm.removeItem(at: work)
print("\n\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
