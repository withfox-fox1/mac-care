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


// --- Cleanup ---
let cdir = mk("cleanup", dir: true)
let caches = cdir.appendingPathComponent("Caches")
for n in ["com.apple.foo", "com.run.app", "pip", "Homebrew", "other.app", "MacCareTests"] { _ = mk("cleanup/Caches/\(n)/f.bin") }
let uc = CleanupScanner.userCacheItems(root: caches, excludedNames: ["pip", "Homebrew", "MacCareTests"], runningIDs: ["com.run.app"])
check(uc.map(\.lastPathComponent) == ["other.app"], "キャッシュ除外: com.apple/実行中/pip/Homebrew")
let sz = CleanupScanner.size(of: caches.appendingPathComponent("other.app"))
check(sz.bytes > 0 && sz.skipped == 0, "dirSize が正の値")

// node_modules 判定
let projs = mk("proj", dir: true)
let now = Date()
func makeProject(_ name: String, ageDays: Int) {
    _ = mk("proj/\(name)/node_modules/x/index.js")
    _ = mk("proj/\(name)/package.json")
    _ = mk("proj/\(name)/src/a.js")
    let old = now.addingTimeInterval(-Double(ageDays) * 86400)
    for rel in ["package.json", "src"] {
        try! fm.setAttributes([.modificationDate: old], ofItemAtPath: projs.appendingPathComponent("\(name)/\(rel)").path)
    }
}
makeProject("old", ageDays: 200)
makeProject("fresh", ageDays: 5)
_ = mk("proj/.hidden/node_modules/y.js")   // 隠しディレクトリは対象外
_ = mk("proj/old/node_modules/x/node_modules/z.js")  // 入れ子は降りない
let nm = CleanupScanner.staleNodeModules(roots: [projs], staleDays: 90, now: now, library: work.appendingPathComponent("zzz"))
check(nm.map { $0.path.replacingOccurrences(of: projs.resolvingSymlinksInPath().path, with: "").replacingOccurrences(of: projs.path, with: "") } == ["/old/node_modules"], "古い node_modules のみ検出")
let deep = mk("proj/d1/d2/d3/d4/d5/d6/node_modules/q.js")
try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-999 * 86400)], ofItemAtPath: deep.deletingLastPathComponent().deletingLastPathComponent().path)
check(!CleanupScanner.staleNodeModules(roots: [projs], staleDays: 90, now: now).contains { $0.path.contains("d6") }, "maxDepth 超は探索しない")

// 分類の実行（SafeTrash 経由で root 内のみ）
let cat = CleanupScanner.makeCategory(id: "t", name: "t", summary: "", effect: "", roots: [caches],
                                      urls: CleanupScanner.children(of: caches) ?? [])
let victim = cat.items.first { $0.name == "other.app" }!
do { try SafeTrash.trash(victim.url, allowedRoots: cat.roots); check(!fm.fileExists(atPath: victim.url.path), "分類ルート内の項目がゴミ箱へ") }
catch { check(false, "分類ルート内の項目がゴミ箱へ: \(error)") }
expectThrows("分類ルート外の項目は拒否") { try SafeTrash.trash(projs.appendingPathComponent("fresh"), allowedRoots: cat.roots) }

// --- LargeFiles ---
let lf = mk("lf", dir: true)
func big(_ rel: String, _ mb: Int) {
    let u = lf.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: u.path, contents: Data(count: mb * 1_000_000))
}
big("big.mov", 3); big("small.txt", 0); big(".hidden/h.bin", 3); big("node_modules/n.bin", 3)
big("Pkg.app/Contents/p.bin", 3); big("Library/l.bin", 3); big("sub/b2.dat", 4)
let found = LargeFileScanner.scan(roots: [lf], thresholdBytes: 2_000_000, library: lf.appendingPathComponent("Library"))
check(found.map(\.name) == ["b2.dat", "big.mov"], "大容量: 閾値/隠し/node_modules/パッケージ/Library 除外とサイズ降順")
check(found.first { $0.name == "big.mov" }?.isVideo == true && found.first { $0.name == "b2.dat" }?.isVideo == false, "大容量: 動画判定")

// --- Video: 純粋ロジック ---
check(VideoCompressor.shouldSkip(MediaInfo(duration: 1, videoCodec: "hevc", hasAudio: true)), "HEVC はスキップ")
check(!VideoCompressor.shouldSkip(MediaInfo(duration: 1, videoCodec: "h264", hasAudio: true)), "H.264 は変換対象")
let vd = mk("vname", dir: true)
check(VideoCompressor.outputURL(for: vd.appendingPathComponent("a.mov")).lastPathComponent == "a.mp4", "出力名: 衝突なし")
_ = mk("vname/a.mp4")
check(VideoCompressor.outputURL(for: vd.appendingPathComponent("a.mov")).lastPathComponent == "a (圧縮).mp4", "出力名: a.mp4 既存なら (圧縮)")
check(VideoCompressor.outputURL(for: vd.appendingPathComponent("a.mp4")).lastPathComponent == "a (圧縮).mp4", "出力名: 入力が .mp4 でも (圧縮)")
_ = mk("vname/a (圧縮).mp4")
check(VideoCompressor.outputURL(for: vd.appendingPathComponent("a.mp4")).lastPathComponent == "a (圧縮 2).mp4", "出力名: (圧縮) も既存なら連番")
let mi = MediaInfo(duration: 10, videoCodec: "hevc", hasAudio: true)
check(VideoCompressor.verify(input: mi, inputSize: 100, output: mi, outputSize: 50) == nil, "検証: 正常")
check(VideoCompressor.verify(input: mi, inputSize: 100, output: mi, outputSize: 100) != nil, "検証: サイズ非縮小は失敗")
check(VideoCompressor.verify(input: mi, inputSize: 100, output: MediaInfo(duration: 11.5, videoCodec: "hevc", hasAudio: true), outputSize: 50) != nil, "検証: 長さ差>1秒は失敗")
check(VideoCompressor.verify(input: mi, inputSize: 100, output: MediaInfo(duration: 10.5, videoCodec: "hevc", hasAudio: true), outputSize: 50) == nil, "検証: 長さ差0.5秒は許容")
check(VideoCompressor.verify(input: mi, inputSize: 100, output: MediaInfo(duration: 10, videoCodec: "hevc", hasAudio: false), outputSize: 50) != nil, "検証: 音声欠落は失敗")
check(VideoCompressor.verify(input: mi, inputSize: 100, output: MediaInfo(duration: 10, videoCodec: nil, hasAudio: true), outputSize: 50) != nil, "検証: 映像なしは失敗")

// --- Video: E2E（ffmpeg が無ければ SKIP） ---
func runVideoTests() async {
    guard let ffmpeg = Tools.path("ffmpeg"), let ffprobe = Tools.path("ffprobe") else { print("SKIP 動画E2E (ffmpeg なし)"); return }
    func gen(_ rel: String, codec: String = "libx264") async -> URL {
        let u = work.appendingPathComponent(rel)
        try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try? await Shell.run(ffmpeg, ["-hide_banner", "-y", "-f", "lavfi", "-i", "testsrc=duration=3:size=640x360:rate=30",
                                              "-f", "lavfi", "-i", "sine=duration=3", "-c:v", codec, "-b:v", "4M",
                                              "-pix_fmt", "yuv420p", "-c:a", "aac", u.path])
        if r?.exitCode != 0 { print("生成失敗: \(r?.stderr ?? "")") }
        return u
    }
    // 成功ケース
    let src = await gen("v1/in.mov")
    let cdate = Date(timeIntervalSince1970: 1_500_000_000)
    try? fm.setAttributes([.creationDate: cdate, .modificationDate: cdate], ofItemAtPath: src.path)
    let oc = await VideoCompressor.compress(input: src, preset: .standard, ffmpeg: ffmpeg, ffprobe: ffprobe)
    let outURL = src.deletingLastPathComponent().appendingPathComponent("in.mp4")
    if case .done(let saved, let o) = oc {
        check(saved > 0 && o == outURL && fm.fileExists(atPath: outURL.path), "E2E: 圧縮成功で出力が存在")
        let info = try? await VideoCompressor.probe(outURL, ffprobe: ffprobe)
        check(info?.videoCodec == "hevc" && info?.hasAudio == true, "E2E: 出力は HEVC + 音声あり")
        check(!fm.fileExists(atPath: src.path), "E2E: 元ファイルが元の場所から消える")
        let a = try? fm.attributesOfItem(atPath: outURL.path)
        check((a?[.modificationDate] as? Date) == cdate, "E2E: 更新日が引き継がれる")
        check(History.readAll().contains { $0.kind == .compress && $0.bytes == saved }, "E2E: 履歴に compress が残る")
        // HEVC 済みはスキップ
        let again = await VideoCompressor.compress(input: outURL, preset: .standard, ffmpeg: ffmpeg, ffprobe: ffprobe)
        check(again == .skipped("HEVC 変換済み") && fm.fileExists(atPath: outURL.path), "E2E: HEVC 済みはスキップ")
    } else { check(false, "E2E: 圧縮成功 (\(oc))") }
    // 検証失敗ケース（verifier 注入）
    let src2 = await gen("v2/in2.mov")
    let oc2 = await VideoCompressor.compress(input: src2, preset: .high, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                             verifier: { _, _, _, _ in "テスト用の強制失敗" })
    var failedOK = false
    if case .failed = oc2 { failedOK = true }
    check(failedOK, "E2E: 検証失敗は failed")
    check(fm.fileExists(atPath: src2.path), "E2E: 検証失敗で元ファイルが残る")
    check(!fm.fileExists(atPath: src2.deletingLastPathComponent().appendingPathComponent("in2.mp4").path), "E2E: 検証失敗で出力が消える")
    // 中止ケース
    let src3 = await gen("v3/in3.mov")
    let t = Task { await VideoCompressor.compress(input: src3, preset: .standard, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                                  verifier: { _, _, _, _ in nil }) }
    t.cancel()
    let oc3 = await t.value
    check(oc3 == .cancelled && fm.fileExists(atPath: src3.path)
          && !fm.fileExists(atPath: src3.deletingLastPathComponent().appendingPathComponent("in3.mp4").path), "E2E: 中止で元が残り出力なし")
}
let sem2 = DispatchSemaphore(value: 0)
Task { await runVideoTests(); sem2.signal() }
sem2.wait()

try? fm.removeItem(at: work)
print("\n\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
