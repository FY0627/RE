import SwiftUI
import BKModel

/// 卡面：配色渐变时有银行圆标、名称与卡类型、余额、尾号；自定义图片时只有右上角的余额。尺寸由外部 frame 决定。
///
/// 渲染开销按 Apple 的建议压低：
/// - 阴影只画在一个圆角矩形上（形状阴影），不对含文字的整张卡做阴影，避免离屏渲染；
/// - 只有图片背景需要圆角裁剪，渐变直接填充圆角矩形，不对整张卡 clip；
/// - 卡面不依赖动画进度，转场时外部只改变换（位移、缩放、旋转、透明度），卡面本身不重新计算。
struct WalletCardView: View {
    let account: Account
    let balanceText: String

    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        let palette = CardPalette.named(account.paletteID)
        let flags = PerfFlags.shared
        face(palette)
            .modifier(CardRasterization(enabled: flags.rasterizeCards))
            .background {
                if flags.cardShadows {
                    Self.shape
                        .fill(Color(hex: palette.colors.last ?? 0x000000))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.spokenTitle)，\(balanceText)")
    }

    private func face(_ palette: CardPalette) -> some View {
        let style = account.face
        // 图片上默认用白字，在大多数照片上更清楚
        let text = style.textColor.map { Color(hex: $0) } ?? (style.imageID == nil ? palette.textColor : .white)
        return Group {
            if style.imageID == nil {
                details(palette, text: text)
            } else {
                balance.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background(palette, imageID: style.imageID) }
    }

    private var balance: some View {
        Text(balanceText)
            .font(.system(size: 14 * account.face.textScale, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func details(_ palette: CardPalette, text: Color) -> some View {
        let style = account.face
        let s = style.textScale
        let subtext = style.textColor == nil ? palette.subtextColor : text.opacity(0.75)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(text.opacity(0.15))
                        .frame(width: 30 * s, height: 30 * s)
                        .overlay(Text(Self.badge(account)).font(.system(size: 14 * s, weight: .bold)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.name).font(.system(size: 14 * s, weight: .bold)).lineLimit(1)
                        Text(account.isCard ? "\(account.bankName) · \(account.cardType.displayName)" : account.cardType.displayName)
                            .font(.system(size: 11 * s, weight: .medium))
                            .foregroundStyle(subtext)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "wave.3.right").font(.system(size: 13 * s)).opacity(0.8)
                    balance
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                if account.isCard {
                    Text("•••• \(account.last4)").font(.system(size: 15 * s, weight: .semibold)).tracking(1.2)
                } else {
                    // 现金、电子钱包没有卡号
                    Image(systemName: account.cardType.symbolName).font(.system(size: 17 * s, weight: .semibold)).opacity(0.85)
                }
                Spacer()
                Text(Self.currencyLabel(account)).font(.system(size: 12 * s, weight: .bold)).italic().opacity(0.8)
            }
        }
    }

    /// 圆标里的字：列表里的银行用它的简称（「中国工商银行」写「工」），自己填的银行用名称的第一个字
    static func badge(_ account: Account) -> String {
        BankCatalog.entry(id: account.bankID)?.badge ?? String(account.bankName.prefix(1))
    }

    /// 单币种显示币种代码；多币种显示主币种和其他币种的数量，例如「HKD +2」。
    static func currencyLabel(_ account: Account) -> String {
        account.isMultiCurrency ? "\(account.currency.rawValue) +\(account.extraCurrencies.count)" : account.currency.rawValue
    }

    /// 自定义图片在后台解码完成之前先显示配色渐变。
    @ViewBuilder
    private func background(_ palette: CardPalette, imageID: String?) -> some View {
        if let imageID, let image = CardFaceImages.shared.image(imageID) {
            // Color.clear 占满卡片，图片在它上面等比填满，再按卡片圆角裁剪
            Color.clear
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipShape(Self.shape)
        } else {
            Self.shape.fill(palette.gradient)
        }
    }
}

/// 单变量开关：卡面是否先合成为一张离屏位图。
private struct CardRasterization: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.drawingGroup() } else { content }
    }
}

extension AccountBalances {
    /// 卡面上显示一个币种的余额：主币种有余额就用主币种，否则用第一个有余额的币种。
    var cardText: String { display?.cardText ?? "余额未知" }
}

extension AccountBalanceSummary {
    /// 卡面上显示的余额：从你填写的初始余额推算；没填时显示「余额未知」，不用部分流水冒充。
    var cardText: String {
        guard let derived = ledgerDerivedMinor else { return "余额未知" }
        return Fmt.money(derived, currency)
    }
}
