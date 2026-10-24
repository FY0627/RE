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

/// 银行卡账户。只保存后四位，不保存完整卡号、密码或邮箱凭据。
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
        archived: Bool = false
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
    }

    public static func isValidLast4(_ value: String) -> Bool {
        value.count == 4 && value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    public var displayTitle: String { "\(bankName) ·\(last4)" }
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

    public init(name: String, bankID: String?, bankName: String, last4: String, cardType: CardType, currency: CurrencyCode, paletteID: String) {
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.paletteID = paletteID
    }
}

public enum AccountValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyBank
    case invalidLast4
    case duplicateAccount
}
