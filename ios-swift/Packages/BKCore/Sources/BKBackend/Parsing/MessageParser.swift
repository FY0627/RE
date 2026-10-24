import Foundation
import BKModel

public struct MessageContext: Sendable {
    public var text: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    /// 用于推断「10月24日」这类没写年份的日期：系统接收时间，没有则用处理时间
    public var referenceDate: Date
    public var calendar: Calendar

    public init(text: String, source: SourceKind, sender: String?, subject: String?, referenceDate: Date, calendar: Calendar) {
        self.text = text
        self.source = source
        self.sender = sender
        self.subject = subject
        self.referenceDate = referenceDate
        self.calendar = calendar
    }
}

public struct ParsedEvent: Sendable, Hashable {
    public var draft: EventDraft
    /// 解析阶段就能确定的问题；nil 表示草稿完整（账户匹配在入账服务里做）
    public var issue: PendingReason?
}

public struct ParsedBalance: Sendable, Hashable {
    public var amount: AmountText
    public var negative: Bool
    public var cardTail: String?
    public var transactionTime: WallClock?
}

public struct ParsedMessage: Sendable {
    public var classification: MessageClassification
    public var events: [ParsedEvent]
    public var balances: [ParsedBalance]
    public var bankHint: String?
    public var cleanedText: String
}

/// 规则解析器：纯函数，不访问数据库，不依赖网络。
public enum MessageParser {
    public static let version = 1

    // MARK: 识别用正则

    private static let tailPatterns: [Rx] = [
        Rx(#"(?:尾号|尾数|末四位|后四位|卡号后四位|账号尾号|卡尾号)\s*(?:为|是)?\s*[：:]?\s*[*xX•·]*\s*(\d{4})(?![\d年月日元.,])"#),
        Rx(#"(?:账户|账号|卡号?|card|acct|account|a/c|konto|karte)\s*(?:ending(?:\s+in|\s+with)?|endend auf|no\.?)?\s*[*xX•·.]{1,}\s*(\d{4})(?![\d年月日元.,])"#),
        Rx(#"(?:ending(?:\s+in|\s+with)?|ends in|endend auf)\s*[：:]?\s*[*xX•·]*\s*(\d{4})(?![\d.,])"#),
        Rx(#"(?<![\w])[*xX•]{2,}\s?(\d{4})(?![\d.,])"#),
        Rx(#"(?:借记卡|储蓄卡|信用卡|贷记卡)?(?:账户|账号)\s*(\d{4})(?![\d年月日元.,:：])"#),
    ]
    private static let referencePattern = Rx(#"(?:交易流水号|流水号|交易参考号|参考号|凭证号|交易编号|交易序号|reference(?:\s+no\.?|\s+number)?|\bref(?:\.|\s+no\.?)?|txn id|transaction id)\s*[：:#]?\s*([A-Za-z0-9][A-Za-z0-9\-]{5,31})"#)
    private static let longDigits = Rx(#"\d{9,}"#)
    private static let counterpartyTailMarker = Rx(#"(?:向|至|到|给|对方|收款|付款|\bto|\bfrom)\s*$"#)
    private static let feeClause = Rx(#"(?:含\s*)?(?:手续费|服务费|费用)[^，,。；;)）]*"#)
    private static let cjk = Rx(#"[\x{4E00}-\x{9FFF}]"#)

    private static let dateTimeFull = Rx(#"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?(?:\s*(?:T|\s)?\s*(\d{1,2})\s*[：:时点]\s*(\d{2})\s*(?:[：:分]\s*(\d{2}))?\s*(?:秒|分)?)?"#)
    private static let dateNumericYear = Rx(#"(?<![\d.])(\d{1,2})([/.])(\d{1,2})[/.](20\d{2}|\d{2})(?:,?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?(?![\d])"#)
    private static let dateEnglishDMY = Rx(#"(?<![\d])(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s*(20\d{2})?(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2}))?"#)
    private static let dateEnglishMDY = Rx(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(20\d{2})?(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2}))?"#)
    private static let dateChinese = Rx(#"(\d{1,2})\s*月\s*(\d{1,2})\s*日(?:\s*(\d{1,2})\s*[：:时点]\s*(\d{2})\s*(?:[：:分]\s*(\d{2}))?\s*(?:秒|分)?)?"#)
    private static let dateShort = Rx(#"(?<![\d.,/])(\d{1,2})([-/])(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d])"#)
    private static let timeOnly = Rx(#"(?<![\d:.])(\d{1,2})\s*[：:]\s*(\d{2})(?:\s*[：:]\s*(\d{2}))?(?![\d:])|(\d{1,2})时(\d{2})分"#)

    private static let amountPattern = Rx(#"(?<![\d.,'#])([-+])?\s?(\d{1,3}(?:,\d{3})+(?:\.\d{1,3})?|\d{1,3}(?:\.\d{3})+(?:,\d{1,3})?|\d{1,3}(?:'\d{3})+(?:\.\d{1,3})?|\d+(?:[.,]\d{1,3})?)(?![\d'#]|[.,]\d)"#)

    private static let counterpartyPatterns: [Rx] = [
        Rx(#"(?:商户名称|交易商户|商户|对方户名|对方账户名|对方名称|对方|收款方|收款人|付款方|付款人|交易对象|merchant|payee|händler)\s*[：:]\s*([^，,。；;\n()（）]{1,40})"#),
        Rx(#"在\s*([^，,。；;\n\d][^，,。；;\n]{1,29}?)\s*(?:消费|支付|刷卡|网上支付|快捷支付|扣款|购物)"#),
        Rx(#"([^\s，,。；;\n:：]{2,30}?)\s*向您(?:尾号\s*[*xX•]*\d{4})?的?(?:账户|账号|卡)?(?:转账|汇款)"#),
        Rx(#"向\s*([^您，,。；;\n][^，,。；;\n]{1,29}?)\s*(?:转账|转出|付款|汇款)"#),
        Rx(#"(?:来自|付款方)\s*([^，,。；;\n]{2,30}?)(?:的|转账|汇款|[，,。；;\n]|$)"#),
        Rx(#"\bat\s+([A-Z0-9][A-Za-z0-9 &'.\-*/]{1,40}?)(?=\s+on\b|\s+\d|[.,;]|\s*$)"#, caseInsensitive: false),
        Rx(#"\b(?:to|from)\s+([A-Z][A-Za-z0-9 &'.\-]{1,40}?)(?=\s+on\b|\s+\d|[.,;]|\s*$)"#, caseInsensitive: false),
        Rx(#"\bbei\s+([A-Z0-9][A-Za-z0-9 &'.\-]{1,40}?)(?=\s+am\b|[.,;]|\s*$)"#, caseInsensitive: false),
    ]
    private static let genericSummary: Set<String> = [
        "消费", "转账", "跨行转账", "行内转账", "工资", "代发工资", "代发", "利息", "结息", "存款", "取款", "支取", "存入", "转入", "转出",
        "汇款", "退款", "还款", "手续费", "年费", "快捷支付", "网上支付", "支付", "扣款", "收入", "支出", "其他", "无",
    ]
    private static let counterpartyNoise = Rx(#"尾号|账户|卡号|您的|贵|本行|余额|人民币|\d{2}[：:]\d{2}|\d+月\d+日|^\d+$|^[\s\p{P}]+$"#)

    private static let sentenceBreak = Rx(#"[。；;!！?？\n]|\.\s+(?=[A-Z【\[])"#, caseInsensitive: false)
    private static let clauseBreak = Rx(#"[，、()（）]|,(?!\d)|\s-\s"#, caseInsensitive: false)

    // MARK: 中间结构

    private struct Mention<Value> {
        var range: NSRange
        var value: Value
    }

    private struct AmountMention {
        var range: NSRange
        var digits: String
        var negative: Bool
        var amount: AmountText
        var hasCurrency: Bool
        var role: Lexicon.Role?
        var includedFee: Bool
        var sentence: Int
    }

    // MARK: 入口

    public static func parse(_ context: MessageContext) -> ParsedMessage {
        var cleaned = TextNormalizer.normalize(context.text)
        if context.source == .email { cleaned = EmailCleaner.stripQuotedHistory(cleaned) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = context.subject.map(TextNormalizer.normalize) ?? ""
        let bankHint = BankDirectory.identify(sender: context.sender, text: cleaned + "\n" + subject)

        func result(_ classification: MessageClassification, _ events: [ParsedEvent] = [], _ balances: [ParsedBalance] = []) -> ParsedMessage {
            ParsedMessage(classification: classification, events: events, balances: balances, bankHint: bankHint, cleanedText: cleaned)
        }

        guard !cleaned.isEmpty else { return result(.empty) }
        if Lexicon.verificationCodeValue.test(cleaned) || Lexicon.verificationCodeValue.test(subject) { return result(.verificationCode) }
        if Lexicon.statement.test(subject) || Lexicon.statement.test(cleaned) { return result(.statement) }

        let ns = NSString(string: cleaned)
        let length = ns.length
        var masked = [Bool](repeating: false, count: length)
        func isFree(_ r: NSRange) -> Bool { (r.location..<(r.location + r.length)).allSatisfy { !masked[$0] } }
        func mask(_ r: NSRange) { for i in r.location..<(r.location + r.length) { masked[i] = true } }

        // 1. 卡号尾号
        var tails: [Mention<String>] = []
        for pattern in tailPatterns {
            for match in pattern.matches(ns) where isFree(match.range) {
                guard let value = match.group(1, in: ns) else { continue }
                tails.append(Mention(range: match.range, value: value))
                mask(match.range)
            }
        }
        tails.sort { $0.range.location < $1.range.location }

        // 2. 日期时间
        let chinese = cjk.test(cleaned)
        var times: [Mention<WallClock>] = []
        func addTime(_ range: NSRange, _ clock: WallClock?) {
            guard let clock, isFree(range) else { return }
            times.append(Mention(range: range, value: clock))
            mask(range)
        }
        let calendar = context.calendar
        let reference = context.referenceDate
        for m in dateTimeFull.matches(ns) {
            addTime(m.range, makeClock(year: m.group(1, in: ns), month: m.group(2, in: ns), day: m.group(3, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: m.group(6, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateNumericYear.matches(ns) {
            guard let a = m.group(1, in: ns).flatMap(Int.init), let b = m.group(3, in: ns).flatMap(Int.init) else { continue }
            let separator = m.group(2, in: ns) ?? "/"
            var month: Int?, day: Int?
            if separator == "." || a > 12 { day = a; month = b } else if b > 12 { month = a; day = b }
            var yearText = m.group(4, in: ns)
            if let y = yearText, y.count == 2 { yearText = "20" + y }
            if month == nil {
                // 无法区分日/月：不写入日期，只保留时间（如果有）
                addTime(m.range, makeClock(year: nil, month: nil, day: nil, hour: m.group(5, in: ns), minute: m.group(6, in: ns), second: m.group(7, in: ns), reference: reference, calendar: calendar))
                continue
            }
            addTime(m.range, makeClock(year: yearText, month: month.map(String.init), day: day.map(String.init), hour: m.group(5, in: ns), minute: m.group(6, in: ns), second: m.group(7, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateEnglishDMY.matches(ns) {
            addTime(m.range, makeClock(year: m.group(3, in: ns), month: monthNumber(m.group(2, in: ns)).map(String.init), day: m.group(1, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: nil, reference: reference, calendar: calendar))
        }
        for m in dateEnglishMDY.matches(ns) {
            addTime(m.range, makeClock(year: m.group(3, in: ns), month: monthNumber(m.group(1, in: ns)).map(String.init), day: m.group(2, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: nil, reference: reference, calendar: calendar))
        }
        for m in dateChinese.matches(ns) {
            addTime(m.range, makeClock(year: nil, month: m.group(1, in: ns), day: m.group(2, in: ns), hour: m.group(3, in: ns), minute: m.group(4, in: ns), second: m.group(5, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateShort.matches(ns) {
            guard let a = m.group(1, in: ns).flatMap(Int.init), let b = m.group(3, in: ns).flatMap(Int.init) else { continue }
            var month: Int?, day: Int?
            if chinese { month = a; day = b } else if a > 12 { day = a; month = b } else if b > 12 { month = a; day = b }
            addTime(m.range, makeClock(year: nil, month: month.map(String.init), day: day.map(String.init), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: m.group(6, in: ns), reference: reference, calendar: calendar))
        }
        for m in timeOnly.matches(ns) {
            let hour = m.group(1, in: ns) ?? m.group(4, in: ns)
            let minute = m.group(2, in: ns) ?? m.group(5, in: ns)
            addTime(m.range, makeClock(year: nil, month: nil, day: nil, hour: hour, minute: minute, second: m.group(3, in: ns), reference: reference, calendar: calendar))
        }
        times.sort { $0.range.location < $1.range.location }
        times = mergeAdjacentDateAndTime(times, in: ns)

        // 3. 交易参考号、长数字串
        var references: [Mention<String>] = []
        for m in referencePattern.matches(ns) where isFree(m.range) {
            if let value = m.group(1, in: ns) { references.append(Mention(range: m.range, value: value)) }
            mask(m.range)
        }
        for m in longDigits.matches(ns) where isFree(m.range) { mask(m.range) }

        // 4. 句子与分句
        let sentences = splitRanges(ns, by: sentenceBreak)
        func sentenceIndex(_ location: Int) -> Int {
            sentences.firstIndex { location >= $0.location && location < $0.location + $0.length } ?? max(0, sentences.count - 1)
        }
        let clauseBoundaries = clauseBreak.matches(ns).map(\.range.location) + sentenceBreak.matches(ns).map(\.range.location)

        // 5. 金额
        var units = Array(cleaned.utf16)
        for i in 0..<units.count where masked[i] { units[i] = 0x23 }
        let maskedText = NSString(string: String(decoding: units, as: UTF16.self))
        var amounts: [AmountMention] = []
        for m in amountPattern.matches(maskedText) {
            guard let digits = m.group(2, in: maskedText) else { continue }
            let numberRange = m.range(at: 2)
            let afterLocation = numberRange.location + numberRange.length
            let after = maskedText.substring(from: afterLocation)
            let beforeStart = max(0, m.range.location - 10)
            let before = maskedText.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
            let prefixCurrency = CurrencyTokens.prefix(in: before)
            let suffixCurrency = CurrencyTokens.suffix(in: after)
            let hasCurrency = prefixCurrency != nil || suffixCurrency != nil
            if !hasCurrency, Lexicon.nonAmountSuffix.test(after) { continue }

            let candidates = CurrencyTokens.combine(prefixCurrency, suffixCurrency, chineseText: chinese)
            var signNegative = m.group(1, in: maskedText) == "-"
            if !signNegative, before.hasSuffix("-") || before.hasSuffix("−") { signNegative = true }

            // 金额前最近的标签（限定在本分句内）
            let clauseStart = clauseBoundaries.filter { $0 < numberRange.location }.max().map { $0 + 1 } ?? 0
            let windowStart = max(clauseStart, numberRange.location - 24)
            let window = ns.substring(with: NSRange(location: windowStart, length: max(0, numberRange.location - windowStart)))
            let (role, included) = roleFor(window: window)
            let hasDecimals = digits.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil
            if !hasCurrency, role == nil, !hasDecimals { continue }
            if role == .points { continue }
            if !hasCurrency, role == nil {
                // 只有两位小数、没有币种也没有标签：分句里必须有交易动作词才算金额
                let clause = ns.substring(with: NSRange(location: clauseStart, length: min(length, afterLocation + 8) - clauseStart))
                if Lexicon.roleLabels.last!.1.test(clause) == false { continue }
            }
            amounts.append(AmountMention(
                range: m.range, digits: digits, negative: signNegative,
                amount: AmountText(digits: digits, currencyCandidates: candidates.candidates, preferredCurrency: candidates.preferred),
                hasCurrency: hasCurrency, role: role ?? .transaction, includedFee: included, sentence: sentenceIndex(numberRange.location)
            ))
        }

        // 同一条通知里其他金额写明的币种，可作为没写币种的金额的线索
        let messageCurrencies = Set(amounts.flatMap(\.amount.currencyCandidates))
        if messageCurrencies.count == 1, let only = messageCurrencies.first {
            for i in amounts.indices where amounts[i].amount.currencyCandidates.isEmpty {
                amounts[i].amount.currencyCandidates = [only]
            }
        }

        let summaryValue = Lexicon.summaryField.first(ns).flatMap { $0.group(1, in: ns)?.trimmingCharacters(in: .whitespaces) }

        // 6. 组装交易
        var events: [ParsedEvent] = []
        var usedBalances = Set<Int>()
        let transactionAmounts = amounts.enumerated().filter { $0.element.role == .transaction }
        let feeAmounts = amounts.enumerated().filter { $0.element.role == .fee }
        let singleTransaction = transactionAmounts.count == 1
        var nextPart = 0

        func sentenceText(_ index: Int) -> String {
            guard sentences.indices.contains(index) else { return cleaned }
            return ns.substring(with: sentences[index])
        }

        // 「向尾号6621账户转账」里的尾号是对方账户，不是本条通知所属的账户
        func isCounterpartyTail(_ mention: Mention<String>) -> Bool {
            let start = max(0, mention.range.location - 4)
            let before = ns.substring(with: NSRange(location: start, length: mention.range.location - start))
            return counterpartyTailMarker.test(before)
        }

        func nearestTail(before location: Int, sentence: Int) -> (String?, String?) {
            let range = sentences.indices.contains(sentence) ? sentences[sentence] : NSRange(location: 0, length: length)
            let inSentence = tails.filter { $0.range.location >= range.location && $0.range.location < range.location + range.length }
            let own = inSentence.filter { !isCounterpartyTail($0) }
            let ownAll = tails.filter { !isCounterpartyTail($0) }
            let primary = own.last(where: { $0.range.location < location }) ?? own.first
                ?? ownAll.last(where: { $0.range.location < location }) ?? ownAll.first ?? inSentence.first
            let other = inSentence.first { $0.value != primary?.value }?.value
            return (primary?.value, other)
        }

        // 交易对方提取用「去掉时间」的句子，避免把「张三于10月24日」整段当成对方名称
        var timelessUnits = Array(cleaned.utf16)
        for mention in times {
            for i in mention.range.location..<(mention.range.location + mention.range.length) { timelessUnits[i] = 0x20 }
        }
        let timeless = NSString(string: String(decoding: timelessUnits, as: UTF16.self))

        func nearestTime(before location: Int, sentence: Int) -> WallClock? {
            let range = sentences.indices.contains(sentence) ? sentences[sentence] : NSRange(location: 0, length: length)
            let inSentence = times.filter { $0.range.location >= range.location && $0.range.location < range.location + range.length }
            return (inSentence.last(where: { $0.range.location < location }) ?? inSentence.first ?? times.first)?.value
        }

        let sentencesWithMultipleTransactions = Set(Dictionary(grouping: transactionAmounts, by: { $0.element.sentence }).filter { $0.value.count > 1 }.keys)

        for (index, amount) in transactionAmounts {
            let sentence = sentenceText(amount.sentence)
            let sentenceRange = sentences.indices.contains(amount.sentence) ? sentences[amount.sentence] : NSRange(location: 0, length: length)
            // 逾期/将要发生的扣款属于提醒，不入账
            if Lexicon.reminder.test(sentence), !Lexicon.completed.test(sentence) { continue }

            let prefix = ns.substring(with: NSRange(location: sentenceRange.location, length: amount.range.location - sentenceRange.location))
            let suffix = ns.substring(with: NSRange(location: amount.range.location + amount.range.length, length: sentenceRange.location + sentenceRange.length - amount.range.location - amount.range.length))
            var detection = detectKind(prefix: prefix, suffix: suffix, summary: summaryValue, message: singleTransaction ? cleaned + "\n" + subject : nil)
            if detection.status == .posted, Lexicon.failed.test(sentence) || (singleTransaction && Lexicon.failed.test(cleaned)) {
                detection.status = .failed
            }
            if detection.direction == nil, detection.kind == .other, amount.negative { detection.direction = .outflow }

            let (tail, otherTail) = nearestTail(before: amount.range.location, sentence: amount.sentence)
            let time = nearestTime(before: amount.range.location, sentence: amount.sentence)
            let counterparty = extractCounterparty(sentence: timeless.substring(with: sentenceRange), summary: summaryValue)
            let reference = references.first { $0.range.location >= sentenceRange.location && $0.range.location < sentenceRange.location + sentenceRange.length }?.value
                ?? (singleTransaction && references.count == 1 ? references[0].value : nil)

            // 余额：同一句里交易金额之后的余额；只有一笔交易时也接受后面句子里的余额
            var balance: AmountText?
            var balanceIndex: Int?
            if let found = amounts.enumerated().first(where: { $0.offset > index && $0.element.role == .balance && ($0.element.sentence == amount.sentence || singleTransaction) && !usedBalances.contains($0.offset) }) {
                balance = found.element.negative ? nil : found.element.amount
                balanceIndex = found.offset
            }
            if let balanceIndex { usedBalances.insert(balanceIndex) }

            // 手续费：「含手续费」拆分；同句单列的手续费作为另一笔
            let sentenceFees = feeAmounts.filter { $0.element.sentence == amount.sentence }
            let included = sentenceFees.first { $0.element.includedFee }?.element.amount

            var issue: PendingReason?
            if sentencesWithMultipleTransactions.contains(amount.sentence) { issue = .ambiguousAmount }
            if issue == nil, detection.uncertain { issue = .uncertainKind }
            if issue == nil, case .failure(.ambiguous) = trialParse(amount.amount) { issue = .ambiguousAmount }

            let part = nextPart
            nextPart += 2
            let draft = EventDraft(
                amount: amount.amount, direction: detection.direction, kind: detection.kind, status: detection.status,
                counterparty: counterparty, cardTail: tail, counterpartyTail: otherTail, transactionTime: time,
                bankReference: reference, balanceAfter: balance, includedFee: included, isSplitFee: false,
                partIndex: part, bankHint: bankHint, evidenceSnippet: String(sentence.prefix(160))
            )
            events.append(ParsedEvent(draft: draft, issue: issue))
            for fee in sentenceFees {
                var feeDraft = draft
                feeDraft.amount = fee.element.amount
                feeDraft.kind = .fee
                feeDraft.direction = .outflow
                feeDraft.isSplitFee = fee.element.includedFee
                feeDraft.includedFee = nil
                feeDraft.balanceAfter = nil
                feeDraft.bankReference = nil
                feeDraft.counterparty = nil
                feeDraft.partIndex = part + 1
                events.append(ParsedEvent(draft: feeDraft, issue: issue))
            }
        }

        // 没有交易金额、只有手续费（例如「扣收年费 100 元」）
        if transactionAmounts.isEmpty {
            for (_, fee) in feeAmounts where !fee.includedFee {
                let sentence = sentenceText(fee.sentence)
                if Lexicon.reminder.test(sentence), !Lexicon.completed.test(sentence) { continue }
                let (tail, _) = nearestTail(before: fee.range.location, sentence: fee.sentence)
                var status: SettlementStatus = .posted
                if Lexicon.failed.test(sentence) { status = .failed }
                let draft = EventDraft(
                    amount: fee.amount, direction: .outflow, kind: .fee, status: status, counterparty: nil, cardTail: tail,
                    counterpartyTail: nil, transactionTime: nearestTime(before: fee.range.location, sentence: fee.sentence),
                    bankReference: nil, balanceAfter: nil, includedFee: nil, isSplitFee: false, partIndex: nextPart,
                    bankHint: bankHint, evidenceSnippet: String(sentence.prefix(160))
                )
                nextPart += 2
                events.append(ParsedEvent(draft: draft, issue: nil))
            }
        }

        // 同一封邮件里重复出现的同一笔（例如正文和摘要各写一次）只保留一次
        var seen = Set<String>()
        events = events.filter { event in
            let d = event.draft
            let key = [d.amount.digits, d.cardTail ?? "", d.kind.rawValue, d.direction?.rawValue ?? "", d.transactionTime?.sortKey ?? "", d.isSplitFee ? "f" : "", d.balanceAfter?.digits ?? ""].joined(separator: "|")
            return seen.insert(key).inserted
        }

        let balances: [ParsedBalance] = amounts.enumerated()
            .filter { $0.element.role == .balance && !usedBalances.contains($0.offset) }
            .map { item in
                let (tail, _) = nearestTail(before: item.element.range.location, sentence: item.element.sentence)
                return ParsedBalance(amount: item.element.amount, negative: item.element.negative, cardTail: tail, transactionTime: nearestTime(before: item.element.range.location, sentence: item.element.sentence))
            }

        // 7. 整条通知的类别
        let strongEvents = events.filter { $0.issue == nil && $0.draft.cardTail != nil }
        if !events.isEmpty {
            if Lexicon.marketing.test(cleaned), strongEvents.isEmpty, tails.isEmpty { return result(.marketing) }
            return result(.transaction, events, balances)
        }
        if !transactionAmounts.isEmpty || !feeAmounts.isEmpty {
            // 有金额，但全部是提醒句
            if Lexicon.reminder.test(cleaned) { return result(.reminder) }
        }
        if Lexicon.limitChange.test(cleaned) { return result(.creditLimitChange) }
        if !balances.isEmpty, !Lexicon.marketing.test(cleaned) || !tails.isEmpty { return result(.balanceSnapshot, [], balances) }
        if Lexicon.marketing.test(cleaned) { return result(.marketing) }
        if Lexicon.reminder.test(cleaned) || amounts.contains(where: { $0.role == .due }) { return result(.reminder) }
        return result(.unrecognized)
    }

    // MARK: 工具函数

    private static func trialParse(_ amount: AmountText) -> Result<Int64, AmountParser.Failure> {
        let exponent = (amount.preferredCurrency ?? amount.currencyCandidates.first)?.minorUnitExponent ?? 2
        return AmountParser.minorUnits(amount.digits, exponent: exponent)
    }

    private static func roleFor(window: String) -> (Lexicon.Role?, Bool) {
        let ns = NSString(string: window)
        var best: (role: Lexicon.Role, end: Int)?
        for (role, rx) in Lexicon.roleLabels {
            guard let last = rx.matches(ns).last else { continue }
            let end = last.range.location + last.range.length
            if let current = best {
                // 距离相同（例如「应还款额」同时命中「还款」）时，非交易标签优先
                if end > current.end || (end == current.end && current.role == .transaction && role != .transaction) {
                    best = (role, end)
                }
            } else {
                best = (role, end)
            }
        }
        guard let best else { return (nil, false) }
        let included = best.role == .fee && Lexicon.includedFee.test(window)
        return (best.role, included)
    }

    struct KindDetection {
        var kind: TransactionKind
        var direction: FlowDirection?
        var status: SettlementStatus
        var uncertain: Bool
    }

    static func detectKind(prefix: String, suffix: String, summary: String?, message: String?) -> KindDetection {
        func lastRule(in text: String) -> (Lexicon.KindRule, Int)? {
            let ns = NSString(string: text)
            var best: (Lexicon.KindRule, Int)?
            for rule in Lexicon.kindRules {
                guard let m = rule.rx.matches(ns).last else { continue }
                let end = m.range.location + m.range.length
                if best == nil || end > best!.1 { best = (rule, end) }
            }
            return best
        }
        func firstRule(in text: String) -> Lexicon.KindRule? {
            let ns = NSString(string: text)
            var best: (Lexicon.KindRule, Int)?
            for rule in Lexicon.kindRules {
                guard let m = rule.rx.first(ns) else { continue }
                if best == nil || m.range.location < best!.1 { best = (rule, m.range.location) }
            }
            return best?.0
        }
        func cueDirection(_ text: String) -> FlowDirection? {
            let ns = NSString(string: text)
            let inflow = Lexicon.inflowCue.matches(ns).last.map { $0.range.location + $0.range.length }
            let outflow = Lexicon.outflowCue.matches(ns).last.map { $0.range.location + $0.range.length }
            switch (inflow, outflow) {
            case let (i?, o?): return i >= o ? .inflow : .outflow
            case (.some, nil): return .inflow
            case (nil, .some): return .outflow
            default: return nil
            }
        }

        // 预授权、冻结等状态词可能出现在句中任意位置
        let around = (prefix + " " + suffix).replacingOccurrences(of: "预授权完成", with: "")
        // 金额后面的「手续费 2 元」描述的是另一笔，不用来判断这一笔的性质
        let suffixForKind = feeClause.replace(suffix, with: " ")
        let rule = lastRule(in: prefix)?.0 ?? summary.flatMap(firstRule(in:)) ?? firstRule(in: suffixForKind) ?? message.flatMap(firstRule(in:))
        var status: SettlementStatus = .posted
        if let statusRule = Lexicon.kindRules.first(where: { $0.status != .posted && $0.rx.test(around) }) { status = statusRule.status }
        let cue = cueDirection(prefix) ?? cueDirection(suffix) ?? summary.flatMap(cueDirection)

        guard let rule else {
            if let cue { return KindDetection(kind: .other, direction: cue, status: status, uncertain: false) }
            return KindDetection(kind: .other, direction: nil, status: status, uncertain: true)
        }
        if rule.status != .posted { status = rule.status }
        if rule.transferGeneric {
            guard let cue else { return KindDetection(kind: .other, direction: nil, status: status, uncertain: true) }
            return KindDetection(kind: cue == .inflow ? .transferIn : .transferOut, direction: cue, status: status, uncertain: false)
        }
        switch rule.kind {
        case .reversal:
            return KindDetection(kind: .reversal, direction: cue ?? .inflow, status: status, uncertain: false)
        case .repayment:
            // 方向不明时交给入账服务按账户类型决定（信用卡收到还款 / 借记卡付出还款）
            return KindDetection(kind: .repayment, direction: cue, status: status, uncertain: false)
        default:
            return KindDetection(kind: rule.kind, direction: rule.direction ?? cue, status: status, uncertain: rule.direction == nil && cue == nil)
        }
    }

    static func extractCounterparty(sentence: String, summary: String?) -> String? {
        let ns = NSString(string: sentence)
        for pattern in counterpartyPatterns {
            for match in pattern.matches(ns) {
                guard var value = match.group(1, in: ns) else { continue }
                value = value.replacingOccurrences(of: #"于\s*\d.*$"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"^(?:您的?|贵方)"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s*(?:于|在)\s*$"#, with: "", options: .regularExpression)
                value = value.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if value.count < 2 || counterpartyNoise.test(value) { continue }
                return value
            }
        }
        if let summary, !genericSummary.contains(summary), !counterpartyNoise.test(summary), summary.count >= 2 {
            return summary
        }
        return nil
    }

    private static func splitRanges(_ ns: NSString, by rx: Rx) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for m in rx.matches(ns) {
            let end = m.range.location + m.range.length
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
            start = end
        }
        if start < ns.length { ranges.append(NSRange(location: start, length: ns.length - start)) }
        return ranges
    }

    private static func monthNumber(_ name: String?) -> Int? {
        guard let name = name?.lowercased().prefix(3) else { return nil }
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(name)).map { $0 + 1 }
    }

    private static func makeClock(year: String?, month: String?, day: String?, hour: String?, minute: String?, second: String?, reference: Date, calendar: Calendar) -> WallClock? {
        let m = month.flatMap(Int.init)
        let d = day.flatMap(Int.init)
        let h = hour.flatMap(Int.init)
        let mi = minute.flatMap(Int.init)
        let s = second.flatMap(Int.init)
        if let m, !(1...12).contains(m) { return nil }
        if let d, !(1...31).contains(d) { return nil }
        if let h, !(0...23).contains(h) { return nil }
        if let mi, !(0...59).contains(mi) { return nil }
        if let s, !(0...59).contains(s) { return nil }
        guard (m != nil && d != nil) || (h != nil && mi != nil) else { return nil }
        var y = year.flatMap(Int.init)
        var inferred = false
        if y == nil, let m, let d {
            let refYear = calendar.component(.year, from: reference)
            y = refYear
            inferred = true
            if let candidate = calendar.date(from: DateComponents(year: refYear, month: m, day: d)), candidate > reference.addingTimeInterval(2 * 86_400) {
                y = refYear - 1
            }
        }
        if m == nil { y = nil; inferred = false }
        return WallClock(year: y, month: m, day: d, hour: h, minute: mi, second: s, yearInferred: inferred)
    }

    /// 「10月24日 」与「14:30」分开写时合并成一个时间。
    private static func mergeAdjacentDateAndTime(_ mentions: [Mention<WallClock>], in ns: NSString) -> [Mention<WallClock>] {
        var output: [Mention<WallClock>] = []
        for mention in mentions {
            if var last = output.last, last.value.hasDate, !last.value.hasTime, !mention.value.hasDate, mention.value.hasTime {
                let gapStart = last.range.location + last.range.length
                let gap = mention.range.location - gapStart
                if gap >= 0, gap <= 3, ns.substring(with: NSRange(location: gapStart, length: gap)).trimmingCharacters(in: .whitespaces).isEmpty {
                    last.value.hour = mention.value.hour
                    last.value.minute = mention.value.minute
                    last.value.second = mention.value.second
                    last.range = NSRange(location: last.range.location, length: mention.range.location + mention.range.length - last.range.location)
                    output[output.count - 1] = last
                    continue
                }
            }
            output.append(mention)
        }
        return output
    }
}

/// 金额旁的币种写法。
enum CurrencyTokens {
    struct Found {
        var candidates: [CurrencyCode]
        var preferred: CurrencyCode?
        var symbolOnly: Bool
    }

    private static let dollarFamily: [CurrencyCode] = ["USD", "HKD", "SGD", "AUD", "CAD", "TWD", "NZD", "MOP"].map { CurrencyCode($0) }

    // 按长度从长到短匹配
    private static let tokens: [(String, [CurrencyCode], CurrencyCode?, Bool)] = [
        ("人民币", [.cny], .cny, false), ("澳门元", [CurrencyCode("MOP")], nil, false), ("瑞士法郎", [.chf], nil, false),
        ("新台币", [CurrencyCode("TWD")], nil, false), ("US$", [.usd], nil, false), ("HK$", [.hkd], nil, false),
        ("NT$", [CurrencyCode("TWD")], nil, false), ("S$", [CurrencyCode("SGD")], nil, false), ("A$", [CurrencyCode("AUD")], nil, false),
        ("C$", [CurrencyCode("CAD")], nil, false), ("RMB", [.cny], nil, false), ("CNY", [.cny], nil, false), ("EUR", [.eur], nil, false),
        ("USD", [.usd], nil, false), ("HKD", [.hkd], nil, false), ("GBP", [.gbp], nil, false), ("JPY", [.jpy], nil, false),
        ("CHF", [.chf], nil, false), ("SGD", [CurrencyCode("SGD")], nil, false), ("AUD", [CurrencyCode("AUD")], nil, false),
        ("CAD", [CurrencyCode("CAD")], nil, false), ("MOP", [CurrencyCode("MOP")], nil, false), ("TWD", [CurrencyCode("TWD")], nil, false),
        ("KRW", [CurrencyCode("KRW")], nil, false), ("SEK", [CurrencyCode("SEK")], nil, false), ("NOK", [CurrencyCode("NOK")], nil, false),
        ("DKK", [CurrencyCode("DKK")], nil, false), ("PLN", [CurrencyCode("PLN")], nil, false), ("CZK", [CurrencyCode("CZK")], nil, false),
        ("HUF", [CurrencyCode("HUF")], nil, false), ("美元", [.usd], nil, false), ("欧元", [.eur], nil, false), ("港币", [.hkd], nil, false),
        ("港元", [.hkd], nil, false), ("英镑", [.gbp], nil, false), ("日元", [.jpy], nil, false), ("韩元", [CurrencyCode("KRW")], nil, false),
        ("澳元", [CurrencyCode("AUD")], nil, false), ("加元", [CurrencyCode("CAD")], nil, false),
        ("€", [.eur], nil, false), ("£", [.gbp], nil, false), ("円", [.jpy], nil, false), ("₩", [CurrencyCode("KRW")], nil, false),
    ]

    static func prefix(in before: String) -> Found? {
        let trimmed = before.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        for (token, candidates, preferred, symbolOnly) in tokens where upper.hasSuffix(token.uppercased()) {
            // 「EUR」之类的字母代码前面不能紧跟字母（避免把单词的一部分当成币种）
            if token.first!.isLetter, token.first!.isASCII {
                let rest = upper.dropLast(token.count)
                if let previous = rest.last, previous.isASCII, previous.isLetter { continue }
            }
            return Found(candidates: candidates, preferred: preferred, symbolOnly: symbolOnly)
        }
        if trimmed.hasSuffix("¥") { return Found(candidates: [.cny, .jpy], preferred: nil, symbolOnly: true) }
        if trimmed.hasSuffix("$") { return Found(candidates: dollarFamily, preferred: nil, symbolOnly: true) }
        return nil
    }

    static func suffix(in after: String) -> Found? {
        let trimmed = after.drop { $0 == " " }
        let upper = trimmed.uppercased()
        for (token, candidates, preferred, symbolOnly) in tokens where upper.hasPrefix(token.uppercased()) {
            if token.first!.isLetter, token.first!.isASCII {
                let rest = upper.dropFirst(token.count)
                if let next = rest.first, next.isASCII, next.isLetter { continue }
            }
            return Found(candidates: candidates, preferred: preferred, symbolOnly: symbolOnly)
        }
        if trimmed.hasPrefix("元") || trimmed.hasPrefix("圆") {
            return Found(candidates: [.cny, .hkd, CurrencyCode("MOP"), CurrencyCode("TWD")], preferred: .cny, symbolOnly: true)
        }
        return nil
    }

    /// 合并前后缀：「人民币100.00元」→ CNY；「¥100」在中文通知里优先 CNY，但保留 JPY 候选。
    static func combine(_ prefix: Found?, _ suffix: Found?, chineseText: Bool) -> (candidates: [CurrencyCode], preferred: CurrencyCode?) {
        switch (prefix, suffix) {
        case (nil, nil):
            return ([], nil)
        case let (p?, nil):
            return (p.candidates, p.preferred ?? (p.candidates.count == 1 ? p.candidates[0] : (chineseText && p.candidates.contains(.cny) ? .cny : nil)))
        case let (nil, s?):
            return (s.candidates, s.preferred ?? (s.candidates.count == 1 ? s.candidates[0] : nil))
        case let (p?, s?):
            let intersection = p.candidates.filter(s.candidates.contains)
            if !intersection.isEmpty {
                let preferred = intersection.count == 1 ? intersection[0] : (p.preferred ?? s.preferred)
                return (intersection, preferred)
            }
            // 「美元100元」这类：明确的代码优先于泛用的「元」
            if !p.symbolOnly { return (p.candidates, p.candidates.count == 1 ? p.candidates[0] : p.preferred) }
            if !s.symbolOnly { return (s.candidates, s.candidates.count == 1 ? s.candidates[0] : s.preferred) }
            return (p.candidates + s.candidates, nil)
        }
    }
}
