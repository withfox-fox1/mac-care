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
check(relNames(.bundleID) == ["ABCDE12345.com.example.foo", "com.example.foo", "com.example.foo", "com.example.foo.helper", "com.example.foo.plist", "com.example.foo.savedState"], "関連: Bundle ID 完全/前方/後方一致")
check(relNames(.nameOnly) == ["Foo"], "関連: 名前のみ一致は区別される")
check(!rel.contains { $0.url.lastPathComponent == "com.example.foobar" || $0.url.lastPathComponent == "Other" }, "関連: 無関係なものは除外")
check(RelatedFinder.matchesBundleID("COM.Example.Foo.plist", "com.example.foo"), "関連: 大文字小文字を区別しない")
// アンインストール（ダミー）
let target = AppCatalog.info(for: fooApp)!
let selected = rel.filter { $0.kind == .bundleID }
do {
    _ = try AppUninstaller.uninstall(app: InstalledApp(url: target.url, name: "x", bundleID: "com.apple.finder", version: "", size: 0, lastUsed: nil, isAppStore: false), related: [], isRunning: false, library: lib, appRoots: [apps])
    check(false, "Apple 製アプリは拒否")
} catch { check(fm.fileExists(atPath: fooApp.path), "Apple 製アプリは拒否") }
do { _ = try AppUninstaller.uninstall(app: target, related: [], isRunning: true, library: lib, appRoots: [apps]); check(false, "実行中は拒否") }
catch { check(fm.fileExists(atPath: fooApp.path), "実行中のアプリは拒否") }
let ur = try? AppUninstaller.uninstall(app: target, related: selected, isRunning: false, library: lib, appRoots: [apps])
check(ur?.failed.isEmpty == true && !fm.fileExists(atPath: fooApp.path)
      && !fm.fileExists(atPath: lib.appendingPathComponent("Application Support/com.example.foo").path)
      && fm.fileExists(atPath: lib.appendingPathComponent("Application Support/Foo").path)
      && fm.fileExists(atPath: lib.appendingPathComponent("Application Support/com.example.foobar").path), "アンインストール: 本体+選択分のみ移動、名前のみ/無関係は残る")
// 残骸
let lib2 = mk("lib2", dir: true)
for rel in ["Application Support/com.gone.app/a", "Application Support/com.example.bar/a", "Caches/com.example.bar.helper/a", "Application Support/com.apple.thing/a",
            "Application Support/PlainName/a", "Preferences/com.gone.pref.plist", "Containers/com.run.x/a", "Caches/com.example/a", "Application Support/com.gone.app2/a"] { _ = mk("lib2/\(rel)") }
let lo = Leftovers.find(library: lib2, installedIDs: ["com.example.bar"], runningIDs: ["com.run.x"]).map(\.url.lastPathComponent).sorted()
check(lo == ["com.gone.app", "com.gone.app2", "com.gone.pref.plist"], "残骸: 未インストールのID形式のみ(インストール済/実行中/Apple/非ID形式は除外)")
check(Leftovers.looksLikeBundleID("com.foo.bar") && !Leftovers.looksLikeBundleID("com.foo") && !Leftovers.looksLikeBundleID("Google") && !Leftovers.looksLikeBundleID("a..b"), "Bundle ID 形式判定")

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

try? fm.removeItem(at: work)
print("\n\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
