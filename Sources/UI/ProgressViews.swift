import SwiftUI
import AppKit

/// 進捗バー（Ocean テーマのアクセントグラデーション）
struct ScanProgressBar: View {
    let fraction: Double
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(Theme.accentGradient)
                    .frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("進捗")
        .accessibilityValue(ETAFormat.percent(fraction))
    }
}

/// 進捗バー＋「42%・残り 約3分」＋現在のステップ
struct ScanProgressBlock: View {
    let fraction: Double
    let etaText: String
    let stepText: String
    var detailText: String = ""
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ETAFormat.percent(fraction)).font(.system(size: 20, weight: .heavy)).monospacedDigit()
                Text(etaText).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            ScanProgressBar(fraction: fraction)
            Text(stepText).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            if !detailText.isEmpty {
                Text(detailText).font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.85)).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 更新結果などのお知らせバナー
struct NoticeBanner: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.warn : Theme.ok)
            Text(text).font(.system(size: 12.5, weight: .semibold)).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 8)
            if state.trashNoticeText == text {
                Button("ゴミ箱を開く") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                }.buttonStyle(.secondary).fixedSize()
            }
            Button("閉じる", action: dismiss).buttonStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // 下の内容が透けないよう、不透明の下地の上に色を重ねる
        .background(Theme.bannerBase, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background((isError ? Theme.warn : Theme.ok).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((isError ? Theme.warn : Theme.ok).opacity(0.35), lineWidth: 1))
    }
}
