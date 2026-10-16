import SwiftUI
import AppKit

/// 履歴画面: 集計カード・絞り込み・日付ごとの一覧（行を押すと内訳と詳細を展開）
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var rows: [HistoryRow] = []
    @State private var stats = HistoryStats(totalFreed: 0, monthFreed: 0, scanCount: 0, failureCount: 0)
    @State private var filter: HistoryFilter = .all
    @State private var expanded: Set<String> = []

    private let calendar = Calendar.current

    private func rebuild() {
        let now = Date()
        // state.history は新しい順なので、記録順に戻してから渡す
        rows = HistoryGrouping.rows(from: Array(state.history.reversed()))
        stats = HistoryGrouping.stats(rows, now: now, calendar: calendar)
    }

    var body: some View {
        PaneScaffold(item: .history, subtitle: "実行した掃除・圧縮・スキャン・削除の記録です。", framed: false) { EmptyView() } content: {
            if rows.isEmpty {
                CardView(padding: 0) {
                    EmptyStateView(symbol: "clock.arrow.circlepath", color: Theme.secondary, message: "履歴はまだありません") { EmptyView() }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    statCards
                    filterBar
                    list
                }
            }
        }
        .onAppear { state.refresh(); rebuild() }
        .onChange(of: state.history) { rebuild() }
    }

    // MARK: 集計カード

    private var statCards: some View {
        let monthLabel = "\(calendar.component(.month, from: Date()))月"
        return HStack(spacing: 10) {
            StatCard(title: "空けた容量（累計）", value: formatBytes(stats.totalFreed), caption: "ゴミ箱を空にした分は含みません", tint: Theme.cleanup)
            StatCard(title: "今月の空けた容量", value: formatBytes(stats.monthFreed), caption: monthLabel, tint: Theme.accentText)
            StatCard(title: "スキャン回数", value: "\(stats.scanCount) 回", caption: "スマートケア内の検査は 1 回", tint: Theme.security)
            StatCard(title: "失敗件数", value: "\(stats.failureCount) 件", caption: "一部失敗を含む",
                     tint: stats.failureCount > 0 ? Theme.danger : Theme.secondary)
        }
    }

    // MARK: 絞り込み

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(HistoryFilter.allCases) { f in
                Button { filter = f } label: {
                    Text(f.title)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(filter == f ? Theme.teal.opacity(0.28) : Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().strokeBorder(filter == f ? Theme.teal.opacity(0.7) : Theme.cardBorder, lineWidth: 1))
                        .foregroundStyle(filter == f ? Theme.accentText : Theme.secondary)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == f ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 一覧

    private var list: some View {
        let now = Date()
        let shown = rows.filter { filter.matches($0.kind) }
        let sections = HistoryGrouping.sections(shown, now: now, calendar: calendar)
        return CardView(padding: 0) {
            if sections.isEmpty {
                Text("該当する履歴はありません").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { sec in
                            Text(sec.title)
                                .font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.accentText)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                            ForEach(sec.rows) { row in
                                HistoryRowView(row: row, calendar: calendar, isExpanded: expanded.contains(row.id)) {
                                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                                }
                                ThemedDivider().opacity(0.6)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color
    var body: some View {
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.system(size: 10.5)).foregroundStyle(Theme.secondary.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 行

private struct HistoryRowView: View {
    let row: HistoryRow
    let calendar: Calendar
    let isExpanded: Bool
    let toggle: () -> Void

    private var symbol: String {
        switch row.kind {
        case .cleanup: row.isEmptyTrash ? "trash.fill" : SidebarItem.cleanup.symbol
        case .trash: "trash.fill"
        case .compress: SidebarItem.compress.symbol
        case .scan: SidebarItem.security.symbol
        case .uninstall: SidebarItem.apps.symbol
        case .loginItem: SidebarItem.loginItems.symbol
        }
    }
    private var tint: Color {
        switch row.kind {
        case .cleanup, .trash: Theme.cleanup
        case .compress: Theme.video
        case .scan: Theme.security
        case .uninstall: Theme.apps
        case .loginItem: Theme.loginItems
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { header }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "詳細を閉じる" : "詳細を表示")
            if isExpanded { HistoryDetailView(row: row, calendar: calendar).padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 12) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
                if let s = row.subtitle {
                    Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            StatusBadge(kind: badgeKind, row.resultLabel).lineLimit(1).fixedSize()
            VStack(alignment: .trailing, spacing: 2) {
                if let o = row.overview {
                    Text(o).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                } else if let f = HistoryFormat.freed(row.freedBytes) {
                    Text(f).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                } else {
                    Text("—").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                Text(HistoryFormat.time(row.date, calendar: calendar)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .frame(width: 140, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var badgeKind: BadgeKind {
        switch row.outcome {
        case .success: .ok
        case .failure, .threat: .danger
        case .partial: .warn
        case .info: .info
        }
    }
}

// MARK: - 展開部

private struct HistoryDetailView: View {
    let row: HistoryRow
    let calendar: Calendar
    private let maxChildren = 200

    private func badgeKind(_ o: HistoryOutcome) -> BadgeKind {
        switch o { case .success: .ok; case .failure, .threat: .danger; case .partial: .warn; case .info: .info }
    }

    private func line(_ label: String, _ value: String, path: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                .lineLimit(path ? 1 : 4).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("日時", HistoryFormat.dateTime(row.date, calendar: calendar))
            if let out = row.outputPath { line("出力先", out, path: true) }
            if let src = row.sourcePath, row.kind != .compress { line("対象", src, path: true) }
            if let sec = row.seconds { line("所要時間", ShortDate.duration(Double(sec))) }
            if row.outputPath == nil, !row.detail.isEmpty { line("詳細", row.detail) }
            if let out = row.outputPath, FileManager.default.fileExists(atPath: out) {
                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)]) }
                    .buttonStyle(.secondary).fixedSize().padding(.top, 2)
            }
            if !row.children.isEmpty {
                Text(row.childrenAreItems ? "内訳（\(row.children.count) 件）" : "関連する記録")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(row.children.prefix(maxChildren).enumerated()), id: \.offset) { i, c in
                        childRow(c).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(i % 2 == 1 ? Theme.rowAlt : Color.clear)
                    }
                    if row.children.count > maxChildren {
                        Text("ほか \(row.children.count - maxChildren) 件").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                }
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.top, 2)
    }

    private func childRow(_ c: HistoryChild) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if !c.detail.isEmpty {
                    Text(c.detail).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let b = c.bytes {
                Text(formatBytes(b)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            }
            StatusBadge(kind: badgeKind(c.outcome), c.resultLabel).lineLimit(1).fixedSize()
        }
    }
}
