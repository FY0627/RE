import Foundation

public enum CardType: String, Sendable, Codable, CaseIterable {
    case debit
    case credit
    case prepaid
    case other

    public var displayName: String {
        switch self {
        case .debit: "借记卡"
        case .credit: "信用卡"
        case .prepaid: "预付卡"
        case .other: "其他账户"
        }
    }
}

/// 卡面个性化：自定义背景图和文字样式。都为空时使用配色方案的默认样式。
public struct CardFace: Hashable, Sendable, Codable {
    /// 背景图的标识。图片本身保存在 App 的文件目录，不进数据库；每次换图都生成新标识。
    public var imageID: String?
    /// 文字颜色（0xRRGGBB）；nil 时用配色方案的文字颜色。
    public var textColor: UInt32?
    /// 文字大小倍数，1 为默认。
    public var textScale: Double

    public init(imageID: String? = nil, textColor: UInt32? = nil, textScale: Double = 1) {
        self.imageID = imageID
        self.textColor = textColor
        self.textScale = textScale
    }

    public static let standard = CardFace()
    public static let textScaleRange: ClosedRange<Double> = 0.8...1.3
}

/// 银行卡账户。自动记账只用后四位匹配；完整卡号是选填的，只为在卡片信息里查看。不保存密码或邮箱凭据。
public struct Account: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// 已知银行的标识（见 `BankDirectory`），自定义银行为 nil。
    public var bankID: String?
    public var bankName: String
    /// 后四位，字符串保存以保留前导零。
    public var last4: String
    public var cardType: CardType
    public var currency: CurrencyCode
    public var paletteID: String
    public var sortOrder: Int
    public var createdAt: Date
    public var archived: Bool
    /// 用户填写的初始余额（最小货币单位，账户币种）。没有银行通知余额时，以它为起点推算余额。
    public var openingBalanceMinor: Int64?
    /// 初始余额对应的时间点：只有晚于这个时间的流水才加到初始余额上。
    public var openingBalanceAt: Date?
    /// 选填的完整卡号（纯数字），末四位必须与 `last4` 一致。
    public var cardNumber: String?
    public var face: CardFace

    public init(
        id: String,
        name: String,
        bankID: String?,
        bankName: String,
        last4: String,
        cardType: CardType,
        currency: CurrencyCode,
        paletteID: String,
        sortOrder: Int,
        createdAt: Date,
        archived: Bool = false,
        openingBalanceMinor: Int64? = nil,
        openingBalanceAt: Date? = nil,
        cardNumber: String? = nil,
        face: CardFace = .standard
    ) {
        self.id = id
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.paletteID = paletteID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.archived = archived
        self.openingBalanceMinor = openingBalanceMinor
        self.openingBalanceAt = openingBalanceAt
        self.cardNumber = cardNumber
        self.face = face
    }

    public static func isValidLast4(_ value: String) -> Bool {
        value.count == 4 && value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    public var displayTitle: String { "\(bankName) ·\(last4)" }

    /// 去掉空格和短横线后的卡号；不是 12–19 位数字时返回 nil。
    public static func normalizedCardNumber(_ input: String) -> String? {
        let digits = String(input.filter { $0 != " " && $0 != "-" })
        guard (12...19).contains(digits.count), digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
        return digits
    }
}

/// 添加账户时由界面填写的内容。
public struct AccountDraft: Sendable, Hashable {
    public var name: String
    public var bankID: String?
    public var bankName: String
    public var last4: String
    public var cardType: CardType
    public var currency: CurrencyCode
    public var paletteID: String
    /// 选填：添加时这张卡的当前余额（最小货币单位，可为负，例如信用卡欠款）。
    public var openingBalanceMinor: Int64?

    public init(name: String, bankID: String?, bankName: String, last4: String, cardType: CardType, currency: CurrencyCode, paletteID: String, openingBalanceMinor: Int64? = nil) {
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.paletteID = paletteID
        self.openingBalanceMinor = openingBalanceMinor
    }
}

public enum AccountValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyBank
    case invalidLast4
    case duplicateAccount
    /// 完整卡号不是 12–19 位数字，或末四位与尾号不一致
    case invalidCardNumber
}
