import SwiftUI
import AppKit

// MARK: - Ocean テーマ（常にダーク）

extension Color {
    /// "#rrggbb" / "rrggbb"
    init(hex: String, opacity: Double = 1) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255, opacity: opacity)
    }
}

extension Color {
    /// 白に近づけた色（macOS 14 には Color.mix がないため NSColor で混色）
    func lightened(_ fraction: CGFloat) -> Color {
        let ns = NSColor(self)
        return Color(nsColor: ns.blended(withFraction: fraction, of: .white) ?? ns)
    }
}

enum Theme {
    static let text = Color(hex: "eaf6f8")
    /// 補助文字色。紺の背景（最も明るい部分でも約 6:1）に対して 4.5:1 以上を確保
    static let secondary = Color(hex: "b4d3dd")
    static let accentText = Color(hex: "5eead4")
    static let ok = Color(hex: "4ade80")
    static let warn = Color(hex: "fbbf24")
    static let danger = Color(hex: "f87171")
    static let info = Color(hex: "38bdf8")
    static let teal = Color(hex: "14b8a6")
    static let blue = Color(hex: "3b82f6")
    static let cardFill = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.10)
    /// お知らせバナーの不透明な下地（背景グラデーションに近い色）
    static let bannerBase = Color(hex: "0b2a3d")
    static let rowAlt = Color.white.opacity(0.035)
    static let accentGradient = LinearGradient(colors: [teal, blue], startPoint: .leading, endPoint: .trailing)
    static let ringGradient = LinearGradient(colors: [accentText, info], startPoint: .leading, endPoint: .trailing)

    // 機能ごとの色
    static let cleanup = Color(hex: "0ea5e9")
    static let largeFiles = Color(hex: "6366f1")
    static let video = Color(hex: "f59e0b")
    static let security = Color(hex: "10b981")
    static let loginItems = Color(hex: "ef4444")
    static let apps = Color(hex: "8b5cf6")
    static let neutral = Color(hex: "475569")
}

/// 背景: 160° のグラデーション＋ティール／ブルーの柔らかい光
struct ThemedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "0f4c5c"), Color(hex: "0b2a3d"), Color(hex: "06131f")],
                           startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
            RadialGradient(colors: [Color(hex: "2dd4bf", opacity: 0.20), .clear],
                           center: UnitPoint(x: 0.8, y: 0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: "3b82f6", opacity: 0.18), .clear],
                           center: UnitPoint(x: 0.3, y: 1), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardView<Content: View>: View {
    var padding: CGFloat = 14
    var radius: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

enum BadgeKind {
    case ok, warn, danger, info
    var color: Color {
        switch self { case .ok: Theme.ok; case .warn: Theme.warn; case .danger: Theme.danger; case .info: Theme.info }
    }
}

struct StatusBadge: View {
    let kind: BadgeKind
    let text: String
    init(kind: BadgeKind, _ text: String) { self.kind = kind; self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.color.opacity(0.15), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 16 : compact ? 12 : 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 30 : compact ? 12 : 22).padding(.vertical, large ? 14 : compact ? 7 : 10)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: large ? 14 : compact ? 10 : 12, style: .continuous))
            .shadow(color: Theme.teal.opacity(enabled ? 0.35 : 0), radius: 10, y: 4)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryDestructive: SecondaryButtonStyle { SecondaryButtonStyle(destructive: true) }
}

/// 健康スコアのリング（中央は数字、または symbol 指定時はアイコン）
struct ScoreRing: View {
    /// nil = 未計測（スマートケア未実行）。数字の代わりに「—」を出し、リングは空にする
    let score: Int?
    var size: CGFloat = 132
    var lineWidth: CGFloat = 12
    var caption: String? = "健康スコア"
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, score ?? 0))) / 100)
                .stroke(tint.map { LinearGradient(colors: [$0, $0.opacity(0.7)], startPoint: .leading, endPoint: .trailing) } ?? Theme.ringGradient,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(tint ?? Theme.accentText)
            } else {
                VStack(spacing: 3) {
                    Text(score.map { "\($0)" } ?? "—").font(.system(size: size * 0.29, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    if let caption { Text(caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary) }
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "健康スコア")
        .accessibilityValue(score.map { "\($0) 点（100 点満点）" } ?? "未計測")
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var filled = true   // false: 色を薄く敷いてアイコンを色付きにする（カード見出し用）
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.25)))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(filled ? Color.white : color.lightened(0.35)))
    }
}

/// ペイン上部の見出し: アイコン + タイトル + 説明 + 右側の操作
struct SectionHeader<Actions: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ボタン類は縮めない（文字が消えるのを防ぐ）。候補は次の順:
    /// 1. 見出しの右に1行 2. 見出しの下に1行 3. 見出しの下で折り返し（FlowLayout）
    /// 注意: actions は候補ごとに生成される（ViewThatFits は全候補を測定する）。
    /// actions 内に onAppear / task など副作用のある処理や @State を持つビューを置かないこと。
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                titleBlock.frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                HStack(spacing: 8) { actions }.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                FlowLayout(spacing: 8, lineSpacing: 8) { actions }
            }
        }
    }
}

/// 子ビューを左から右へ並べ、幅を超えたら次の行へ折り返すレイアウト（各子ビューは理想サイズ）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing; lineH = max(lineH, s.height); maxW = max(maxW, x - spacing)
        }
        return (frames, CGSize(width: maxW, height: y + lineH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, width: bounds.width)
        for (sv, f) in zip(subviews, r.frames) {
            sv.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                     proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// 空状態: 機能色の大きな SF Symbol + 短い説明 + 主ボタン
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let color: Color
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(color)
            Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            action
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// スキャン前の空状態（統一の 3 段構成）: 何をするか → 安全性 → 主ボタン → 所要時間の目安
struct ScanEmptyState: View {
    let symbol: String
    let color: Color
    /// 何をするか（1 行）
    let what: String
    /// StepDurations のキー。実測値があれば「目安: 約 N 分」を出す（nil なら省略）
    var durationKey: String? = nil
    let scan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(color)
            Text(what).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Label("スキャンでは何も削除しません", systemImage: "checkmark.shield.fill")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            Button("スキャンする", action: scan).buttonStyle(.primary).fixedSize().padding(.top, 4)
            if let t = ScanEstimate.text(durationKey) {
                Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 所要時間の目安（StepDurations の実測値。キーが無い・値が無いときは nil）
enum ScanEstimate {
    static func text(_ key: String?, durations: [String: Double]? = nil) -> String? {
        guard let key, let sec = (durations ?? StepDurations.load())[key], sec > 0 else { return nil }
        if sec < 60 { return "目安: 1分未満" }
        return "目安: 約 \(Int((sec / 60).rounded())) 分"
    }
}

/// 情報行（左にアイコン、文言、必要なら右に閉じるボタン）。注意・情報・前回との差分の表示に共通で使う
struct StatusStrip: View {
    var symbol: String = "info.circle.fill"
    var tint: Color = Theme.info
    let text: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(tint == Theme.warn ? Theme.warn : Theme.secondary)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).fixedSize()
                    .accessibilityLabel("閉じる").help("閉じる")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 進行中の表示: 「何をしているか」の文言＋不確定バー
struct ScanActivity: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
            ProgressView().progressViewStyle(.linear).tint(Theme.teal)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 「前回のスキャン（今日 11:42）の結果です」
struct LastScanNote: View {
    let date: Date?
    var body: some View {
        if let date {
            Text("前回のスキャン（\(ShortDate.format(date))）の結果です。最新にするには「再スキャン」を押してください。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// 主ボタン／副ボタンを状態で切り替える（ButtonStyle の型が違うため分岐する）
    @ViewBuilder func prominentButton(_ primary: Bool, compact: Bool = false) -> some View {
        if primary {
            if compact { self.buttonStyle(.primaryCompact) } else { self.buttonStyle(.primary) }
        } else { self.buttonStyle(.secondary) }
    }
    /// 常にダークで表示する（ウィンドウ・パネル共通）
    func oceanScheme() -> some View {
        self.preferredColorScheme(.dark).tint(Theme.teal).foregroundStyle(Theme.text)
    }
    /// リスト/テーブルを透明にしてカードに馴染ませる
    func themedList() -> some View {
        self.scrollContentBackground(.hidden).background(Color.clear)
    }
}

struct ThemedDivider: View {
    var body: some View { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
}

/// カード下端の操作バー（選択件数・実行ボタンなど）
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ThemedDivider()
            HStack(spacing: 8) { content }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.12))
        }
    }
}

/// 一覧の行（交互に薄い背景）
struct ThemedRow<Content: View>: View {
    let index: Int
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index % 2 == 1 ? Theme.rowAlt : Color.clear)
    }
}
