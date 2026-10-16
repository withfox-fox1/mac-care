import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String? = nil
    @State private var wakeBusy = false
    @State private var wakeError: String? = nil
    @State private var showIgnored = false
    @State private var showInstallHelp = false
    @State private var detailsOpen = false
    @State private var toolsOpen = false

    private var fullScanTime: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(hour: state.settings.fullScanHour, minute: state.settings.fullScanMinute)) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    state.settings.fullScanHour = c.hour ?? 0; state.settings.fullScanMinute = c.minute ?? 0
                })
    }

    // MARK: - 起床スケジュール（pmset。動作は従来どおり）

    /// pmset の起床スケジュールを設定/解除する（明示操作時のみ。管理者パスワードのプロンプトが出る）
    private func setWake(_ on: Bool) async {
        wakeBusy = true; defer { wakeBusy = false }
        wakeError = nil
        var s = Settings.load()
        let events = await WakeScheduler.currentEvents()
        let existing = WakeSchedule.classify(events, ourTime: s.wakeScheduleTime)
        if on {
            if case .foreign(let ev) = existing {
                let a = NSAlert()
                a.messageText = "既存の起床スケジュールを上書きしますか？"
                a.informativeText = "pmset の繰り返しスケジュールは 1 つしか持てません。現在の設定（\(ev.map { "\($0.kind) \($0.time) \($0.days)" }.joined(separator: ", "))）は上書きされます。"
                a.addButton(withTitle: "上書きする"); a.addButton(withTitle: "キャンセル")
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
            s.fullScanHour = state.settings.fullScanHour; s.fullScanMinute = state.settings.fullScanMinute
            if let err = await WakeScheduler.run(arguments: WakeSchedule.applyArguments(hour: s.fullScanHour, minute: s.fullScanMinute)) {
                wakeError = "起床スケジュールを設定できませんでした: \(err)"; return
            }
            s.wakeForScan = true
            s.wakeScheduleTime = WakeSchedule.wakeTime(hour: s.fullScanHour, minute: s.fullScanMinute)
        } else {
            // MacCare 以外の繰り返しスケジュールは解除しない
            if case .foreign = existing {
                wakeError = "MacCare 以外の起床スケジュールがあるため、pmset は変更せず MacCare 側の設定のみ解除しました。"
            } else if let err = await WakeScheduler.run(arguments: WakeSchedule.cancelArguments) {
                wakeError = "起床スケジュールを解除できませんでした: \(err)"; return
            }
            s.wakeForScan = false; s.wakeScheduleTime = nil
        }
        s.wakeSuggestionDismissed = true
        try? s.save()
        state.settings.wakeForScan = s.wakeForScan
        state.settings.wakeScheduleTime = s.wakeScheduleTime
        state.settings.wakeSuggestionDismissed = true
    }

    // MARK: - 既定値に戻す

    private func resetToDefaults() async {
        let ok = await Confirm.destructive(
            title: "設定を既定値に戻しますか？",
            message: "大きいファイルの基準、探す場所、自動チェックの有無と時刻、検査する場所など、この画面で変えられる項目を初期状態に戻します。\n無視リストと起床設定は変わりません。",
            button: "既定値に戻す", snapshot: ()) { _ in
            state.settings.resetEditableToDefaults()   // 変更は onChange でディスクへ保存される
        }
        _ = ok
    }

    // MARK: - 部品

    private func pickFolder(_ add: @escaping (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK { p.urls.forEach { add($0.path) } }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        CardView(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: "dff3f6"))
                body()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 見出し（太字）＋1 行の説明。管理者パスワードが必要な項目は lock で鍵アイコンを付ける。
    private func head(_ title: String, _ caption: String? = nil, lock: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if lock {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        .help("管理者パスワードが必要です").accessibilityLabel("管理者パスワードが必要")
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<T: View>(_ title: String, _ caption: String? = nil, lock: Bool = false, @ViewBuilder control: () -> T) -> some View {
        HStack(alignment: .center, spacing: 12) {
            head(title, caption, lock: lock)
            Spacer(minLength: 12)
            control()
        }
    }

    private func toggleRow(_ title: String, _ caption: String? = nil, lock: Bool = false, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        row(title, caption, lock: lock) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).disabled(disabled)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            Text(value).font(.callout).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder private func pathList(_ title: String, _ caption: String, _ binding: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row(title, caption) {
                Button("追加…") { pickFolder { p in if !binding.wrappedValue.contains(p) { binding.wrappedValue.append(p) } } }
                    .buttonStyle(.secondary)
            }
            ForEach(binding.wrappedValue, id: \.self) { p in
                HStack(spacing: 8) {
                    Image(systemName: p == NSHomeDirectory() ? "house.fill" : "folder.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(SettingsChoices.displayPath(p)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { binding.wrappedValue.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.secondary)
                        .accessibilityLabel("\(SettingsChoices.displayPath(p)) を一覧から外す")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.rowAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if binding.wrappedValue.isEmpty {
                Text("場所がありません。「追加…」で選んでください。").font(.caption).foregroundStyle(Theme.warn)
            }
        }
    }

    private func choicePicker(_ values: [Int], current: Binding<Int>, label: @escaping (Int) -> String, name: String) -> some View {
        Picker(name, selection: current) {
            ForEach(SettingsChoices.options(values, including: current.wrappedValue), id: \.self) { Text(label($0)).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    // MARK: - ツール未導入の警告（詳細に畳まず上部に出す）

    @ViewBuilder private var toolWarnings: some View {
        let missing = SettingsChoices.missingTools(state.tools)
        if !missing.isEmpty {
            CardView(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(missing, id: \.feature) { m in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(m.feature)に必要なツールが見つかりません").font(.system(size: 13, weight: .semibold))
                                Text("未導入: \(m.missing.joined(separator: "、"))").font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                        }
                    }
                    HStack {
                        Spacer()
                        Button("導入方法を見る") { showInstallHelp = true }.buttonStyle(.secondary)
                            .popover(isPresented: $showInstallHelp, arrowEdge: .bottom) { installHelp }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warn.opacity(0.45), lineWidth: 1))
        }
    }

    private var installHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ターミナルで次のコマンドを実行してください").font(.system(size: 13, weight: .semibold))
            Text("Homebrew が入っていない場合は、先に brew.sh の手順で導入します。").font(.caption).foregroundStyle(Theme.secondary)
            HStack {
                Text(Tools.installHint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("コピー") { copyInstallHint() }.buttonStyle(.secondary)
            }
            .padding(10).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("導入後、この画面を開き直すと反映されます。").font(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(16).frame(width: 420)
    }

    private func copyInstallHint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Tools.installHint, forType: .string)
    }

    // MARK: - アップデート

    private var updateCard: some View {
        let u = state.update
        return card("アップデート") {
            row("MacCare \(BuildInfo.version)", updateCaption(u)) {
                HStack(spacing: 8) {
                    if u.checking { ProgressView().controlSize(.small) }
                    Button("今すぐ確認") { Task { await u.check() } }.buttonStyle(.secondary).disabled(u.checking)
                    if case .available = u.state {
                        Button("アップデートする") { u.confirmAndStart() }.buttonStyle(.primary)
                    }
                }
            }
            switch u.state {
            case .available(let n, let commits):
                VStack(alignment: .leading, spacing: 4) {
                    Text("変更点").font(.system(size: 12, weight: .semibold))
                    ForEach(commits, id: \.hash) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.hash).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accentText)
                            Text(c.subject).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                    if n > commits.count { Text("ほか \(n - commits.count) 件").font(.caption).foregroundStyle(Theme.secondary) }
                }
            case .blocked(let m):
                Text(m).font(.caption).foregroundStyle(Theme.warn)
            case .unavailable(let m):
                Text(m).font(.caption).foregroundStyle(Theme.secondary)
            default: EmptyView()
            }
        }
    }

    private func updateCaption(_ u: UpdateModel) -> String {
        let when = u.lastCheck.map { "（\(ShortDate.format($0)) に確認）" } ?? ""
        switch u.state {
        case .unknown: return "まだ確認していません。"
        case .upToDate: return "✓ 最新です\(when)"
        case .available(let n, _): return "新しい版があります（\(n) 件の更新）\(when)"
        case .blocked: return "今は更新できません。"
        case .unavailable: return "更新を確認できませんでした。"
        }
    }

    // MARK: - 詳細情報

    private var detailsGroup: some View {
        let total = state.tools.count
        let ok = state.tools.filter(\.isAvailable).count
        return CardView(padding: 16) {
            DisclosureGroup(isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        row("使用している外部ツール", "MacCare が内部で使うコマンドです。") {
                            HStack(spacing: 6) {
                                if ok == total { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                                else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn) }
                                Text("\(ok)/\(total) 利用可能").font(.callout).foregroundStyle(Theme.secondary)
                            }
                        }
                        DisclosureGroup("ツールの一覧", isExpanded: $toolsOpen) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(state.tools) { t in
                                    HStack {
                                        Text(t.name).font(.callout)
                                        Spacer()
                                        if let p = t.path { Text(p).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled) }
                                        else { StatusBadge(kind: .warn, "未導入") }
                                    }
                                }
                                if ok < total {
                                    HStack {
                                        Text(Tools.installHint).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                        Spacer()
                                        Button("コピー") { copyInstallHint() }.buttonStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.callout)
                    }
                    ThemedDivider()
                    row("更新の仕組み", "GitHub から最新版を取り込み、アプリを作り直します。1 日 1 回、確認だけ自動で行います。") {
                        Button("ログをFinderで表示") { revealLog() }.buttonStyle(.secondary)
                    }
                    ThemedDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("バージョン詳細").font(.system(size: 13, weight: .semibold))
                        detailLine("バージョン", BuildInfo.version)
                        detailLine("ビルド", BuildInfo.commit ?? "不明")
                        detailLine("ソースの場所", BuildInfo.sourceDir ?? "不明")
                        detailLine("ログ", SelfUpdate.logURL.path)
                    }
                }
                .padding(.top, 12)
            } label: {
                head("詳細情報", "トラブル時に使います。")
            }
        }
    }

    private func detailLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer()
        }
    }

    private func revealLog() {
        let url = SelfUpdate.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? Storage.ensureDir()
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - 本体

    var body: some View {
        @Bindable var st = state
        PaneScaffold(item: .settings, subtitle: "変更は自動で保存されます。", framed: false) {
            Button("既定値に戻す…") { Task { await resetToDefaults() } }.buttonStyle(.secondary)
        } content: {
            ScrollView {
                VStack(spacing: 14) {
                    card("一般") {
                        toggleRow("ログイン時に MacCare を開く", "Mac を起動してログインすると、自動で MacCare が立ち上がります。",
                                  isOn: Binding(get: { launchAtLogin }, set: { on in
                            do { try LaunchAtLogin.set(on); launchError = nil } catch { launchError = "\(error.localizedDescription)" }
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }))
                        if let e = launchError { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                    }
                    card("自動チェック") {
                        toggleRow("毎日自動でチェックする", "ゴミ・脅威・ログイン項目をまとめて調べます。何も削除しません。",
                                  isOn: $st.settings.scheduledScanEnabled)
                        row("実行時刻", "スリープ中だった場合は、次に使い始めたときに実行します。") {
                            DatePicker("実行時刻", selection: fullScanTime, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                        toggleRow("スリープ中でも起こして実行する",
                                  "設定時に Mac のパスワードを求められます。実行の \(WakeSchedule.leadMinutes) 分前に起こします。",
                                  lock: true,
                                  isOn: Binding(get: { state.settings.wakeForScan }, set: { on in Task { await setWake(on) } }),
                                  disabled: wakeBusy)
                        if state.settings.wakeForScan, let t = state.settings.wakeScheduleTime,
                           t != WakeSchedule.wakeTime(hour: st.settings.fullScanHour, minute: st.settings.fullScanMinute) {
                            HStack {
                                Text("起こす時刻（\(t)）が実行時刻とずれています").font(.caption).foregroundStyle(Theme.warn)
                                Spacer()
                                Button("実行時刻に合わせる") { Task { await setWake(true) } }.buttonStyle(.secondary).disabled(wakeBusy)
                            }
                        }
                        if let e = wakeError { Text(e).font(.caption).foregroundStyle(Theme.warn) }
                        ThemedDivider()
                        infoRow("前回の自動チェック", st.settings.lastScheduledRun.map { ShortDate.format($0) } ?? "まだありません")
                        infoRow("前回の全体検査", state.security.lastFullAt.map { ShortDate.format($0) } ?? "まだありません")
                    }
                    toolWarnings
                    card("容量") {
                        row("大きいファイルとみなすサイズ", "これ以上のファイルを「大容量ファイル」に一覧表示します。") {
                            choicePicker(SettingsChoices.thresholdMB, current: $st.settings.largeFileThresholdMB,
                                         label: { SettingsChoices.sizeLabel(mb: $0) }, name: "大きいファイルとみなすサイズ")
                        }
                        pathList("探す場所", "大きいファイルを探すフォルダです。", $st.settings.largeFileRoots)
                        row("古い開発用フォルダとみなす日数", "プログラミングをしない方は変更不要です。") {
                            choicePicker(SettingsChoices.staleDays, current: $st.settings.nodeModulesStaleDays,
                                         label: { SettingsChoices.daysLabel($0) }, name: "古い開発用フォルダとみなす日数")
                        }
                    }
                    card("セキュリティ") {
                        pathList("検査する場所", "ウイルスや不審なファイルを調べるフォルダです。", $st.settings.scanTargets)
                        toggleRow("時間をかけて念入りに検査する", "アプリケーションフォルダも含めて調べます。時間が長くなります。",
                                  isOn: $st.settings.deepScan)
                        row("無視している検出 \(st.settings.ignoredDetections.count) 件", "問題なしと判断して、警告から外したファイルです。") {
                            Button("管理…") { showIgnored = true }.buttonStyle(.secondary)
                        }
                    }
                    updateCard
                    detailsGroup
                }
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showIgnored) { IgnoredManageSheet().environment(state) }
        .onAppear { state.refresh(); launchAtLogin = LaunchAtLogin.isEnabled }
        .onChange(of: state.settings) { _, new in
            var disk = Settings.load()
            disk.mergeEditable(from: new)
            try? disk.save()
        }
    }
}

/// 無視リストの管理。解除は確認なしで即保存する（警告が再び出るだけの安全側の操作）。
struct IgnoredManageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var items: [IgnoredDetection] = []
    @State private var error: String? = nil

    private func remove(_ item: IgnoredDetection) {
        var disk = Settings.load()
        disk.removeIgnored(item)
        do {
            try disk.save()
            error = nil
            items = disk.ignoredDetections
            state.settings.ignoredDetections = disk.ignoredDetections
        } catch {
            self.error = "保存できませんでした: \(error.localizedDescription)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("無視している検出").font(.system(size: 17, weight: .heavy))
            Text("無視をやめると、次回の検査からそのファイルが再び警告の対象になります。")
                .font(.callout).foregroundStyle(Theme.secondary)
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                    Text("無視している検出はありません").font(.system(size: 13, weight: .semibold))
                    Text("検査結果で「無視」を選んだファイルが、ここに並びます。").font(.caption).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items, id: \.path) { it in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((it.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(it.path).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Button("無視をやめる") { remove(it) }.buttonStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.rowAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(Theme.warn) }
            HStack { Spacer(); Button("閉じる") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 540)
        .background(ThemedBackground())
        .oceanScheme()
        .onAppear { items = Settings.load().ignoredDetections }
    }
}
