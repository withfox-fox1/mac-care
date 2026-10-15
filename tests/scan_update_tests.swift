import Foundation

private func git(_ dir: String, _ args: [String]) -> String {
    await_sync {
        let r = try? await Shell.run("/usr/bin/git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
        return (r?.stdout ?? "") + (r?.stderr ?? "")
    }
}

func scanUpdateTests() {
    // --- 自己アップデート: 解析・判定 ---
    check(SelfUpdate.parseCount(" 3\n") == 3 && SelfUpdate.parseCount("x") == nil && SelfUpdate.parseCount("") == nil, "更新: rev-list 件数の解析")
    let logs = SelfUpdate.parseLog("abc1234 Fix: a b\n\ndef5678 second commit\nonlyhash\n")
    check(logs == [UpdateCommit(hash: "abc1234", subject: "Fix: a b"), UpdateCommit(hash: "def5678", subject: "second commit"), UpdateCommit(hash: "onlyhash", subject: "")], "更新: git log --oneline の解析")
    check(SelfUpdate.parseLog((1...30).map { "h\($0) s" }.joined(separator: "\n")).count == 10, "更新: コミット一覧は最大10件")
    check(SelfUpdate.decide(RepoFacts(isRepo: false)) == .unavailable("ソースフォルダが git リポジトリではありません。"), "更新: リポジトリでなければ確認不可")
    check(SelfUpdate.decide(RepoFacts()) == .upToDate, "更新: 差分なしは最新")
    check(SelfUpdate.decide(RepoFacts(dirty: true)) == .upToDate, "更新: 最新なら作業ツリーが汚れていても最新と表示")
    let cm = [UpdateCommit(hash: "a", subject: "s")]
    check(SelfUpdate.decide(RepoFacts(behind: 2, commits: cm)) == .available(count: 2, commits: cm), "更新: 遅れていれば更新あり")
    if case .blocked = SelfUpdate.decide(RepoFacts(dirty: true, behind: 1)) { check(true, "更新: 作業ツリーに変更があれば拒否") } else { check(false, "更新: 作業ツリーに変更があれば拒否") }
    if case .blocked = SelfUpdate.decide(RepoFacts(behind: 1, ahead: 1)) { check(true, "更新: 分岐していれば拒否") } else { check(false, "更新: 分岐していれば拒否") }
    if case .blocked = SelfUpdate.decide(RepoFacts(ahead: 2)) { check(true, "更新: HEAD が先行していれば拒否") } else { check(false, "更新: HEAD が先行していれば拒否") }
    if case .blocked = SelfUpdate.decide(RepoFacts(branch: "feature", behind: 1)) { check(true, "更新: main 以外のブランチは拒否") } else { check(false, "更新: main 以外のブランチは拒否") }
    let now0 = Date(timeIntervalSince1970: 1_800_000_000)
    check(SelfUpdate.isCheckDue(last: nil, now: now0) && !SelfUpdate.isCheckDue(last: now0.addingTimeInterval(-86399), now: now0)
          && SelfUpdate.isCheckDue(last: now0.addingTimeInterval(-86400), now: now0) && SelfUpdate.isCheckDue(last: now0.addingTimeInterval(60), now: now0), "更新: 1日1回の自動確認の判定")
    check(await_sync { await SelfUpdate.check(dir: nil) } == .unavailable("ソースフォルダの情報がありません。install.sh でビルドしたアプリのみ更新できます。"), "更新: ソース未設定は確認不可")
    let nogit = mk("upd/nogit", dir: true)
    if case .unavailable = await_sync({ await SelfUpdate.check(dir: nogit.path) }) { check(true, "更新: git リポジトリでないフォルダは確認不可") } else { check(false, "更新: git リポジトリでないフォルダは確認不可") }
    if case .unavailable = await_sync({ await SelfUpdate.check(dir: work.path + "/nonexistent") }) { check(true, "更新: 存在しないフォルダは確認不可") } else { check(false, "更新: 存在しないフォルダは確認不可") }

    // 起動後の結果判定
    let pend = SelfUpdate.Pending(fromCommit: "aaa", startedAt: now0)
    check(SelfUpdate.evaluate(pending: pend, currentCommit: "bbb", log: "", now: now0) == .success("bbb"), "更新結果: コミットが変われば成功")
    check(SelfUpdate.evaluate(pending: pend, currentCommit: "aaa", log: "x\nMACCARE_UPDATE_EXIT=1\n", now: now0) != .none, "更新結果: 終了コード非0は失敗")
    check(SelfUpdate.evaluate(pending: pend, currentCommit: "aaa", log: "building…", now: now0.addingTimeInterval(60)) == .none, "更新結果: 進行中は保留")
    if case .failed = SelfUpdate.evaluate(pending: pend, currentCommit: "aaa", log: "building…", now: now0.addingTimeInterval(16 * 60)) { check(true, "更新結果: 長時間完了しなければ失敗") } else { check(false, "更新結果: 長時間完了しなければ失敗") }

    // 実リポジトリではなく一時リポジトリで fetch/比較/切り離し更新を検証
    let o = mk("upd/origin.git", dir: true).path
    _ = git(o, ["init", "--bare", "-b", "main"])
    let w1 = mk("upd/w1", dir: true).path
    _ = git(w1, ["init", "-b", "main"]); _ = git(w1, ["remote", "add", "origin", o])
    try! "#!/bin/sh\necho installed > installed.marker\n".write(toFile: w1 + "/install.sh", atomically: true, encoding: .utf8)
    _ = git(w1, ["add", "."]); _ = git(w1, ["commit", "-m", "first"]); _ = git(w1, ["push", "-u", "origin", "main"])
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w1 + "/install.sh")
    _ = git(w1, ["update-index", "--chmod=+x", "install.sh"]); _ = git(w1, ["commit", "-m", "make exec"]); _ = git(w1, ["push", "origin", "main"])
    let w2 = work.appendingPathComponent("upd/w2").path
    _ = git(work.path, ["clone", o, w2])
    check(await_sync { await SelfUpdate.check(dir: w2) } == .upToDate, "更新(一時リポジトリ): 同一なら最新")
    try! "x".write(toFile: w1 + "/new.txt", atomically: true, encoding: .utf8)
    _ = git(w1, ["add", "."]); _ = git(w1, ["commit", "-m", "add: new file"]); _ = git(w1, ["push", "origin", "main"])
    let st1 = await_sync { await SelfUpdate.check(dir: w2) }
    if case .available(let n, let c) = st1 { check(n == 1 && c.first?.subject == "add: new file", "更新(一時リポジトリ): 更新あり1件とコミット一覧") } else { check(false, "更新(一時リポジトリ): 更新あり1件とコミット一覧 \(st1)") }
    try! "dirty".write(toFile: w2 + "/install.sh.local", atomically: true, encoding: .utf8)
    if case .blocked = await_sync({ await SelfUpdate.check(dir: w2) }) { check(true, "更新(一時リポジトリ): 未追跡の変更があれば拒否") } else { check(false, "更新(一時リポジトリ): 未追跡の変更があれば拒否") }
    try? fm.removeItem(atPath: w2 + "/install.sh.local")
    let logU = work.appendingPathComponent("upd/update.log"), pendU = work.appendingPathComponent("upd/pending.json")
    do { try SelfUpdate.startUpdate(dir: w2, log: logU, pending: pendU, fromCommit: "old") } catch { check(false, "更新: 起動に失敗 \(error)") }
    var logText = ""
    for _ in 0..<100 {
        logText = (try? String(contentsOf: logU, encoding: .utf8)) ?? ""
        if logText.contains("MACCARE_UPDATE_EXIT=") { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    check(logText.contains("MACCARE_UPDATE_EXIT=0") && fm.fileExists(atPath: w2 + "/installed.marker") && fm.fileExists(atPath: w2 + "/new.txt"),
          "更新: pull → install.sh を切り離して実行しログに記録")
    check(SelfUpdate.loadPending(pendU)?.fromCommit == "old", "更新: 保留情報(更新前コミット)を保存")
    check(await_sync { await SelfUpdate.check(dir: w2) } != .unknown, "更新(一時リポジトリ): 更新後に再確認できる")

    // --- ファイル一覧 ---
    let sd = mk("scan/d", dir: true)
    _ = mk("scan/d/a.txt"); _ = mk("scan/d/sub/b.bin"); _ = mk("scan/d/.hidden"); _ = mk("scan/d/Pkg.app/Contents/c")
    try? fm.createSymbolicLink(at: sd.appendingPathComponent("link"), withDestinationURL: sd.appendingPathComponent("a.txt"))
    let big = sd.appendingPathComponent("big.dat")
    fm.createFile(atPath: big.path, contents: Data(count: 5000))
    let en = ScanFileList.enumerate(sd)
    let names = Set(en.files.map { ($0.path as NSString).lastPathComponent })
    check(names == ["a.txt", "b.bin", ".hidden", "c", "big.dat"], "一覧: 隠しファイル・パッケージ内を含み、シンボリックリンクは含まない")
    check(en.files.first { $0.path.hasSuffix("big.dat") }?.size == 5000, "一覧: サイズを取得")
    let inv = ScanFileList.build(yaraTargets: [sd, mk("scan/e", dir: true)], clamTargets: [sd], clamMax: 4000)
    check(inv.yara.count == 5 && inv.clam.count == 4 && inv.clamOverLimit.map { ($0.path as NSString).lastPathComponent } == ["big.dat"], "一覧: ClamAV 上限超は YARA のみ(スキップせず区別)")
    let single = ScanFileList.enumerate(sd.appendingPathComponent("a.txt"))
    check(single.files.count == 1, "一覧: ファイル単体の対象")
    check(ScanFileList.enumerate(sd.appendingPathComponent("none")).files.isEmpty, "一覧: 存在しない対象は空")
    let ch = ScanFileList.chunks((0..<10).map { ScanFile(path: "/p\($0)", size: 100, mtime: 0, inode: 0) }, maxBytes: 350, maxCount: 100)
    check(ch.map(\.count) == [3, 3, 3, 1], "一覧: バイト数で塊に分割")
    check(ScanFileList.chunks([ScanFile(path: "/huge", size: 9_999, mtime: 0, inode: 0)], maxBytes: 10, maxCount: 5).count == 1 && ScanFileList.chunks([]).isEmpty, "一覧: 巨大ファイルは単独の塊、空は空")

    // --- キャッシュ ---
    func sf(_ p: String, _ size: Int64 = 10, _ mt: Int64 = 1, _ ino: UInt64 = 1) -> ScanFile { ScanFile(path: p, size: size, mtime: mt, inode: ino) }
    let t1 = Date(timeIntervalSince1970: 1_800_000_000)
    let files = [sf("/a"), sf("/b"), sf("/c")]
    let c0 = ScanCache.merge(files: files, previous: [:], quick: false, clean: ["/a", "/b"], now: t1)
    check(Set(c0.keys) == ["/a", "/b"], "キャッシュ: 問題なしのファイルだけ記録(検出・エラーは記録しない)")
    let pFull = ScanCache.plan(files: files, cache: c0, quick: false)
    check(pFull.toScan.count == 3 && pFull.hits == 0, "キャッシュ: フルは常に全件検査")
    var changed = files; changed[0] = sf("/a", 11); changed[1] = sf("/b", 10, 2); changed.append(sf("/d")); changed[2] = sf("/c", 10, 1, 9)
    let pq = ScanCache.plan(files: changed, cache: c0, quick: true)
    check(pq.hits == 0 && pq.toScan.count == 4, "キャッシュ: サイズ/更新時刻/inode が変われば再検査、新規も検査")
    let pq2 = ScanCache.plan(files: files, cache: c0, quick: true)
    check(pq2.hits == 2 && pq2.toScan.map(\.path) == ["/c"] && pq2.oldestHit == t1 && abs(pq2.hitRate - 2.0 / 3.0) < 1e-9 && pq2.hitBytes == 20, "キャッシュ: 未変更はスキップ(命中2/3)・最古の検査時刻")
    let t2 = t1.addingTimeInterval(3600)
    let c1 = ScanCache.merge(files: [sf("/a"), sf("/c")], previous: c0, quick: true, clean: ["/c"], now: t2)
    check(Set(c1.keys) == ["/a", "/c"] && c1["/a"]?.scannedAt == Int64(t1.timeIntervalSince1970) && c1["/c"]?.scannedAt == Int64(t2.timeIntervalSince1970), "キャッシュ: 命中分は元の検査時刻を維持し、消えたファイルは落とす")
    let c2 = ScanCache.merge(files: [sf("/a")], previous: c0, quick: false, clean: [], now: t2)
    check(c2.isEmpty, "キャッシュ: フルで問題なしと確認できなかったファイルは残さない")
    var store = ScanCacheStore(); store.clam = c0; store.lastFullAt = t1
    store.save()
    check(ScanCacheStore.load() == store, "キャッシュ: JSON の保存→読込が一致")
    try! "broken".write(to: ScanCacheStore.url, atomically: true, encoding: .utf8)
    check(ScanCacheStore.load() == ScanCacheStore(), "キャッシュ: 破損時は空(=全件検査)")

    // --- clamscan / yara 出力 ---
    check(ClamLine.parse("/tmp/a b/c.txt: OK") == .ok("/tmp/a b/c.txt"), "clamscan行: OK")
    check(ClamLine.parse("/tmp/x: y: z.bin: Win.Test.EICAR_HDB-1 FOUND") == .found(path: "/tmp/x: y: z.bin", signature: "Win.Test.EICAR_HDB-1"), "clamscan行: パスに ': ' を含む FOUND")
    check(ClamLine.parse("/tmp/p: q/f: OK") == .ok("/tmp/p: q/f"), "clamscan行: パスに ': ' を含む OK")
    check(ClamLine.parse("/priv/f: Access denied. ERROR") == .error(path: "/priv/f", message: "Access denied."), "clamscan行: ERROR")
    check(ClamLine.parse("LibClamAV Warning: foo") == .other && ClamLine.parse("") == .other && ClamLine.parse("/e: Empty file") == .other, "clamscan行: その他は無視")
    check(YaraErrors.unreadable("error scanning /a b/c: d.txt: could not open file\nwarning: x\nerror scanning /z: could not open file\n") == ["/a b/c: d.txt", "/z"], "yara stderr: 読み取れなかったパス")
    check(ClamEngine.parseSigtoolVersion("File: x\nBuild time: y\nVersion: 28153\nSignatures: 3\n") == "28153" && ClamEngine.parseSigtoolVersion("none") == nil, "sigtool: 定義バージョンの解析")
    check(ClamEngine.limitArgs.allSatisfy { $0.hasSuffix("=2147483647") } && ClamEngine.limitArgs.count == 3, "ClamAV: サイズ上限を libclamav の最大まで引き上げる")

    // --- 進捗・残り時間 ---
    check(abs(ProgressMath.weighted([(weight: 1, fraction: 1), (weight: 3, fraction: 0)]) - 0.25) < 1e-9 && ProgressMath.weighted([]) == 0
          && ProgressMath.weighted([(weight: 0, fraction: 1)]) == 0 && ProgressMath.weighted([(weight: 2, fraction: 5)]) == 1, "進捗: 重み付き平均と範囲")
    let st0 = Date(timeIntervalSince1970: 1_000)
    var mt = ProgressMeter(startedAt: st0)
    check(mt.update(fraction: 0.5, now: st0.addingTimeInterval(3)) == nil, "残り時間: 最初の数秒は計算中(nil)")
    check(mt.update(fraction: 0.001, now: st0.addingTimeInterval(10)) == nil, "残り時間: 進捗がほぼ0なら計算中")
    let r1 = mt.update(fraction: 0.25, now: st0.addingTimeInterval(60))
    check(r1.map { abs($0 - 180) < 1e-6 } == true, "残り時間: 経過/進捗から算出(60秒で25% → 残り180秒)")
    let r2 = mt.update(fraction: 0.5, now: st0.addingTimeInterval(120))   // 生の推定=120。平滑化で 180→156
    check(r2.map { abs($0 - (180 * 0.7 + 120 * 0.3)) < 1e-6 } == true, "残り時間: 指数移動平均で平滑化")
    check(mt.update(fraction: 1, now: st0.addingTimeInterval(200)) == 0, "残り時間: 完了で0")
    check(ETAFormat.text(nil) == "残り時間を計算中…" && ETAFormat.text(40) == "残り 40秒" && ETAFormat.text(42) == "残り 40秒" && ETAFormat.text(2) == "まもなく完了"
          && ETAFormat.text(180) == "残り 約3分" && ETAFormat.text(200) == "残り 約3分" && ETAFormat.text(3600) == "残り 約1時間" && ETAFormat.text(5400) == "残り 約1時間30分", "残り時間の表記")
    check(ETAFormat.percent(0.426) == "43%" && ETAFormat.percent(2) == "100%" && ETAFormat.percent(-1) == "0%", "進捗: パーセント表記")
    let bp = ByteProgress(); bp.reset(total: 200); bp.add(50)
    check(bp.fraction == 0.25, "ByteProgress: 処理バイト/総バイト")
    bp.finish(); check(bp.fraction == 1, "ByteProgress: 完了で100%")
    let bz = ByteProgress(); bz.reset(total: 0); check(bz.fraction == 0, "ByteProgress: 対象0件でも完了前は0%"); bz.finish(); check(bz.fraction == 1, "ByteProgress: 対象0件は完了で100%")
    let col = ClamCollector(sizes: ["/a": 100, "/b": 300], progress: { let p = ByteProgress(); p.reset(total: 400); return p }())
    col.handle("/a: OK"); col.handle("/b: Eicar-Signature FOUND"); col.handle("/zzz: OK"); col.handle("/q: Access denied. ERROR")
    let co = col.outcome
    check(co.clean == ["/a", "/zzz"] && co.hits.count == 1 && co.hits[0].path == "/b" && co.errors == 1, "ClamCollector: OK/FOUND/ERROR を集計")
    StepDurations.save(["security": 300, "cleanup": 0])
    let sdur = StepDurations.load()
    check(sdur["security"] == 300 && sdur["cleanup"] == StepDurations.defaults["cleanup"] && sdur["largeFiles"] == StepDurations.defaults["largeFiles"], "進捗の重み: 前回の所要時間を使い、欠けは既定値")
    var jc = Calendar(identifier: .gregorian); jc.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let fnow = jc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
    check(FullScanLabel.text(jc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 0, minute: 3)), now: fnow, calendar: jc) == "前回のフルスキャン: 今日 00:03"
          && FullScanLabel.text(nil, now: fnow, calendar: jc) == "前回のフルスキャン: 未実施", "表示: 前回のフルスキャン")

    // --- 起床スケジュール(pmset) ---
    check(WakeSchedule.wakeTime(hour: 0, minute: 0) == "23:58:00" && WakeSchedule.wakeTime(hour: 3, minute: 30) == "03:28:00" && WakeSchedule.wakeTime(hour: 0, minute: 1) == "23:59:00", "pmset: 起床時刻は2分前(日跨ぎ対応)")
    check(WakeSchedule.applyArguments(hour: 0, minute: 0) == ["repeat", "wake", "MTWRFSU", "23:58:00"] && WakeSchedule.cancelArguments == ["repeat", "cancel"], "pmset: コマンド引数")
    check(WakeSchedule.appleScript(arguments: WakeSchedule.applyArguments(hour: 0, minute: 0)) == "do shell script \"/usr/bin/pmset repeat wake MTWRFSU 23:58:00\" with administrator privileges", "pmset: AppleScript の組み立て")
    let noRep = "Scheduled power events:\n [0]  wake at 10/15/2026 17:37:30 by 'com.apple.alarm.user-invisible-x'\n"
    check(WakeSchedule.parseRepeating(noRep).isEmpty && WakeSchedule.classify([], ourTime: nil) == .none, "pmset -g sched: 繰り返しなし(単発のみ)は無視")
    let rep = "Repeating power events:\n  wakepoweron at 11:58PM every day\nScheduled power events:\n [0]  wake at 10/15/2026 17:37:30 by 'x'\n"
    let evs = WakeSchedule.parseRepeating(rep)
    check(evs == [WakeSchedule.RepeatingEvent(kind: "wakepoweron", time: "23:58:00", days: "every day")], "pmset -g sched: 繰り返しイベントの解析")
    check(WakeSchedule.classify(evs, ourTime: "23:58:00") == .ours && WakeSchedule.classify(evs, ourTime: "03:28:00") == .foreign(evs) && WakeSchedule.classify(evs, ourTime: nil) == .foreign(evs), "pmset: 自分の設定か他の設定かを判別")
    let evs2 = WakeSchedule.parseRepeating("Repeating power events:\n  shutdown at 6:00PM weekdays\n  wake at 8:30AM weekdays\n")
    check(evs2.count == 2 && evs2[0].time == "18:00:00" && evs2[1].time == "08:30:00" && WakeSchedule.classify(evs2, ourTime: "08:30:00") != .ours, "pmset: 複数イベントがあれば他の設定扱い")
    check(WakeSchedule.normalize("12:00AM") == "00:00:00" && WakeSchedule.normalize("12:30PM") == "12:30:00" && WakeSchedule.normalize("junk") == nil, "pmset: 時刻表記の正規化")
    let sg = SleepGuard(reason: "MacCare test"); check(sg.isActive, "電源アサーション: 取得できる"); sg.release(); check(!sg.isActive, "電源アサーション: 解放できる")

    // --- 推奨 ---
    var ri = RecommendationInput(now: now0); ri.lastSmartCare = now0
    ri.updateAvailable = 2; ri.wakeSuggested = true
    let rall = Recommendations.all(ri)
    check(rall.map(\.kind) == [.appUpdate, .wakeSchedule] && rall[0].title == "MacCare のアップデートがあります" && rall[0].action == .navigate("settings"), "おすすめ: アップデートと起床スケジュールの提案")
}
