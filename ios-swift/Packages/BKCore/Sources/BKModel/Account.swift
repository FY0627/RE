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

/// 某个币种的初始余额：用户填写的「现在」的余额，没有更晚的银行通知余额时，以它为起点推算余额。
public struct OpeningBalance: Hashable, Sendable, Codable {
    public var currency: CurrencyCode
    /// 最小货币单位，可为负（欠款）
    public var amountMinor: Int64
    /// 只有晚于这个时间的流水才加到初始余额上
    public var at: Date

    public init(currency: CurrencyCode, amountMinor: Int64, at: Date) {
        self.currency = currency
        self.amountMinor = amountMinor
        self.at = at
    }
}

/// 银行卡账户。自动记账只用后四位匹配；完整卡号是选填的，只为在卡片信息里查看。不保存密码或邮箱凭据。
/// 多币种账户（例如一张卡里存港币、美元、人民币）：`currency` 是主币种，通知没写币种时记为主币种；
/// 其余币种在 `extraCurrencies`。每个币种的余额分开推算，不做换算。
public struct Account: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// 已知银行的标识（见 `BankDirectory`），自定义银行为 nil。
    public var bankID: String?
    public var bankName: String
    /// 后四位，字符串保存以保留前导零。
    public var last4: String
    public var cardType: CardType
    /// 主币种
    public var currency: CurrencyCode
    /// 多币种账户的其他币种（不含主币种）；单币种账户为空。
    public var extraCurrencies: [CurrencyCode]
    public var paletteID: String
    public var sortOrder: Int
    public var createdAt: Date
    public var archived: Bool
    /// 各币种的初始余额（每个币种最多一条）
    public var openingBalances: [OpeningBalance]
    /// 选填的完整卡号（纯数字），末四位必须与 `last4` 一致。
    public var cardNumber: String?
    /// 选填的账号（户口号码），可以是打码的形式，例如 `971-634XXX-888`。
    /// 有的银行通知（尤其是转账邮件）只写账号不写卡号尾号，靠它匹配到这张卡。
    public var accountNumber: String?
    public var face: CardFace

    public init(
        id: String,
        name: String,
        bankID: String?,
        bankName: String,
        last4: String,
        cardType: CardType,
        currency: CurrencyCode,
        extraCurrencies: [CurrencyCode] = [],
        paletteID: String,
        sortOrder: Int,
        createdAt: Date,
        archived: Bool = false,
        openingBalances: [OpeningBalance] = [],
        cardNumber: String? = nil,
        accountNumber: String? = nil,
        face: CardFace = .standard
    ) {
        self.id = id
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.extraCurrencies = Self.normalizedExtras(extraCurrencies, primary: currency)
        self.paletteID = paletteID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.archived = archived
        self.openingBalances = openingBalances
        self.cardNumber = cardNumber
        self.accountNumber = accountNumber
        self.face = face
    }

    /// 账户持有的全部币种，主币种在前。
    public var currencies: [CurrencyCode] { [currency] + extraCurrencies }
    public var isMultiCurrency: Bool { !extraCurrencies.isEmpty }

    public func openingBalance(_ currency: CurrencyCode) -> OpeningBalance? {
        openingBalances.first { $0.currency == currency }
    }

    /// 主币种的初始余额
    public var openingBalanceMinor: Int64? { openingBalance(currency)?.amountMinor }
    public var openingBalanceAt: Date? { openingBalance(currency)?.at }

    /// 去掉重复和主币种，保持原有顺序。
    public static func normalizedExtras(_ extras: [CurrencyCode], primary: CurrencyCode) -> [CurrencyCode] {
        var seen: Set<CurrencyCode> = [primary]
        return extras.filter { seen.insert($0).inserted }
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

    /// 整理用户填写的账号：去掉空格，`x`、`*`、`•` 统一成 `X`（打码位），保留短横线方便阅读。
    /// 去掉短横线后必须是 6–30 位数字或 X，且至少有 3 位数字；否则返回 nil。
    public static func normalizedAccountNumber(_ input: String) -> String? {
        var output = ""
        for char in input.uppercased() where char != " " {
            switch char {
            case "0"..."9", "X", "-": output.append(char)
            case "*", "•": output.append("X")
            default: return nil
            }
        }
        let pattern = numberPattern(output)
        guard (6...30).contains(pattern.count), pattern.filter(\.isNumber).count >= 3 else { return nil }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 号码只留数字和打码位 X，用于比较：`971-634xxx-888` → `971634XXX888`
    public static func numberPattern(_ input: String) -> String {
        String(input.uppercased().compactMap { char -> Character? in
            switch char {
            case "0"..."9", "X": char
            case "*", "•": "X"
            default: nil
            }
        })
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
    /// 多币种账户的其他币种
    public var extraCurrencies: [CurrencyCode]
    public var paletteID: String
    /// 选填：添加时这张卡主币种的当前余额（最小货币单位，可为负，例如信用卡欠款）。
    public var openingBalanceMinor: Int64?
    /// 选填：其他币种的当前余额
    public var extraOpeningBalances: [CurrencyCode: Int64]

    public init(
        name: String, bankID: String?, bankName: String, last4: String, cardType: CardType, currency: CurrencyCode, paletteID: String,
        openingBalanceMinor: Int64? = nil, extraCurrencies: [CurrencyCode] = [], extraOpeningBalances: [CurrencyCode: Int64] = [:]
    ) {
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.extraCurrencies = extraCurrencies
        self.paletteID = paletteID
        self.openingBalanceMinor = openingBalanceMinor
        self.extraOpeningBalances = extraOpeningBalances
    }
}

public enum AccountValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyBank
    case invalidLast4
    case duplicateAccount
    /// 完整卡号不是 12–19 位数字，或末四位与尾号不一致
    case invalidCardNumber
    /// 账号不是 6–30 位数字或打码位
    case invalidAccountNumber
}
