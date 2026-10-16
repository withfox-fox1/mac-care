import Foundation
import AppKit

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


func await_sync<T>(_ body: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: T!
    Task { result = await body(); sem.signal() }
    sem.wait()
    return result
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
check(s.largeFileThresholdMB == 500 && s.nodeModulesStaleDays == 90 && s.fullScanHour == 0 && s.fullScanMinute == 0 && s.quickScan
      && s.scheduledScanEnabled && s.lastScheduledRun == nil && s.largeFileRoots == [NSHomeDirectory()], "Settings 既定値")
s.largeFileThresholdMB = 1234
s.lastScheduledRun = Date(timeIntervalSince1970: 1_700_000_000)
s.largeFileRoots = ["/tmp/x"]
try! s.save()
check(Settings.load() == s, "Settings の保存→読込が一致")
try! "{\"fullScanHour\": 3}".write(to: Storage.settingsURL, atomically: true, encoding: .utf8)
check(Settings.load().fullScanHour == 3 && Settings.load().largeFileThresholdMB == 500, "Settings 欠損キーは既定値で補う")
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
var run1 = CleanupScanner.RunningInfo(); run1.ids = ["com.run.app"]
let uc = CleanupScanner.userCacheItems(root: caches, otherCategoryNames: ["pip", "Homebrew"], running: run1)
check(uc.keep.map(\.lastPathComponent) == ["other.app"], "キャッシュ除外: com.apple/実行中/pip/Homebrew/never-clean")
check(Set(uc.excluded.map(\.name)) == ["com.apple.foo", "com.run.app", "pip", "Homebrew", "MacCareTests"] && uc.excluded.allSatisfy { !$0.reason.isEmpty }, "キャッシュ除外: 除外項目と理由が返る")
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
        let h264 = await gen("v1/codec_h264.mov")
        let isH = await VideoCodec.isHEVC(outURL), isA = await VideoCodec.isHEVC(h264)
        let isMissing = await VideoCodec.isHEVC(work.appendingPathComponent("none.mp4"))
        check(isH && !isA && !isMissing, "E2E: HEVC 判定（圧縮済みは true、H.264・読めないものは false）")
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


// --- Security: 純粋ロジック ---
check(YaraEngine.parse("RuleA /tmp/a b/c.bin\nRuleB /tmp/d\nnoise line\n") ==
      [Detection(engine: .yara, signature: "RuleA", path: "/tmp/a b/c.bin"), Detection(engine: .yara, signature: "RuleB", path: "/tmp/d")], "YARA 出力の解析(空白を含むパス)")
check(ClamEngine.parse("/tmp/x/eicar.com: Win.Test.EICAR_HDB-1 FOUND\n/tmp/y: z: a FOUND\nWARNING: foo\n") ==
      [Detection(engine: .clamav, signature: "Win.Test.EICAR_HDB-1", path: "/tmp/x/eicar.com"),
       Detection(engine: .clamav, signature: "a", path: "/tmp/y: z")], "ClamAV 出力の解析")
let ig = mk("ig/f.bin")
var ignoreList: [IgnoredDetection] = []
IgnoreList.add(path: ig.path, to: &ignoreList)
let det = Detection(engine: .yara, signature: "R", path: ig.path)
check(IgnoreList.filter([det], list: ignoreList).visible.isEmpty, "無視: 同一ハッシュは非表示")
try! "changed content".write(to: ig, atomically: true, encoding: .utf8)
check(IgnoreList.filter([det], list: ignoreList).visible.count == 1, "無視: ハッシュが変わると再表示")
check(IgnoreList.filter([Detection(engine: .yara, signature: "R", path: ig.path + ".none")], list: ignoreList).visible.count == 1, "無視: 別パスは表示")

// --- ログイン項目 ---
let la = mk("la", dir: true)
func writePlist(_ name: String, _ d: [String: Any]) {
    (d as NSDictionary).write(to: la.appendingPathComponent(name), atomically: true)
}
writePlist("a.plist", ["Label": "com.test.a", "ProgramArguments": ["/bin/ls", "-l"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]])
writePlist("b.plist", ["Label": "com.test.b", "Program": "/usr/bin/true", "ProgramArguments": ["/bin/other"]])
let pa = LoginItems.parse(plist: la.appendingPathComponent("a.plist"), domain: .user)
check(pa?.label == "com.test.a" && pa?.program == "/bin/ls" && pa?.runAtLoad == true && pa?.keepAlive == true, "plist 解析: ProgramArguments[0]/RunAtLoad/KeepAlive(dict)")
check(LoginItems.parse(plist: la.appendingPathComponent("b.plist"), domain: .system)?.program == "/usr/bin/true", "plist 解析: Program 優先")
check(LoginItems.scan(dirs: [(la, .user)]).count == 2, "plist 一覧")
check(LoginItems.parseSigner("Authority=Developer ID Application: X (T1)\nAuthority=Apple\nTeamIdentifier=T1\n") == "Developer ID Application: X (T1)", "署名者の解析")
check(await_sync { await LoginItems.signer(of: "/nonexistent/prog") } == "実行ファイルなし", "署名者: 実行ファイルなし")
check(await_sync { await LoginItems.signer(of: "/bin/ls") } != "未署名", "署名者: /bin/ls は署名あり")
let d1 = LoginItems.diff(previous: [SnapshotItem(label: "a", program: "/x", sha256: "1"), SnapshotItem(label: "gone", program: "/g", sha256: "9")],
                         current: [SnapshotItem(label: "a", program: "/x", sha256: "2"), SnapshotItem(label: "n", program: "/n", sha256: "3")])
check(d1 == SnapshotDiff(new: ["n"], changed: ["a"], removed: ["gone"]), "スナップショット差分(新規/変更/削除)")
let first = await_sync { await LoginItems.fullScan(dirs: [(la, .user)]) }
check(first.diff == nil && first.items.allSatisfy { $0.change == .unchanged }, "初回スキャンは基準のみ(差分なし)")
writePlist("c.plist", ["Label": "com.test.c", "ProgramArguments": ["/bin/ls"]])
writePlist("a.plist", ["Label": "com.test.a", "ProgramArguments": ["/bin/echo"]])
let second = await_sync { await LoginItems.fullScan(dirs: [(la, .user)]) }
check(second.items.first { $0.label == "com.test.c" }?.change == .new && second.items.first { $0.label == "com.test.a" }?.change == .changed
      && second.items.first { $0.label == "com.test.b" }?.change == .unchanged, "再スキャンで 新規/変更 を検出")

// --- アプリ・関連ファイル ---
let apps = mk("Apps", dir: true)
func makeApp(_ rel: String, _ bid: String, _ name: String, mas: Bool = false) -> URL {
    let a = apps.appendingPathComponent(rel)
    try! fm.createDirectory(at: a.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    (["CFBundleIdentifier": bid, "CFBundleName": name, "CFBundleShortVersionString": "1.2"] as NSDictionary)
        .write(to: a.appendingPathComponent("Contents/Info.plist"), atomically: true)
    try! "bin".write(to: a.appendingPathComponent("Contents/bin"), atomically: true, encoding: .utf8)
    if mas { try! fm.createDirectory(at: a.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true) }
    return a
}
let fooApp = makeApp("Foo.app", "com.example.foo", "Foo", mas: true)
_ = makeApp("Group/Bar.app", "com.example.bar", "Bar")
_ = makeApp("Group/Deep/Baz.app", "com.example.baz", "Baz")   // 2階層下は対象外
let found2 = AppCatalog.appURLs(in: [apps]).map(\.lastPathComponent).sorted()
check(found2 == ["Bar.app", "Foo.app"], "アプリ列挙: 直下+1階層下フォルダ")
let fi = AppCatalog.info(for: fooApp)
check(fi?.bundleID == "com.example.foo" && fi?.name == "Foo" && fi?.version == "1.2" && fi?.isAppStore == true && fi?.isApple == false && (fi?.size ?? 0) > 0, "アプリ情報(ID/版/App Store/サイズ)")
let lib = mk("lib", dir: true)
for rel in ["Application Support/com.example.foo/data.bin", "Caches/com.example.foo.helper/c.bin", "Preferences/com.example.foo.plist",
            "Group Containers/ABCDE12345.com.example.foo/g.bin", "Application Support/Foo/n.bin", "Application Support/com.example.foobar/x.bin",
            "Caches/Other/o.bin", "Saved Application State/com.example.foo.savedState/s.bin", "Containers/com.example.foo/k.bin"] { _ = mk("lib/\(rel)") }
let rel = RelatedFinder.find(bundleID: "com.example.foo", appName: "Foo", library: lib)
func relNames(_ k: RelatedFile.Kind) -> [String] { rel.filter { $0.kind == k }.map { $0.url.lastPathComponent }.sorted() }
check(relNames(.bundleID) == ["ABCDE12345.com.example.foo", "com.example.foo", "com.example.foo", "com.example.foo.plist", "com.example.foo.savedState"] && relNames(.bundlePrefix) == ["com.example.foo.helper"], "関連: Bundle ID 完全/前方/後方一致")
check(relNames(.nameOnly) == ["Foo"], "関連: 名前のみ一致は区別される")
check(!rel.contains { $0.url.lastPathComponent == "com.example.foobar" || $0.url.lastPathComponent == "Other" }, "関連: 無関係なものは除外")
check(RelatedFinder.matchesBundleID("COM.Example.Foo.plist", "com.example.foo"), "関連: 大文字小文字を区別しない")
// アンインストール（ダミー）
let target = AppCatalog.info(for: fooApp)!
let selected = rel.filter { $0.kind == .bundleID }
do {
    _ = try AppUninstaller.uninstall(app: InstalledApp(url: target.url, name: "x", bundleID: "com.apple.finder", version: "", size: 0, lastUsed: nil, isAppStore: false), related: [], isRunning: { false }, library: lib, appRoots: [apps])
    check(false, "Apple 製アプリは拒否")
} catch { check(fm.fileExists(atPath: fooApp.path), "Apple 製アプリは拒否") }
do { _ = try AppUninstaller.uninstall(app: target, related: [], isRunning: { true }, library: lib, appRoots: [apps]); check(false, "実行中は拒否") }
catch { check(fm.fileExists(atPath: fooApp.path), "実行中のアプリは拒否") }
let ur = try? AppUninstaller.uninstall(app: target, related: selected, isRunning: { false }, library: lib, appRoots: [apps])
check(ur?.failed.isEmpty == true && !fm.fileExists(atPath: fooApp.path)
      && !fm.fileExists(atPath: lib.appendingPathComponent("Application Support/com.example.foo").path)
      && fm.fileExists(atPath: lib.appendingPathComponent("Application Support/Foo").path)
      && fm.fileExists(atPath: lib.appendingPathComponent("Application Support/com.example.foobar").path), "アンインストール: 本体+選択分のみ移動、名前のみ/無関係は残る")
// 残骸
let lib2 = mk("lib2", dir: true)
for rel in ["Application Support/com.gone.app/a", "Application Support/com.example.bar/a", "Caches/com.example.bar.helper/a", "Application Support/com.apple.thing/a",
            "Application Support/PlainName/a", "Preferences/com.gone.pref.plist", "Containers/com.run.x/a", "Caches/com.example/a", "Application Support/com.gone.app2/a"] { _ = mk("lib2/\(rel)") }
let lo = Leftovers.find(library: lib2, installedIDs: ["com.example.bar"], runningIDs: ["com.run.x"], isInstalled: { _ in false }).map(\.url.lastPathComponent).sorted()
check(lo == ["com.gone.app", "com.gone.app2", "com.gone.pref.plist"], "残骸: 未インストールのID形式のみ(インストール済/実行中/Apple/非ID形式は除外)")
check(Leftovers.looksLikeBundleID("com.foo.bar") && !Leftovers.looksLikeBundleID("com.foo") && !Leftovers.looksLikeBundleID("Google") && !Leftovers.looksLikeBundleID("a..b"), "Bundle ID 形式判定")


// --- P5: スケジューラ / スマートケア / 設定 ---
check(Storage.baseDir.path.contains("/MacCareTests/") && !Storage.baseDir.path.hasSuffix("Application Support/MacCare"), "テストは注入した保存先のみ使う(実 AppSupport を使わない)")
var sch = Settings()
sch.scheduledScanEnabled = true; sch.fullScanHour = 0; sch.fullScanMinute = 0; sch.lastScheduledRun = nil
var jcal = Calendar(identifier: .gregorian); jcal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
func jd(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { jcal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
func dec(_ now: Date, last: Date?, low: Bool = false, busy: Bool = false, _ s: Settings = sch, _ cal: Calendar = jcal) -> ScheduleDecision {
    SchedulerLogic.decide(settings: s, now: now, lastFull: last, batteryLow: low, busy: busy, calendar: cal)
}
let noon = jd(2026, 10, 15, 12, 0)
check(dec(noon, last: nil) == .run, "スケジューラ: 未実行なら実行")
check(dec(noon, last: jd(2026, 10, 15, 0, 3)) == .notDue, "スケジューラ: 今日0:03に実行済みなら実行しない(1日1回)")
check(dec(jd(2026, 10, 15, 23, 59), last: jd(2026, 10, 15, 0, 3)) == .notDue, "スケジューラ: 同じ日の23:59も実行しない")
check(dec(jd(2026, 10, 15, 0, 0), last: jd(2026, 10, 14, 0, 3)) == .run, "スケジューラ: 日付が変わった0:00ちょうどで実行")
check(dec(jd(2026, 10, 14, 23, 59), last: jd(2026, 10, 14, 0, 3)) == .notDue, "スケジューラ: 0:00の前は実行しない")
check(dec(noon, last: jd(2026, 10, 12, 0, 3)) == .run, "スケジューラ: 数日取り逃した場合は復帰後に実行(補完)")
check(dec(noon, last: jd(2026, 10, 14, 23, 50)) == .run, "スケジューラ: 前日23:50の手動フルは当日0:00分を満たさない")
check(dec(noon, last: nil, low: true) == .skipBattery, "スケジューラ: 低バッテリーはスキップ")
check(dec(noon, last: nil, busy: true) == .skipBusy, "スケジューラ: スキャン中はスキップ")
check(dec(noon, last: nil, low: true, busy: true) == .skipBusy, "スケジューラ: 実行中判定が優先")
var shs = sch; shs.lastScheduledRun = jd(2026, 10, 15, 0, 5)
check(dec(noon, last: nil, shs) == .notDue, "スケジューラ: lastScheduledRun も実行済みとみなす")
var sch3 = sch; sch3.fullScanHour = 3; sch3.fullScanMinute = 30
check(dec(jd(2026, 10, 15, 3, 29), last: jd(2026, 10, 14, 3, 31), sch3) == .notDue && dec(jd(2026, 10, 15, 3, 30), last: jd(2026, 10, 14, 3, 31), sch3) == .run, "スケジューラ: 実行時刻を変更できる(3:30)")
sch.scheduledScanEnabled = false
check(dec(noon, last: nil) == .disabled, "スケジューラ: 無効設定では実行しない")
sch.scheduledScanEnabled = true
// 夏時間（米国 2026-03-08 に 2:00→3:00）でも予定時刻が正しく求まる
var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
var sch2 = sch; sch2.fullScanHour = 2; sch2.fullScanMinute = 30
let nyNow = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
let tgt = SchedulerLogic.lastTarget(now: nyNow, hour: 2, minute: 30, calendar: ny)
check(tgt < nyNow && nyNow.timeIntervalSince(tgt) < 86400 && tgt > nyNow.addingTimeInterval(-2 * 86400), "夏時間: 存在しない2:30でも直近の予定時刻を返す")
check(SchedulerLogic.decide(settings: sch2, now: nyNow, lastFull: tgt, batteryLow: false, busy: false, calendar: ny) == .notDue, "夏時間: 予定時刻に実行済みなら再実行しない")
check(SchedulerLogic.catchUpDelay(now: jd(2026, 10, 14, 23, 58), hour: 0, minute: 0, calendar: jcal) == 30
      && SchedulerLogic.catchUpDelay(now: jd(2026, 10, 15, 0, 3), hour: 0, minute: 0, calendar: jcal) == 30
      && SchedulerLogic.catchUpDelay(now: jd(2026, 10, 15, 9, 0), hour: 0, minute: 0, calendar: jcal) == 300, "復帰後の待ち時間: 予定時刻付近は30秒、通常は5分")

func cat(_ id: String, _ items: [String]) -> CleanupCategory {
    CleanupCategory(id: id, name: id, summary: "", effect: "", roots: [], items: items.map { CleanupItem(url: URL(fileURLWithPath: "/x/\($0)"), size: 10) }, skipped: 0)
}
let allCats = ["caches", "logs", "npm", "brew", "pip", "xcode-derived", "xcode-archives", "xcode-devsupport", "node_modules"].map { cat($0, [$0 + "1"]) }
let safeIDs = SmartCare.safeItemIDs(allCats)
check(safeIDs == Set(["caches", "logs", "npm", "brew", "pip"].map { "/x/\($0)1" }), "スマートケア: 安全な分類のみ選択")
check(!safeIDs.contains { $0.contains("node_modules") || $0.contains("xcode") || $0.contains("Trash") }, "スマートケア: node_modules/Xcode/ゴミ箱は含まれない")
check(!SmartCare.safeCategoryIDs.contains("node_modules") && !SmartCare.safeCategoryIDs.contains("trash"), "スマートケア: 安全リストに危険分類なし")

var ns = Settings()
ns.deepScan = true; ns.launchAtLoginInitialized = true; ns.fullScanHour = 3; ns.wakeForScan = true; ns.wakeScheduleTime = "02:58:00"; ns.scanTargets = ["/a", "/b"]
try! ns.save()
check(Settings.load() == ns && Settings.load().deepScan == true, "Settings: 新規項目(deepScan/起動登録済み)の保存→読込")
var disk = Settings(); disk.ignoredDetections = [IgnoredDetection(path: "/p", sha256: "h")]
var edited = Settings(); edited.largeFileThresholdMB = 777; edited.deepScan = true
disk.mergeEditable(from: edited)
check(disk.largeFileThresholdMB == 777 && disk.deepScan && disk.ignoredDetections.count == 1, "Settings: 編集項目のみマージ(無視リストは保持)")
let sr = SmartCareResult(date: Date(timeIntervalSince1970: 1_700_000_000), junkBytes: 5, safeJunkBytes: 4, threats: 1, newLoginItems: 2,
                         changedLoginItems: 0, largeFileCount: 3, largeFileBytes: 9, deep: false, seconds: 1.5)
sr.save()
check(SmartCareResult.load() == sr && sr.needsAttention, "スマートケア結果の保存→読込と警告判定")
let dd = mk("deep/Apps", dir: true)
var ts = Settings(); ts.scanTargets = [dd.path, "/Applications", home.path + "/nonexistent-dir"]
let tq = SecurityScanner.buildTargets(settings: ts, loginItems: [])
check(tq.yara.map(\.path) == [dd.path, "/Applications"] && tq.clam.map(\.path) == [dd.path], "セキュリティ対象: 標準では ClamAV から /Applications を除外(YARA は全対象)")
ts.deepScan = true
check(SecurityScanner.buildTargets(settings: ts, loginItems: []).clam.map(\.path) == [dd.path, "/Applications"], "セキュリティ対象: じっくりでは ClamAV も /Applications を含む")


// --- P6: 堅牢化 ---
func runMain<T>(_ body: @MainActor @escaping () async -> T) -> T {
    var out: T? = nil
    Task { @MainActor in out = await body() }
    while out == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    return out!
}
// ドットファイル除外
let dotdir = mk("dot/Caches", dir: true)
_ = mk("dot/Caches/.DS_Store"); _ = mk("dot/Caches/real.app/f")
check((CleanupScanner.children(of: dotdir) ?? []).map(\.lastPathComponent) == ["real.app"], "クリーンアップ: .DS_Store などドットファイルを除外")
// 実行中アプリ・提供元・プロセス名・never-clean
var run2 = CleanupScanner.RunningInfo()
run2.ids = ["com.google.chrome"]; run2.vendors = ["google"]; run2.names = ["claude", "codex", "node"]
let rc = mk("run/Caches", dir: true)
for n in ["Google", "claude-cli-nodejs", "Codex", "com.google.Chrome.helper", "ms-playwright", "CloudKit", "GeoServices", "PassKit", "GameKit", "FamilyCircle", "harmless.app", "nodemodules-cache"] { _ = mk("run/Caches/\(n)/f.bin") }
let rr = CleanupScanner.userCacheItems(root: rc, otherCategoryNames: [], running: run2)
check(rr.keep.map(\.lastPathComponent).sorted() == ["harmless.app", "nodemodules-cache"], "キャッシュ除外: 提供元/プロセス名/実行中ID/never-clean を除外")
check(Set(rr.excluded.map(\.name)) == ["Google", "claude-cli-nodejs", "Codex", "com.google.Chrome.helper", "ms-playwright", "CloudKit", "GeoServices", "PassKit", "GameKit", "FamilyCircle"], "キャッシュ除外: 除外件数(10件)と一致")
check(CleanupScanner.neverCleanCaches.keys.contains("ms-playwright") && CleanupScanner.neverCleanCaches.keys.contains("cloudkit"), "never-clean リスト")
// iOS Wrapper アプリ / Containers 表示のみ
let iosApp = apps.appendingPathComponent("iPadThing.app")
try! fm.createDirectory(at: iosApp.appendingPathComponent("Wrapper/iPadThing.app"), withIntermediateDirectories: true)
(["CFBundleIdentifier": "com.ios.thing", "CFBundleName": "iPadThing"] as NSDictionary).write(to: iosApp.appendingPathComponent("Wrapper/iPadThing.app/Info.plist"), atomically: true)
check(AppCatalog.info(for: iosApp, withSize: false)?.bundleID == "com.ios.thing", "iOS Wrapper アプリのバンドルIDを取得")
let lib3 = mk("lib3", dir: true)
for rel in ["Application Support/com.ios.thing/a", "Containers/com.gone.container/a", "Group Containers/group.com.gone.group/a", "Caches/com.gone.cache/a", "Caches/com.system.knows/a", "Containers/com.ios.thing/a"] { _ = mk("lib3/\(rel)") }
let lo3 = Leftovers.find(library: lib3, installedIDs: ["com.ios.thing"], runningIDs: [], isInstalled: { $0 == "com.system.knows" })
check(lo3.map(\.url.lastPathComponent).sorted() == ["com.gone.cache", "com.gone.container", "group.com.gone.group"], "残骸: iOSアプリ/LaunchServices既知は除外")
check(lo3.filter(\.displayOnly).map(\.url.lastPathComponent).sorted() == ["com.gone.container", "group.com.gone.group"] && lo3.first { $0.url.lastPathComponent == "com.gone.cache" }?.displayOnly == false, "残骸: Containers/Group Containers は表示のみ")
check(Leftovers.deletable(lo3).map(\.url.lastPathComponent) == ["com.gone.cache"], "残骸: 削除対象に Containers を含まない")
let fails = AppUninstaller.trashLeftovers(lo3, library: lib3)
check(fails == 0 && !fm.fileExists(atPath: lib3.appendingPathComponent("Caches/com.gone.cache").path)
      && fm.fileExists(atPath: lib3.appendingPathComponent("Containers/com.gone.container").path)
      && fm.fileExists(atPath: lib3.appendingPathComponent("Group Containers/group.com.gone.group").path), "残骸: 実行しても Containers は残る")
// 前方一致 vs 別アプリ
let lib4 = mk("lib4", dir: true)
for rel in ["Application Support/com.google.Chrome/a", "Application Support/com.google.Chrome.canary/a", "Caches/com.google.Chrome.helper/a", "Preferences/com.google.Chrome.plist", "Preferences/com.google.Chrome.canary.plist"] { _ = mk("lib4/\(rel)") }
let rel4 = RelatedFinder.find(bundleID: "com.google.Chrome", appName: "Chrome", library: lib4, otherInstalledIDs: ["com.google.Chrome.canary", "com.google.Chrome"])
check(rel4.map(\.url.lastPathComponent).sorted() == ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.plist"], "関連: 別アプリ(canary)のデータは除外")
check(rel4.first { $0.url.lastPathComponent == "com.google.Chrome.helper" }?.kind == .bundlePrefix && rel4.first { $0.url.lastPathComponent == "com.google.Chrome" }?.kind == .bundleID, "関連: 前方一致のみは別扱い(既定未選択)")
let rel4c = RelatedFinder.find(bundleID: "com.google.Chrome.canary", appName: "Canary", library: lib4, otherInstalledIDs: ["com.google.Chrome.canary", "com.google.Chrome"])
check(rel4c.map(\.url.lastPathComponent).sorted() == ["com.google.Chrome.canary", "com.google.Chrome.canary.plist"], "関連: canary 自身は自分のデータを検出")
check(Set(RelatedFinder.allowedRoots(library: lib4).map(\.path)).isDisjoint(with: [lib4.path]), "アンインストール許可範囲に ~/Library 全体を含まない")
// 拒否リスト追加
let hm = NSHomeDirectory()
for p in [hm + "/Library/Mobile Documents/x", hm + "/Library/CloudStorage/OneDrive/x", hm + "/Library/Keychains/login.keychain-db", hm + "/Library/Mail/V10",
          hm + "/Library/Messages/chat.db", hm + "/Library/Accounts/a", hm + "/Library/Photos/x", hm + "/Library/Safari/History.db", hm + "/Library/Cookies/c",
          hm + "/Library/Containers/com.apple.Safari", hm + "/Library/Containers/com.apple.Safari/Data/x", hm + "/Library/Group Containers/group.com.apple.notes/x",
          hm + "/Pictures/My.photoslibrary", hm + "/Pictures/My.photoslibrary/originals/a.jpg", hm + "/Music/Music Library.musiclibrary/x",
          hm + "/Desktop", hm + "/Documents", hm + "/Downloads", hm + "/Pictures", hm + "/Movies", hm + "/Music", hm + "/Public", hm + "/Applications",
          hm + "/Library/Containers", hm + "/Library/Application Support"] {
    expectThrows("拒否リスト(追加): \(p)") { try SafeTrash.trash(URL(fileURLWithPath: p), allowedRoots: slash) }
}
// 動画検証の強化
let vOK = MediaInfo(duration: 10, videoCodec: "hevc", hasAudio: true)
check(VideoCompressor.verify(input: MediaInfo(duration: 0, videoCodec: "h264", hasAudio: true), inputSize: 100, output: vOK, outputSize: 50) != nil, "検証: 入力の長さ0は失敗")
check(VideoCompressor.verify(input: vOK, inputSize: 100, output: MediaInfo(duration: 0, videoCodec: "hevc", hasAudio: true), outputSize: 50) != nil, "検証: 出力の長さ0は失敗")
check(VideoCompressor.verify(input: vOK, inputSize: 100, output: MediaInfo(duration: 10, videoCodec: "h264", hasAudio: true), outputSize: 50) != nil, "検証: 出力が HEVC でなければ失敗")
// 確認ダイアログ
_ = NSApplication.shared
MainActor.assumeIsolated {
    let al = Confirm.makeAlert(title: "t", message: "m", button: "削除")
    check(al.buttons.count == 2 && al.buttons[0].title == "キャンセル" && al.buttons[0].keyEquivalent == "\r", "確認: キャンセルが既定ボタン(Return)")
    check(al.buttons[1].title == "削除" && al.buttons[1].keyEquivalent == "" && al.buttons[1].hasDestructiveAction, "確認: 実行ボタンはキー割り当てなし・破壊的")
}
var invoked: [Int] = []
let r1 = runMain { () -> Bool in
    Confirm.presenter = { _, _, _ in false }
    return await Confirm.destructive(title: "", message: "", button: "", snapshot: 1) { invoked.append($0) }
}
check(r1 == false && invoked.isEmpty, "確認: キャンセル時は action を実行しない")
let r2 = runMain { () -> Bool in
    var live = 1
    Confirm.presenter = { _, _, _ in live = 99; return true }   // 表示中に共有状態が変わっても
    let r = await Confirm.destructive(title: "", message: "", button: "", snapshot: live) { invoked.append($0) }
    return r
}
check(r2 == true && invoked == [1], "確認: 実行時はスナップショットの値が渡される")
// スナップショットのみを削除（共有の選択状態は使わない）
let snapDir = mk("snap", dir: true)
let fa = mk("snap/a.txt"), fb = mk("snap/b.txt")
let cm = runMain { () -> (Bool, Bool, Set<String>) in
    let m = CleanupModel()
    m.selected = [fb.path]   // 共有の選択は b だが、確認済みスナップショットは a のみ
    await m.cleanItems([CleanupJob(item: CleanupItem(url: fa, size: 1), roots: [snapDir])], settings: Settings(), rescan: false)
    return (fm.fileExists(atPath: fa.path), fm.fileExists(atPath: fb.path), m.selected)
}
check(cm.0 == false && cm.1 == true && cm.2 == [fb.path], "スナップショット: 渡された項目のみ削除し、共有の選択は変更しない")
// LargeFiles: 渡された roots の外は削除されない
let lfDir = mk("lfsnap", dir: true), otherDir = mk("lfother", dir: true)
let lf1 = mk("lfsnap/x.bin"), lf2 = mk("lfother/y.bin")
_ = runMain { () -> Bool in
    let m = LargeFilesModel()
    await m.trash([LargeFile(url: lf1, size: 1, lastUsed: Date(), kind: ""), LargeFile(url: lf2, size: 1, lastUsed: Date(), kind: "")], roots: [lfDir])
    return true
}
check(!fm.fileExists(atPath: lf1.path) && fm.fileExists(atPath: lf2.path), "大容量: 設定した検索範囲の外は削除されない")
// スマートケア: 完了後に共有状態が変わっても結果に影響しない
let st = runMain { () -> AppState in AppState() }
let scRes = runMain { () -> SmartCareResult? in
    st.smartCare.steps = SmartCareSteps(
        cleanup: { s, _ in
            let r: (junk: Int64, safeJunk: Int64) = (100, 40)
            s.cleanup.categories = []          // ステップ後に共有状態が変わる（別の掃除など）
            return r },
        security: { _, _ in 2 }, loginItems: { _ in (1, 0) }, largeFiles: { _, _ in (3, 9) })
    await st.smartCare.run(state: st)
    return st.smartCare.result
}
check(scRes?.junkBytes == 100 && scRes?.safeJunkBytes == 40 && scRes?.threats == 2 && scRes?.newLoginItems == 1 && scRes?.largeFileCount == 3, "スマートケア: 結果はステップ出力から確定(共有状態を再読込しない)")
// 並行スキャンは進行中の完了を待つ
var cs = Settings(); cs.largeFileRoots = [mk("emptyroot", dir: true).path]
let cc = runMain { () -> (Bool, Bool) in
    let m = CleanupModel()
    let first = Task { @MainActor in await m.scan(settings: cs) }
    await Task.yield()
    await m.scan(settings: cs)              // 進行中の1回目を待つ（即 return しない）
    let afterSecond = (m.hasScanned, m.scanning)
    await first.value
    return afterSecond
}
check(cc.0 == true && cc.1 == false, "スキャン: 実行中なら完了を待ってから戻る")
// ログイン項目の無効化
let agents = mk("agents", dir: true)
func loginItem(_ name: String) -> LoginItem {
    let u = agents.appendingPathComponent(name + ".plist")
    (["Label": name] as NSDictionary).write(to: u, atomically: true)
    return LoginItem(label: name, plistURL: u, program: nil, runAtLoad: false, keepAlive: false, domain: .user, plistSHA256: "")
}
func sr(_ code: Int32, _ err: String = "") -> ShellResult? { ShellResult(stdout: "", stderr: err, exitCode: code) }
let li1 = loginItem("com.t.fail")
let dis1: Bool = await_sync { do { try await LoginItems.disable(li1, launchctl: { a in a[0] == "bootout" ? sr(5, "Boot-out failed: 5: Input/output error") : sr(113) }, agentsRoot: agents); return false } catch { return true } }
check(dis1 && fm.fileExists(atPath: li1.plistURL.path), "ログイン項目: bootout 失敗なら plist はそのまま")
let li2 = loginItem("com.t.notloaded")
let dis2: Bool = await_sync { do { try await LoginItems.disable(li2, launchctl: { a in a[0] == "bootout" ? sr(3, "Boot-out failed: 3: No such process") : sr(113) }, agentsRoot: agents); return true } catch { return false } }
check(dis2 && !fm.fileExists(atPath: li2.plistURL.path), "ログイン項目: 未ロード(No such process)は正常として plist を移動")
let li3 = loginItem("com.t.still")
let dis3: Bool = await_sync { do { try await LoginItems.disable(li3, launchctl: { a in a[0] == "bootout" ? sr(0) : sr(0) }, agentsRoot: agents); return false } catch { return true } }
check(dis3 && fm.fileExists(atPath: li3.plistURL.path), "ログイン項目: bootout 後も読み込まれていれば plist はそのまま")
let li4 = loginItem("com.t.ok")
let dis4: Bool = await_sync { do { try await LoginItems.disable(li4, launchctl: { a in a[0] == "bootout" ? sr(0) : sr(113) }, agentsRoot: agents); return true } catch { return false } }
check(dis4 && !fm.fileExists(atPath: li4.plistURL.path), "ログイン項目: bootout 成功＋消滅確認後に plist を移動")
// アプリ内ファイルの検出
check(SecurityModel.enclosingApp(of: "/Applications/Foo.app/Contents/MacOS/foo")?.lastPathComponent == "Foo.app" && SecurityModel.enclosingApp(of: "/Users/x/Downloads/a.bin") == nil, "セキュリティ: .app 内部のファイルを判定")
// 実行中の再確認は削除直前に評価される
var polled = 0
let app5 = makeApp("Run.app", "com.example.run", "Run")
let info5 = AppCatalog.info(for: app5, withSize: false)!
let lib5 = mk("lib5", dir: true)
do { _ = try AppUninstaller.uninstall(app: info5, related: [], isRunning: { polled += 1; return true }, library: lib5, appRoots: [apps]); check(false, "再確認で実行中なら拒否") }
catch { check(polled == 1 && fm.fileExists(atPath: app5.path), "アンインストール: 削除直前に実行中を再確認して拒否") }


// --- 残骸: macOS 管理の設定を除外 ---
let lib6 = mk("lib6", dir: true)
for rel in ["Preferences/org.cups.PrintingPrefs.plist", "Preferences/.GlobalPreferences.plist", "Preferences/loginwindow.plist", "Preferences/pbs.plist",
            "Preferences/ContextStoreAgent.plist", "Preferences/diagnostics_agent.plist", "Preferences/com.openssh.ssh-agent.plist", "Preferences/org.openssh.x.plist",
            "Preferences/systemgroup.com.apple.x.plist", "Group Containers/group.com.apple.notes/a", "Preferences/com.realgone.app.plist"] { _ = mk("lib6/\(rel)") }
let lo6 = Leftovers.find(library: lib6, installedIDs: [], runningIDs: [], isInstalled: { _ in false }).map(\.url.lastPathComponent)
check(lo6 == ["com.realgone.app.plist"], "残骸: org.cups/openssh/com.apple/ドット始まり/非ドメイン形式の設定は除外")
check(Leftovers.isSystemOwned("org.cups.printingprefs") && Leftovers.isSystemOwned("group.com.apple.x") && !Leftovers.isSystemOwned("com.vercel.cli"), "残骸: システム管理名の判定")
// --- Security E2E（ツールが無ければ SKIP） ---
func runSecurityTests() async {
    guard let yara = Tools.path("yara"), let yarac = Tools.path("yarac") else { print("SKIP YARA テスト (yara/yarac なし)"); return await clamTests() }
    let sdir = mk("sec/files", dir: true)
    let marker = "MACCARE-UNIQUE-" + "STRING-7f3a91"
    try! "hello \(marker) world".write(to: sdir.appendingPathComponent("hit.txt"), atomically: true, encoding: .utf8)
    try! "nothing here".write(to: sdir.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
    let rules = mk("sec/test.yar")
    try! "rule MacCareTestRule { strings: $a = \"\(marker)\" condition: $a }\n".write(to: rules, atomically: true, encoding: .utf8)
    let out = work.appendingPathComponent("sec/test.yarc")
    let c1 = try? await YaraEngine.ensureCompiled(rules: rules, version: "1", yarac: yarac, out: out)
    let c2 = try? await YaraEngine.ensureCompiled(rules: rules, version: "1", yarac: yarac, out: out)
    let c3 = try? await YaraEngine.ensureCompiled(rules: rules, version: "2", yarac: yarac, out: out)
    check(c1 == true && c2 == false && c3 == true, "YARA: 同一バージョンは再コンパイルせず、変更時は再コンパイル")
    let hits = (try? await YaraEngine.scan(compiled: out, target: sdir, yara: yara)) ?? []
    check(hits.count == 1 && hits[0].signature == "MacCareTestRule" && hits[0].path.hasSuffix("/hit.txt"), "YARA: カスタムルールで検出を解析")
    let cleanDir = mk("sec/cleanonly", dir: true)
    try! "benign".write(to: cleanDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let cleanHits = try? await YaraEngine.scan(compiled: out, target: cleanDir, yara: yara)
    check(cleanHits?.isEmpty == true, "YARA: クリーンなディレクトリは0件")
    await clamTests()
}
func clamTests() async {
    guard let clam = Tools.path("clamscan") else { print("SKIP ClamAV テスト (clamscan なし)"); return }
    let dir = mk("sec/clam", dir: true)
    let eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$" + "EICAR-STANDARD-ANTIVIRUS-TEST-FILE" + "!$H+H*"
    try! eicar.write(to: dir.appendingPathComponent("eicar.com"), atomically: true, encoding: .utf8)
    let hits = (try? await ClamEngine.scan(targets: [dir], clamscan: clam)) ?? []
    check(hits.count == 1 && hits[0].path.hasSuffix("/eicar.com") && hits[0].signature.lowercased().contains("eicar"), "ClamAV: EICAR を検出")
    let clean = mk("sec/clamclean", dir: true)
    try! "benign".write(to: clean.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let none = try? await ClamEngine.scan(targets: [clean], clamscan: clam)
    check(none?.isEmpty == true, "ClamAV: クリーンなディレクトリは0件")
}
let sem3 = DispatchSemaphore(value: 0)
Task { await runSecurityTests(); sem3.signal() }
sem3.wait()


// MARK: - 健康スコア・おすすめ・システムメトリクス
func healthTests() {
    let now = Date()
    func inp(threats: Int = 0, login: Int = 0, free: Int64? = 500, total: Int64? = 1000, junk: Int64 = 0, last: Date? = nil) -> HealthInput {
        HealthInput(threats: threats, newOrChangedLoginItems: login, freeBytes: free, totalBytes: total, junkBytes: junk,
                    lastSmartCare: last ?? now, now: now)
    }
    check(HealthScore.score(inp()) == 100, "スコア: 問題なしは100")
    check(HealthScore.score(inp(threats: 1)) == 70, "スコア: 脅威1件で-30")
    check(HealthScore.score(inp(threats: 5)) == 40, "スコア: 脅威の減点は最大-60")
    check(HealthScore.score(inp(login: 1)) == 90 && HealthScore.score(inp(login: 9)) == 80, "スコア: ログイン項目 -10/件・最大-20")
    check(HealthScore.score(inp(free: 99, total: 1000)) == 80 && HealthScore.score(inp(free: 100, total: 1000)) == 100, "スコア: 空き10%未満で-20（ちょうど10%は対象外）")
    check(HealthScore.score(inp(junk: 5_000_000_000)) == 95 && HealthScore.score(inp(junk: 4_999_999_999)) == 100, "スコア: 不要データ5GB以上で-5")
    check(HealthScore.score(inp(last: now.addingTimeInterval(-15 * 86400))) == 90, "スコア: 14日超で-10")
    check(HealthScore.score(inp(last: now.addingTimeInterval(-14 * 86400))) == 100, "スコア: ちょうど14日は対象外")
    check(HealthScore.score(HealthInput(threats: 0, newOrChangedLoginItems: 0, freeBytes: 500, totalBytes: 1000, junkBytes: 0, lastSmartCare: nil, now: now)) == 90, "スコア: 未実行は-10")
    check(HealthScore.score(inp(threats: 9, login: 9, free: 1, junk: 9_000_000_000, last: now.addingTimeInterval(-99 * 86400))) == 0, "スコア: 下限は0")
    check(HealthScore.headline(80) == "Mac は良好です" && HealthScore.headline(79) == "注意が必要です"
          && HealthScore.headline(50) == "注意が必要です" && HealthScore.headline(49) == "対処が必要です", "見出し: 80/50 の境界")

    var r = RecommendationInput(now: now); r.lastSmartCare = now
    check(Recommendations.all(r).isEmpty, "おすすめ: 問題なしなら空")
    r.threats = 1; r.videoCount = 3; r.videoBytes = 10_000_000_000; r.cleanMyMacItems = 2; r.junkBytes = 2_000_000_000
    r.notificationsAuthorized = false; r.fullDiskAccessMissing = true
    let all = Recommendations.all(r)
    check(all.first?.kind == .threats && all.first?.action == .navigate("security"), "おすすめ: 脅威が最優先")
    check(all.map(\.kind) == [.threats, .videos, .cleanMyMac, .junk, .notifications, .fullDiskAccess], "おすすめ: 優先順")
    check(Recommendations.top(r).count == 3, "おすすめ: 上位3件")
    check(all[1].title.contains(formatBytes(8_000_000_000)) && all[1].action == .navigate("compress"), "おすすめ: 動画は合計の80%を見積もる")
    r.threats = 0; r.junkBytes = 999_999_999
    check(!Recommendations.all(r).contains { $0.kind == .junk }, "おすすめ: 不要データ1GB未満は出さない")
    var o = RecommendationInput(now: now); o.lastSmartCare = now.addingTimeInterval(-8 * 86400)
    check(Recommendations.all(o).first?.kind == .staleScan && Recommendations.all(o).first?.action == .runSmartCare, "おすすめ: 7日超でスマートケア")
    o.lastSmartCare = nil
    check(Recommendations.all(o).first?.kind == .staleScan, "おすすめ: 未実行でスマートケア")
    var n = RecommendationInput(now: now); n.lastSmartCare = now; n.notificationsAuthorized = true
    check(Recommendations.all(n).isEmpty, "おすすめ: 通知が許可済みなら出さない")
    n.notificationsAuthorized = false
    if case .openURL(let u)? = Recommendations.all(n).first?.action { check(u.contains("Notifications"), "おすすめ: 通知は設定の通知ペインを開く") }
    else { check(false, "おすすめ: 通知は設定の通知ペインを開く") }
}
func metricsTests() {
    check(MetricsMath.memoryPressure(freeLevel: 60) == 40 && MetricsMath.memoryPressure(freeLevel: 120) == 0, "メモリ: プレッシャー = 100 - level")
    let a: [UInt32] = [100, 50, 800, 0, 100, 50, 800, 0]
    let b: [UInt32] = [200, 100, 1000, 0, 200, 100, 1000, 0]
    check(abs(MetricsMath.cpuLoad(prev: a, cur: b) - 42.857) < 0.01, "CPU: ティック差分から負荷を計算")
    check(MetricsMath.cpuLoad(prev: a, cur: a) == 0, "CPU: 差分0は0%")
    check(MetricsMath.counterDelta(prev: UInt32.max - 5, cur: 10) == 16, "ネットワーク: 32bitカウンタの桁あふれ")
    let t0 = Date()
    let p = NetworkCounters(perInterface: ["en0": (1000, 500)], date: t0)
    let c = NetworkCounters(perInterface: ["en0": (5000, 2500), "en1": (1, 1)], date: t0.addingTimeInterval(2))
    let th = NetworkCounters.throughput(prev: p, cur: c)
    check(th.down == 2000 && th.up == 1000, "ネットワーク: スループット（新規IFは無視）")
    check(MetricsMath.appended(Array(repeating: 1, count: 30), 2).count == 30 && MetricsMath.appended([1], 2) == [1, 2], "履歴: 末尾30件のみ保持")
    check(MetricsMath.rate(5_000) == "5 KB/s" && MetricsMath.rate(2_500_000) == "2.5 MB/s" && MetricsMath.rate(12) == "12 B/s", "表示: 転送速度")
    check(MetricsMath.minutes(454) == "7時間34分" && MetricsMath.minutes(42) == "42分", "表示: 残り時間")
    check(MetricsMath.batteryCondition("Good") == "正常" && MetricsMath.batteryCondition(nil) == nil, "バッテリー: 状態の日本語化")

    let ps = """
      101  3355443 12.5 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      102  1048576  8.0 /Applications/Google Chrome.app/Contents/Frameworks/X/Google Chrome Helper (Renderer)
      200   204800  3.1 /usr/libexec/trustd
      bad line
    """
    let ents = ProcessStats.parse(ps)
    check(ents.count == 3 && ents[0].pid == 101 && ents[0].path.hasSuffix("Google Chrome"), "ps: 空白を含むパスを解析")
    check(ProcessStats.appName(path: ents[1].path) == "Google Chrome" && ProcessStats.appName(path: "/usr/libexec/trustd") == "trustd", "ps: .app 単位の名前")
    check(ProcessStats.appName(path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent") == "Web コンテンツ（WebKit）"
          && ProcessStats.appName(path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores") == "Spotlight（索引作成）"
          && ProcessStats.appName(path: "com.macpaw.CleanMyMac5.HealthMonitor") == "CleanMyMac5 HealthMonitor"
          && ProcessStats.appName(path: "./run") == "run" && ProcessStats.appName(path: "a.b") == "a.b", "ps: .app 外の表示名")
var lf = LargeFile(url: URL(fileURLWithPath: "/x/a.mov"), size: 1, lastUsed: Date(), kind: "")
let lfBefore = lf.needsCompression
lf.isHEVC = true
check(lfBefore && !lf.needsCompression && !LargeFile(url: URL(fileURLWithPath: "/x/a.zip"), size: 1, lastUsed: Date(), kind: "").needsCompression,
      "大容量: 圧縮済み動画と動画以外は圧縮の提案対象外")
    let usage = ProcessStats.aggregate(ents)
    check(ProcessStats.topMemory(usage)?.name == "Google Chrome" && ProcessStats.topMemory(usage)?.memoryBytes == (3355443 + 1048576) * 1024, "ps: ヘルパーを合算して最大メモリ")
    check(ProcessStats.topCPU(usage)?.cpu == 20.5, "ps: 最大CPU")
    let sp = SpeedTest.parse("{\"dl_throughput\":123000000,\"ul_throughput\":45500000,\"responsiveness\":1000}")
    check(sp != nil && abs(sp!.down - 123) < 0.001 && abs(sp!.up - 45.5) < 0.001 && SpeedTest.parse("oops") == nil, "networkQuality: JSON 解析")
    let lv = BluetoothInfo.parse(Data("{\"AA\":{\"single\":80},\"BB\":{\"left\":60,\"right\":40}}".utf8))
    check(lv["AA"]?.minimum == 80 && lv["BB"]?.minimum == 40 && BluetoothInfo.parse(Data()).isEmpty, "Bluetooth: 残量 JSON 解析")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    let d1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 11, minute: 42))!
    let d2 = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18, minute: 13))!
    let d3 = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 5))!
    check(ShortDate.format(d1, now: now, calendar: cal) == "今日 11:42" && ShortDate.format(d2, now: now, calendar: cal) == "昨日 18:13"
          && ShortDate.format(d3, now: now, calendar: cal) == "10/3 09:05", "日時: 今日/昨日/それ以前")
    check(ShortDate.duration(420) == "7分" && ShortDate.duration(42) == "42秒", "日時: 所要時間")
}
healthTests()
metricsTests()
scanUpdateTests()

// MARK: - 履歴のグループ化・集計
func historyTests() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    func dt(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: d, hour: h, minute: m, second: s))!
    }
    func en(_ d: Date, _ k: HistoryKind, _ t: String, _ b: Int64 = 0, _ r: String = "ok", _ det: String = "") -> HistoryEntry {
        HistoryEntry(date: d, kind: k, target: t, bytes: b, result: r, detail: det)
    }
    let t0 = dt(14, 18, 13, 38)

    // クリーンアップ要約＋同時刻の trash は 1 行にまとまり、二重計上されない
    var es: [HistoryEntry] = (1...3).map { en(t0, .trash, "/Users/x/Library/Caches/a\($0)", Int64($0) * 1000) }
    es.append(en(t0, .cleanup, "3 件", 6000, "ok", "失敗 0 件"))
    var rows = HistoryGrouping.rows(from: es)
    check(rows.count == 1 && rows[0].title == "3 項目をゴミ箱へ" && rows[0].children.count == 3 && rows[0].freedBytes == 6000, "履歴: cleanup と同時刻 trash を 1 行に束ねる")
    let now = dt(16, 12, 0)
    var st = HistoryGrouping.stats(rows, now: now, calendar: cal)
    check(st.totalFreed == 6000 && st.monthFreed == 6000, "履歴: クリーンアップは要約の bytes のみ集計（二重計上なし）")

    // 秒が切り上がって 1 秒ずれた trash も同じ要約に入る。要約より件数が多い古い trash は取り込まない
    es = [en(t0.addingTimeInterval(-300), .trash, "/old", 77), en(t0.addingTimeInterval(-1), .trash, "/a", 10), en(t0, .trash, "/b", 20), en(t0, .cleanup, "2 件", 30)]
    rows = HistoryGrouping.rows(from: es)
    check(rows.count == 2 && rows[0].children.count == 2 && rows[1].title == "1 項目をゴミ箱へ", "履歴: 件数上限と 5 秒閾値で別操作の trash を取り込まない")

    // 時刻が離れた trash は別行、近いものは束ねる（要約なし）
    es = [en(t0, .trash, "/a", 1), en(t0.addingTimeInterval(3), .trash, "/b", 2), en(t0.addingTimeInterval(8.5), .trash, "/c", 4), en(t0.addingTimeInterval(200), .trash, "/d", 8)]
    rows = HistoryGrouping.rows(from: es)
    check(rows.count == 3 && rows.map(\.itemCount) == [1, 1, 2], "履歴: 要約なしの trash は 5 秒以内ごとに束ねる（間隔は連鎖で判定）")
    check(rows[2].freedBytes == 3 && rows[2].title == "2 項目をゴミ箱へ", "履歴: 束ねた trash の容量は合計")

    // 圧縮: 元ファイルの trash は取り込み、削減量のみを集計
    es = [en(t0, .trash, "/private/tmp/ナレッジ/動画.mov", 900), en(t0, .compress, "/tmp/ナレッジ/動画.mov", 700, "ok", "出力: /tmp/ナレッジ/動画.mp4")]
    rows = HistoryGrouping.rows(from: es)
    check(rows.count == 1 && rows[0].title == "動画を圧縮" && rows[0].subtitle == "動画.mp4" && rows[0].outputPath == "/tmp/ナレッジ/動画.mp4" && rows[0].freedBytes == 700, "履歴: 圧縮は元 trash を取り込み出力先を保持")
    st = HistoryGrouping.stats(rows, now: now, calendar: cal)
    check(st.totalFreed == 700, "履歴: 圧縮は削減量のみ集計")

    // アンインストール: アプリ＋関連の trash を取り込む
    es = [en(t0, .trash, "/Applications/Foo.app", 500), en(t0, .trash, "/Users/x/Library/Foo", 50),
          en(t0, .uninstall, "/Applications/Foo.app", 550, "ok", "com.foo、関連 1 件、失敗 0 件")]
    rows = HistoryGrouping.rows(from: es)
    check(rows.count == 1 && rows[0].title == "アプリを削除" && rows[0].children.count == 2 && HistoryGrouping.stats(rows, now: now, calendar: cal).totalFreed == 550, "履歴: アンインストールの trash を取り込む")

    // ゴミ箱を空にする: 行の容量は出すが累計には含めない
    es = [en(t0, .cleanup, "~/.Trash", 5000)]
    rows = HistoryGrouping.rows(from: es)
    check(rows[0].isEmptyTrash && rows[0].freedBytes == 5000 && HistoryGrouping.stats(rows, now: now, calendar: cal).totalFreed == 0, "履歴: ゴミ箱を空にした分は累計に含めない")

    // スキャン回数: スマートケア内のセキュリティスキャン・定期通知は 1 回
    let s0 = dt(15, 5, 10, 28)
    es = [en(s0.addingTimeInterval(-2), .scan, "セキュリティスキャン（10 対象）", 0, "clean", "YARA 0 / ClamAV 0 件、標準モード、1025 秒"),
          en(s0, .scan, "スマートケア（定期フル）", 540672, "clean", "脅威 0 件 / 不要データ 541 KB / 新しいログイン項目 0 件、1025 秒"),
          en(s0, .scan, "定期フルスキャン", 540672, "notified", "脅威 0 件 / 不要データ 541 KB"),
          en(s0.addingTimeInterval(600), .scan, "セキュリティスキャン（10 対象）", 0, "clean", "YARA 0 / ClamAV 0 件、30 秒"),
          en(s0.addingTimeInterval(700), .scan, "/tmp/evil", 0, "ignored", "YARA: x")]
    rows = HistoryGrouping.rows(from: es)
    st = HistoryGrouping.stats(rows, now: now, calendar: cal)
    check(rows.count == 3 && st.scanCount == 2, "履歴: スキャン回数はスマートケア一式を 1 回・無視操作は数えない")
    let sc = rows.first { $0.title == "スマートケア" }
    check(sc?.children.count == 2 && sc?.overview == "脅威 0 件\n不要データ 541 KB" && sc?.seconds == 1025 && sc?.subtitle == "定期フル・所要 17分", "履歴: スマートケア行に関連記録と概要・所要時間")
    // 通知記録が単独（直前に定期スマートケアが無い）なら 1 回と数える
    rows = HistoryGrouping.rows(from: [en(s0, .scan, "定期スキャン", 1, "no-notification-permission", "脅威 0 件")])
    check(rows.count == 1 && rows[0].countsAsScan, "履歴: 単独の通知記録も 1 回")
    // 古い版: 通知記録が 136 秒後でも直前の定期スマートケアに結びつく
    rows = HistoryGrouping.rows(from: [en(s0, .scan, "スマートケア（定期）", 1, "clean", "脅威 0 件"), en(s0.addingTimeInterval(136), .scan, "定期スキャン", 1, "no-notification-permission", "")])
    check(rows.count == 1 && rows[0].children.count == 1, "履歴: 遅れた通知記録も結びつける")

    // 失敗件数: failed と partial。成功は数えない
    es = [en(t0, .trash, "/f", 1, "failed", "x"), en(t0.addingTimeInterval(100), .cleanup, "~/.Trash", 0, "failed", "e"),
          en(t0.addingTimeInterval(200), .uninstall, "残骸 2 件", 5, "partial"), en(t0.addingTimeInterval(300), .compress, "/a.mov", 5, "ok", "出力: /a.mp4")]
    rows = HistoryGrouping.rows(from: es)
    st = HistoryGrouping.stats(rows, now: now, calendar: cal)
    check(rows.count == 4 && st.failureCount == 3, "履歴: 失敗件数は失敗＋一部失敗")
    check(rows.first { $0.isEmptyTrash }?.freedBytes == nil, "履歴: 失敗した操作は解放容量を出さない")

    // 今月の判定（月初・月末・前年同月）
    es = [en(dt(1, 0, 0, 0), .compress, "/a.mov", 10, "ok", "出力: /a.mp4"),
          en(dt(30, 23, 59, 59, month: 9), .compress, "/b.mov", 100, "ok", "出力: /b.mp4"),
          en(dt(20, 12, 0, 0, year: 2025), .compress, "/c.mov", 1000, "ok", "出力: /c.mp4"),
          en(dt(31, 23, 59, 59), .compress, "/d.mov", 10000, "ok", "出力: /d.mp4")]
    rows = HistoryGrouping.rows(from: es)
    st = HistoryGrouping.stats(rows, now: now, calendar: cal)
    check(st.totalFreed == 11110 && st.monthFreed == 10010, "履歴: 今月の判定（前月末・前年同月・月末を区別）")

    // 日付見出しの区切り（23:59:59 と 0:00:00 は別の日）
    es = [en(dt(15, 23, 59, 59), .compress, "/a.mov", 1, "ok", "出力: /a.mp4"), en(dt(16, 0, 0, 0), .compress, "/b.mov", 1, "ok", "出力: /b.mp4"),
          en(dt(16, 11, 59, 59), .compress, "/c.mov", 1, "ok", "出力: /c.mp4"), en(dt(14, 8, 0, 0), .compress, "/d.mov", 1, "ok", "出力: /d.mp4"),
          en(dt(20, 8, 0, 0, month: 12, year: 2025), .compress, "/e.mov", 1, "ok", "出力: /e.mp4")]
    let secs = HistoryGrouping.sections(HistoryGrouping.rows(from: es), now: now, calendar: cal)
    check(secs.map(\.title) == ["今日", "昨日", "10月14日（水）", "2025年12月20日（土）"], "履歴: 日付見出し（今日・昨日・曜日付き・他年）")
    check(secs.map { $0.rows.count } == [2, 1, 1, 1], "履歴: 0 時の境界で日が分かれ、新しい順に並ぶ")
    check(HistoryFormat.time(dt(3, 9, 5), calendar: cal) == "09:05", "履歴: 時刻表示")

    // 並び順と同時刻の記録順
    es = [en(t0, .compress, "/a.mov", 1, "ok", "出力: /a.mp4"), en(t0, .compress, "/b.mov", 2, "ok", "出力: /b.mp4")]
    check(HistoryGrouping.rows(from: es).map(\.freedBytes) == [2, 1], "履歴: 同時刻は後から記録した方が上")

    // result の日本語化
    check(HistoryResult.label("ok") == "成功" && HistoryResult.label("failed") == "失敗" && HistoryResult.label("clean") == "脅威なし"
          && HistoryResult.label("notified") == "通知済み" && HistoryResult.label("no-notification-permission") == "通知なし（権限未許可）"
          && HistoryResult.label("partial") == "一部失敗" && HistoryResult.label("found") == "脅威を検出", "履歴: result の日本語化")
    check(HistoryResult.label("mystery") == "mystery" && HistoryResult.outcome("mystery") == .info && HistoryResult.outcome("failed") == .failure, "履歴: 未知の result はそのまま表示")

    // 絞り込み
    check(HistoryKind.allCases.allSatisfy { k in HistoryFilter.allCases.filter { $0 != .all }.filter { $0.matches(k) }.count == 1 }, "履歴: 全 kind がちょうど 1 つの絞り込みに属する")
    check(HistoryFilter.delete.matches(.uninstall) && HistoryFilter.delete.matches(.loginItem) && HistoryFilter.cleanup.matches(.trash), "履歴: 削除＝アンインストール・ログイン項目、掃除＝cleanup・trash")
    check(HistoryFormat.freed(2_000_000_000) == "−\(formatBytes(2_000_000_000))" && HistoryFormat.freed(0) == nil && HistoryFormat.freed(-5)?.hasPrefix("+") == true, "履歴: 解放容量の符号表示")
}
historyTests()

func compressCandidateTests() {
    let M: Int64 = 1_000_000
    // 100 秒・200MB → 16 Mbps、上限 2.5Mbps で 31.25MB
    check(CompressEstimator.bitrate(size: 200 * M, duration: 100) == 16_000_000, "圧縮候補: ビットレート = size*8/duration")
    check(CompressEstimator.estimatedOutput(size: 200 * M, duration: 100) == 31_250_000, "圧縮候補: 推定出力は 2.5Mbps で頭打ち")
    check(CompressEstimator.estimatedSaving(size: 200 * M, duration: 100) == 168_750_000, "圧縮候補: 推定削減量 = size - 推定出力")
    // 2Mbps（上限未満）→ 推定出力は元サイズ相当で、削減量 0
    check(CompressEstimator.estimatedOutput(size: 25 * M, duration: 100) == 25 * M, "圧縮候補: 上限未満は入力ビットレートで見積もる")
    check(CompressEstimator.estimatedSaving(size: 25 * M, duration: 100) == 0, "圧縮候補: 削減量は 0 未満にならない（低ビットレート）")
    check(CompressEstimator.estimatedSaving(size: 100 * M, duration: 1) ?? -1 >= 0 && CompressEstimator.estimatedSaving(size: 1, duration: 1_000_000) == 0, "圧縮候補: 端の値でも削減量が負にならない")
    // duration 不明
    check(CompressEstimator.bitrate(size: 200 * M, duration: nil) == nil && CompressEstimator.bitrate(size: 200 * M, duration: 0) == nil, "圧縮候補: duration 不明/0 はビットレート nil")
    check(CompressEstimator.estimatedOutput(size: 200 * M, duration: nil) == nil && CompressEstimator.estimatedSaving(size: 200 * M, duration: nil) == nil, "圧縮候補: duration 不明は見込み nil")
    check(!CompressEstimator.defaultSelected(size: 200 * M, duration: nil) && !CompressEstimator.isLowBitrate(size: 200 * M, duration: nil), "圧縮候補: duration 不明は既定チェックなし")
    // 低ビットレート 4Mbps の境界（100秒で 50MB = 4Mbps ちょうど）
    check(CompressEstimator.isLowBitrate(size: 50 * M - 1, duration: 100) && !CompressEstimator.isLowBitrate(size: 50 * M, duration: 100), "圧縮候補: 4Mbps 未満が低ビットレート（境界）")
    check(!CompressEstimator.defaultSelected(size: 40 * M, duration: 100) && CompressEstimator.defaultSelected(size: 50 * M, duration: 100), "圧縮候補: 既定チェックは 4Mbps 以上のみ")
    // キャッシュ判定
    func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    check(CompressEstimator.isCachePath(u("/Users/a/Movies/CapCut/User Data/Cache/SmartCrop/x.mp4")), "圧縮候補: Cache 配下はキャッシュ")
    check(CompressEstimator.isCachePath(u("/Users/a/x/CACHES/y/z.mov")) && CompressEstimator.isCachePath(u("/Users/a/x/cache/z.mov")), "圧縮候補: caches/大文字小文字を無視")
    check(!CompressEstimator.isCachePath(u("/Users/a/Movies/Cachet/z.mov")) && !CompressEstimator.isCachePath(u("/Users/a/Movies/z.mov")), "圧縮候補: 構成要素が一致しないものは対象")
    // 100MB の境界（拡張子・サイズ）
    func lf(_ path: String, _ size: Int64) -> LargeFile { LargeFile(url: u(path), size: size, lastUsed: .distantPast, kind: "") }
    check(CompressEstimator.isPreCandidate(lf("/Users/a/Movies/a.mp4", 100_000_000)), "圧縮候補: 100MB ちょうどは対象")
    check(!CompressEstimator.isPreCandidate(lf("/Users/a/Movies/a.mp4", 99_999_999)), "圧縮候補: 100MB 未満は対象外")
    check(!CompressEstimator.isPreCandidate(lf("/Users/a/Movies/a.zip", 500_000_000)) && CompressEstimator.isPreCandidate(lf("/Users/a/Movies/a.MOV", 500_000_000)), "圧縮候補: 動画拡張子のみ（大文字可）")
    check(!CompressEstimator.isPreCandidate(lf("/Users/a/Movies/Cache/a.mp4", 500_000_000)), "圧縮候補: キャッシュパスは対象外")
    // キュー内の除外と合計
    let c1 = CompressCandidate(url: u("/v/a.mp4"), size: 200 * M, duration: 100)
    let c2 = CompressCandidate(url: u("/v/b.mp4"), size: 300 * M, duration: nil)
    check(CompressEstimator.visible([c1, c2], excludingPaths: ["/v/a.mp4"]).map(\.id) == ["/v/b.mp4"], "圧縮候補: キュー内のファイルは候補から外れる")
    check(CompressEstimator.totalSaving([c1, c2]) == 168_750_000 && CompressEstimator.totalSize([c1, c2]) == 500 * M, "圧縮候補: 合計（不明は削減 0 として加算）")
    check(c1.defaultSelected && !c2.defaultSelected, "圧縮候補: 構造体の既定チェック")
    check(CompressEstimator.bitrateText(2_300_000) == "2.3 Mbps" && CompressEstimator.bitrateText(nil) == "—", "圧縮候補: ビットレート表示")
}
compressCandidateTests()

try? fm.removeItem(at: work)
print("\n\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
