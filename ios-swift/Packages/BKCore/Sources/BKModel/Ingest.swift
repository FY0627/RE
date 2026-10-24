import Foundation

/// 快捷指令交给 App 的一次输入。只包含系统实际提供的字段，缺失就是 nil。
public struct IngestRequest: Sendable, Hashable {
    public var text: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    public var receivedAt: Date?
    public var messageID: String?
    public var boundAccountID: String?

    public init(text: String, source: SourceKind, sender: String? = nil, subject: String? = nil, receivedAt: Date? = nil, messageID: String? = nil, boundAccountID: String? = nil) {
        self.text = text
        self.source = source
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.boundAccountID = boundAccountID
    }
}

/// 整条通知的类别。
public enum MessageClassification: String, Sendable, Codable, CaseIterable {
    case transaction
    case verificationCode
    case marketing
    case reminder
    case statement
    case balanceSnapshot
    case creditLimitChange
    case unrecognized
    case empty

    public var displayName: String {
        switch self {
        case .transaction: "资金变动"
        case .verificationCode: "验证码（内容未保存）"
        case .marketing: "营销信息"
        case .reminder: "还款/账单/扣款提醒"
        case .statement: "账单/对账单（不重复入账）"
        case .balanceSnapshot: "余额通知（无交易）"
        case .creditLimitChange: "信用额度变化"
        case .unrecognized: "未能识别"
        case .empty: "空输入（快捷指令未传入内容）"
        }
    }
}

/// 一次输入的最终处理结果。
public enum IngestOutcome: String, Sendable, Codable {
    /// 至少一笔已入账，没有待处理
    case recorded
    /// 有内容进入待处理（可能同时有已入账的）
    case pending
    /// 识别为非交易信息，只记日志
    case filtered
    /// 与之前的输入完全相同
    case duplicateInput
    /// 每一笔都与已有流水重复，已合并为来源证据
    case mergedDuplicate
}

public struct IngestResult: Sendable, Hashable {
    public var ingestID: String?
    public var outcome: IngestOutcome
    public var classification: MessageClassification
    public var recordedCount: Int
    public var mergedCount: Int
    public var pendingCount: Int
    public var summary: String

    public init(ingestID: String?, outcome: IngestOutcome, classification: MessageClassification, recordedCount: Int, mergedCount: Int, pendingCount: Int, summary: String) {
        self.ingestID = ingestID
        self.outcome = outcome
        self.classification = classification
        self.recordedCount = recordedCount
        self.mergedCount = mergedCount
        self.pendingCount = pendingCount
        self.summary = summary
    }
}

/// 「我的 › 自动记账状态」里展示的接收日志。
public struct IngestLogEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    public var receivedAt: Date?
    public var processedAt: Date
    public var classification: MessageClassification
    public var outcome: IngestOutcome
    public var detail: String
    public var rawText: String?
    public var boundAccountID: String?

    public init(id: String, source: SourceKind, sender: String?, subject: String?, receivedAt: Date?, processedAt: Date, classification: MessageClassification, outcome: IngestOutcome, detail: String, rawText: String?, boundAccountID: String?) {
        self.id = id
        self.source = source
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.classification = classification
        self.outcome = outcome
        self.detail = detail
        self.rawText = rawText
        self.boundAccountID = boundAccountID
    }
}

public enum PendingReason: String, Sendable, Codable, CaseIterable {
    /// 同尾号多个账户或来源冲突
    case ambiguousAccount
    /// 没有与尾号匹配的账户
    case noMatchingAccount
    /// 正文里没有尾号，只有快捷指令绑定的账户可作为候选
    case missingCardTail
    /// 正文里找不到金额
    case missingAmount
    /// 同一句里有多个可能是交易金额的数字，或金额格式有歧义
    case ambiguousAmount
    /// 币种无法确定
    case unknownCurrency
    /// 无法判断资金方向或交易性质
    case uncertainKind
    /// 与另一来源的已有流水高度相似但证据不足以合并
    case possibleDuplicate
    /// 整条通知未能识别
    case unrecognized

    public var displayName: String {
        switch self {
        case .ambiguousAccount: "多个账户都可能匹配"
        case .noMatchingAccount: "没有与尾号匹配的账户"
        case .missingCardTail: "通知里没有卡号尾号"
        case .missingAmount: "没有找到交易金额"
        case .ambiguousAmount: "金额有歧义"
        case .unknownCurrency: "无法确定币种"
        case .uncertainKind: "无法确定资金方向"
        case .possibleDuplicate: "可能与已有流水重复"
        case .unrecognized: "暂不支持的通知格式"
        }
    }

    /// 是否允许用户从系统给出的候选中确认入账。
    public var allowsConfirmation: Bool {
        switch self {
        case .ambiguousAccount, .missingCardTail, .possibleDuplicate, .noMatchingAccount: true
        default: false
        }
    }
}

public enum PendingStatus: String, Sendable, Codable {
    case open
    case confirmed
    case ignored
}

/// 通知里的一个金额：先保留原文，等币种确定后再按该币种的小数位换算成最小单位。
public struct AmountText: Hashable, Sendable, Codable {
    /// 去掉货币符号后的数字原文，例如 `1,234.56`、`1.234,56`
    public var digits: String
    /// 在这个金额旁边写明的币种候选（`¥` 可能是 CNY 或 JPY，`$` 可能是多种美元）
    public var currencyCandidates: [CurrencyCode]
    /// 候选有多个时，按书写习惯优先考虑的一个（例如中文短信里的「元」「¥」→ CNY）
    public var preferredCurrency: CurrencyCode?

    public init(digits: String, currencyCandidates: [CurrencyCode], preferredCurrency: CurrencyCode?) {
        self.digits = digits
        self.currencyCandidates = currencyCandidates
        self.preferredCurrency = preferredCurrency
    }
}

/// 解析出的一笔交易草稿，账户可能尚未确定。
public struct EventDraft: Hashable, Sendable, Codable {
    public var amount: AmountText
    public var direction: FlowDirection?
    public var kind: TransactionKind
    public var status: SettlementStatus
    public var counterparty: String?
    public var cardTail: String?
    public var counterpartyTail: String?
    public var transactionTime: WallClock?
    public var bankReference: String?
    public var balanceAfter: AmountText?
    /// 原交易金额里「含手续费」的部分；已拆成单独的手续费草稿
    public var includedFee: AmountText?
    /// 由「含手续费」拆出来的手续费部分
    public var isSplitFee: Bool
    public var partIndex: Int
    public var bankHint: String?
    /// 原文中这笔交易所在的句子（展示给用户核对，不会上传）
    public var evidenceSnippet: String

    public init(amount: AmountText, direction: FlowDirection?, kind: TransactionKind, status: SettlementStatus, counterparty: String?, cardTail: String?, counterpartyTail: String?, transactionTime: WallClock?, bankReference: String?, balanceAfter: AmountText?, includedFee: AmountText?, isSplitFee: Bool, partIndex: Int, bankHint: String?, evidenceSnippet: String) {
        self.amount = amount
        self.direction = direction
        self.kind = kind
        self.status = status
        self.counterparty = counterparty
        self.cardTail = cardTail
        self.counterpartyTail = counterpartyTail
        self.transactionTime = transactionTime
        self.bankReference = bankReference
        self.balanceAfter = balanceAfter
        self.includedFee = includedFee
        self.isSplitFee = isSplitFee
        self.partIndex = partIndex
        self.bankHint = bankHint
        self.evidenceSnippet = evidenceSnippet
    }
}

public struct PendingItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var ingestID: String
    public var reason: PendingReason
    public var draft: EventDraft?
    public var candidateAccountIDs: [String]
    public var duplicateOfRecordID: String?
    public var status: PendingStatus
    public var createdAt: Date
    public var source: SourceKind
    public var sender: String?
    public var receivedAt: Date?
    public var rawText: String?

    public init(id: String, ingestID: String, reason: PendingReason, draft: EventDraft?, candidateAccountIDs: [String], duplicateOfRecordID: String?, status: PendingStatus, createdAt: Date, source: SourceKind, sender: String?, receivedAt: Date?, rawText: String?) {
        self.id = id
        self.ingestID = ingestID
        self.reason = reason
        self.draft = draft
        self.candidateAccountIDs = candidateAccountIDs
        self.duplicateOfRecordID = duplicateOfRecordID
        self.status = status
        self.createdAt = createdAt
        self.source = source
        self.sender = sender
        self.receivedAt = receivedAt
        self.rawText = rawText
    }
}

/// 银行通知里写明的余额（快照）。
public struct BalanceObservation: Hashable, Sendable {
    public var accountID: String
    public var amountMinor: Int64
    public var currency: CurrencyCode
    /// 用于判断新旧：有正文时间就用正文时间，否则用系统接收时间/处理时间。
    public var orderKey: String
    public var transactionTime: WallClock?
    public var observedAt: Date
    public var recordID: String?

    public init(accountID: String, amountMinor: Int64, currency: CurrencyCode, orderKey: String, transactionTime: WallClock?, observedAt: Date, recordID: String?) {
        self.accountID = accountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.orderKey = orderKey
        self.transactionTime = transactionTime
        self.observedAt = observedAt
        self.recordID = recordID
    }
}

/// 账户余额：银行通知余额与账本推算余额分开展示。
public struct AccountBalanceSummary: Hashable, Sendable {
    public var accountID: String
    /// 最新（按通知内时间排序）的银行通知余额；没有就是未知
    public var bankReported: BalanceObservation?
    /// 银行余额 + 之后已入账流水；没有银行余额基准时为 nil（未知）
    public var ledgerDerivedMinor: Int64?
    /// 推算用到的、晚于基准的流水笔数
    public var recordsAfterBase: Int

    public init(accountID: String, bankReported: BalanceObservation?, ledgerDerivedMinor: Int64?, recordsAfterBase: Int) {
        self.accountID = accountID
        self.bankReported = bankReported
        self.ledgerDerivedMinor = ledgerDerivedMinor
        self.recordsAfterBase = recordsAfterBase
    }
}

/// 某账户的自动记账可观测状态。App 读不到快捷指令自动化是否启用，只能展示实际接收情况。
public struct AccountAutomationStatus: Hashable, Sendable {
    public var accountID: String
    public var lastSuccessAt: Date?
    public var lastSuccessSource: SourceKind?
    public var receivedCount: Int

    public init(accountID: String, lastSuccessAt: Date?, lastSuccessSource: SourceKind?, receivedCount: Int) {
        self.accountID = accountID
        self.lastSuccessAt = lastSuccessAt
        self.lastSuccessSource = lastSuccessSource
        self.receivedCount = receivedCount
    }
}

/// 统计页的月度汇总（按币种分开，不做汇率换算）。
public struct MonthStats: Hashable, Sendable {
    public struct CurrencyTotals: Hashable, Sendable {
        public var currency: CurrencyCode
        /// 支出：流出，不含内部转账与还款
        public var expenseMinor: Int64
        /// 收入：流入，不含内部转账、还款、退款、冲正
        public var incomeMinor: Int64
        /// 退款与流入方向的冲正
        public var refundMinor: Int64
        /// 内部转账（两边都在账本里或已明确关联），不计入收支
        public var internalTransferMinor: Int64
        /// 还款，不计入收支
        public var repaymentMinor: Int64
        public var recordCount: Int
        public var byKind: [KindTotal]

        public init(currency: CurrencyCode, expenseMinor: Int64, incomeMinor: Int64, refundMinor: Int64, internalTransferMinor: Int64, repaymentMinor: Int64, recordCount: Int, byKind: [KindTotal]) {
            self.currency = currency
            self.expenseMinor = expenseMinor
            self.incomeMinor = incomeMinor
            self.refundMinor = refundMinor
            self.internalTransferMinor = internalTransferMinor
            self.repaymentMinor = repaymentMinor
            self.recordCount = recordCount
            self.byKind = byKind
        }

        public var netExpenseMinor: Int64 { expenseMinor - refundMinor }
    }

    public struct KindTotal: Hashable, Sendable {
        public var kind: TransactionKind
        public var direction: FlowDirection
        public var amountMinor: Int64
        public var count: Int

        public init(kind: TransactionKind, direction: FlowDirection, amountMinor: Int64, count: Int) {
            self.kind = kind
            self.direction = direction
            self.amountMinor = amountMinor
            self.count = count
        }
    }

    public struct AccountTotal: Hashable, Sendable {
        public var accountID: String
        public var currency: CurrencyCode
        public var inflowMinor: Int64
        public var outflowMinor: Int64
        public var count: Int

        public init(accountID: String, currency: CurrencyCode, inflowMinor: Int64, outflowMinor: Int64, count: Int) {
            self.accountID = accountID
            self.currency = currency
            self.inflowMinor = inflowMinor
            self.outflowMinor = outflowMinor
            self.count = count
        }
    }

    public var year: Int
    public var month: Int
    public var currencies: [CurrencyTotals]
    public var accounts: [AccountTotal]
    public var holdCount: Int
    public var failedCount: Int

    public init(year: Int, month: Int, currencies: [CurrencyTotals], accounts: [AccountTotal], holdCount: Int, failedCount: Int) {
        self.year = year
        self.month = month
        self.currencies = currencies
        self.accounts = accounts
        self.holdCount = holdCount
        self.failedCount = failedCount
    }
}
