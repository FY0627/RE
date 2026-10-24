import Foundation

/// 资金方向，相对于账户本身：钱进入账户为流入，离开账户为流出。
/// 信用卡消费是流出（负债增加），信用卡还款是流入。
public enum FlowDirection: String, Sendable, Codable, CaseIterable {
    case inflow
    case outflow

    public var opposite: FlowDirection { self == .inflow ? .outflow : .inflow }
    public var displayName: String { self == .inflow ? "流入" : "流出" }
}

/// 交易性质。不是用户分类：用户不能管理它，它只用来正确处理退款、转账、还款等。
public enum TransactionKind: String, Sendable, Codable, CaseIterable {
    case purchase
    case income
    case salary
    case transferIn
    case transferOut
    case refund
    case repayment
    case interestCharge
    case fee
    case deposit
    case withdrawal
    case interestIncome
    case reversal
    case other

    public var displayName: String {
        switch self {
        case .purchase: "消费"
        case .income: "入账"
        case .salary: "工资"
        case .transferIn: "转入"
        case .transferOut: "转出"
        case .refund: "退款"
        case .repayment: "还款"
        case .interestCharge: "扣息"
        case .fee: "手续费"
        case .deposit: "存入"
        case .withdrawal: "取款"
        case .interestIncome: "利息"
        case .reversal: "冲正/撤销"
        case .other: "其他"
        }
    }

    /// 可以与另一账户的反向流水配对成内部转账的性质。
    public var isTransferLike: Bool {
        switch self {
        case .transferIn, .transferOut, .repayment, .deposit, .withdrawal: true
        default: false
        }
    }
}

/// 结算状态：只有 `posted` 计入收支和余额推算。
public enum SettlementStatus: String, Sendable, Codable, CaseIterable {
    /// 已发生的资金变动
    case posted
    /// 预授权、冻结：资金被占用但未结算
    case hold
    /// 预授权撤销、解冻
    case holdReleased
    /// 支付失败、交易未成功
    case failed

    public var displayName: String {
        switch self {
        case .posted: "已入账"
        case .hold: "冻结/预授权"
        case .holdReleased: "解冻/撤销预授权"
        case .failed: "交易失败"
        }
    }
}

public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case sms
    case email
    case other

    public var displayName: String {
        switch self {
        case .sms: "短信"
        case .email: "邮件"
        case .other: "其他文本"
        }
    }
}

/// 通知正文里写明的交易时间（银行所在地的墙上时间，不做时区换算）。
public struct WallClock: Hashable, Sendable, Codable, Comparable {
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var second: Int?
    /// 年份是根据接收时间推断的（正文只写了月日）。
    public var yearInferred: Bool

    public init(year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, second: Int? = nil, yearInferred: Bool = false) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.yearInferred = yearInferred
    }

    public var hasDate: Bool { month != nil && day != nil }
    public var hasTime: Bool { hour != nil && minute != nil }
    /// 精确到分钟，可以作为强去重证据。
    public var isMinutePrecise: Bool { year != nil && hasDate && hasTime }

    private static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }

    /// 可排序的文本，例如 `2026-10-24T14:30`；缺失部分省略。
    public var sortKey: String {
        var text = ""
        if let year { text += Self.pad(year, 4) } else { text += "????" }
        if let month, let day { text += "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2) }
        if let hour, let minute {
            text += "T" + Self.pad(hour, 2) + ":" + Self.pad(minute, 2)
            if let second { text += ":" + Self.pad(second, 2) }
        }
        return text
    }

    public var displayText: String {
        var parts: [String] = []
        if let month, let day {
            if let year, !yearInferred { parts.append("\(year)年\(month)月\(day)日") } else { parts.append("\(month)月\(day)日") }
        }
        if let hour, let minute { parts.append(Self.pad(hour, 2) + ":" + Self.pad(minute, 2)) }
        return parts.joined(separator: " ")
    }

    public static func < (lhs: WallClock, rhs: WallClock) -> Bool { lhs.sortKey < rhs.sortKey }
}

/// 一条资金变动记录。只有备注 `note` 允许用户修改。
public struct LedgerRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var accountID: String
    public var amountMinor: Int64
    public var currency: CurrencyCode
    public var direction: FlowDirection
    public var kind: TransactionKind
    public var status: SettlementStatus
    public var counterparty: String?
    public var transactionTime: WallClock?
    /// 系统提供的接收时间；系统没提供就是 nil，不用处理时间冒充。
    public var receivedAt: Date?
    /// App 处理这条输入的时间。
    public var processedAt: Date
    public var source: SourceKind
    public var ingestID: String
    public var partIndex: Int
    public var bankReference: String?
    public var balanceAfterMinor: Int64?
    /// 本条流水已包含、并已另行拆出的手续费（只用于展示说明）。
    public var includedFeeMinor: Int64?
    public var note: String
    public var transferGroupID: String?
    public var relatedRecordID: String?

    public init(
        id: String, accountID: String, amountMinor: Int64, currency: CurrencyCode, direction: FlowDirection,
        kind: TransactionKind, status: SettlementStatus, counterparty: String?, transactionTime: WallClock?,
        receivedAt: Date?, processedAt: Date, source: SourceKind, ingestID: String, partIndex: Int,
        bankReference: String?, balanceAfterMinor: Int64?, includedFeeMinor: Int64?, note: String,
        transferGroupID: String?, relatedRecordID: String?
    ) {
        self.id = id
        self.accountID = accountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.direction = direction
        self.kind = kind
        self.status = status
        self.counterparty = counterparty
        self.transactionTime = transactionTime
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.source = source
        self.ingestID = ingestID
        self.partIndex = partIndex
        self.bankReference = bankReference
        self.balanceAfterMinor = balanceAfterMinor
        self.includedFeeMinor = includedFeeMinor
        self.note = note
        self.transferGroupID = transferGroupID
        self.relatedRecordID = relatedRecordID
    }

    /// 排序和按日分组使用的系统时间。
    public var effectiveAt: Date { receivedAt ?? processedAt }
    public var isInternalTransfer: Bool { transferGroupID != nil }
    public var money: Money { Money(minorUnits: amountMinor, currency: currency) }
}

/// 列表展示用：记录 + 账户摘要。
public struct RecordRow: Identifiable, Hashable, Sendable {
    public var record: LedgerRecord
    public var accountName: String
    public var bankName: String
    public var last4: String
    public var paletteID: String

    public init(record: LedgerRecord, accountName: String, bankName: String, last4: String, paletteID: String) {
        self.record = record
        self.accountName = accountName
        self.bankName = bankName
        self.last4 = last4
        self.paletteID = paletteID
    }

    public var id: String { record.id }
}

/// 分页游标：按 (effectiveAt, id) 倒序。
public struct RecordCursor: Hashable, Sendable {
    public var effectiveAt: Date
    public var id: String

    public init(effectiveAt: Date, id: String) {
        self.effectiveAt = effectiveAt
        self.id = id
    }
}

/// 记录的来源证据（同一笔交易可能同时有短信和邮件）。
public struct RecordEvidence: Hashable, Sendable {
    public var ingestID: String
    public var source: SourceKind
    public var sender: String?
    public var receivedAt: Date?
    public var processedAt: Date
    public var rawText: String?

    public init(ingestID: String, source: SourceKind, sender: String?, receivedAt: Date?, processedAt: Date, rawText: String?) {
        self.ingestID = ingestID
        self.source = source
        self.sender = sender
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.rawText = rawText
    }
}

public struct RecordDetail: Hashable, Sendable {
    public var row: RecordRow
    public var evidence: [RecordEvidence]
    public var transferPeer: RecordRow?
    public var related: RecordRow?

    public init(row: RecordRow, evidence: [RecordEvidence], transferPeer: RecordRow?, related: RecordRow?) {
        self.row = row
        self.evidence = evidence
        self.transferPeer = transferPeer
        self.related = related
    }
}
