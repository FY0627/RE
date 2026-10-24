import Foundation
import XCTest
@testable import BKBackend
import BKModel

/// 解析样例。所有样例都是按银行通知的公开常见写法构造的脱敏文本：
/// 卡号尾号、金额、商户、时间均为虚构，不来自真实用户数据。
final class ParserSampleTests: XCTestCase {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    static let reference = Date(timeIntervalSince1970: 1_792_828_800) // 2026-10-24 16:00 +08:00

    func parse(_ text: String, source: SourceKind = .sms, sender: String? = nil, subject: String? = nil) -> ParsedMessage {
        MessageParser.parse(MessageContext(text: text, source: source, sender: sender, subject: subject, referenceDate: Self.reference, calendar: Self.calendar))
    }

    func single(_ text: String, source: SourceKind = .sms, sender: String? = nil, subject: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> EventDraft? {
        let parsed = parse(text, source: source, sender: sender, subject: subject)
        XCTAssertEqual(parsed.classification, .transaction, "classification", file: file, line: line)
        XCTAssertEqual(parsed.events.count, 1, "event count: \(parsed.events.map(\.draft.amount.digits))", file: file, line: line)
        XCTAssertNil(parsed.events.first?.issue, "issue", file: file, line: line)
        return parsed.events.first?.draft
    }

    // MARK: 消费

    func testPurchaseWithMerchantTimeAndBalance() throws {
        let d = try XCTUnwrap(single("【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元，余额1,234.56元。", sender: "95555"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.amount.digits, "38.00")
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.counterparty, "星巴克咖啡")
        XCTAssertEqual(d.balanceAfter?.digits, "1,234.56")
        XCTAssertEqual(d.transactionTime, WallClock(year: 2026, month: 10, day: 24, hour: 14, minute: 30, yearInferred: true))
        XCTAssertEqual(d.bankHint, "cmb")
    }

    func testCreditCardPurchaseWithoutMerchant() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月23日21:05消费1,280.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertNil(d.counterparty, "商户缺失时不编造")
        XCTAssertEqual(d.bankHint, "boc")
    }

    func testQuickPaymentWithSummaryMerchant() throws {
        let d = try XCTUnwrap(single("您账户6621于10月24日09:12快捷支付支出人民币56.80元，摘要：美团外卖，余额2,003.20元【工商银行】"))
        XCTAssertEqual(d.cardTail, "6621")
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.counterparty, "美团外卖")
    }

    func testEnglishCardPurchaseInEuro() throws {
        let d = try XCTUnwrap(single("Your card ending 3305 was charged EUR 12,50 at REWE MARKT on 24.10.2026 13:02. Available balance: EUR 1.204,30."))
        XCTAssertEqual(d.cardTail, "3305")
        XCTAssertEqual(d.amount.digits, "12,50")
        XCTAssertEqual(d.amount.currencyCandidates, [.eur])
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.counterparty, "REWE MARKT")
        XCTAssertEqual(d.balanceAfter?.digits, "1.204,30")
        XCTAssertEqual(d.transactionTime?.isMinutePrecise, true)
        XCTAssertEqual(d.transactionTime?.day, 24)
    }

    // MARK: 入账

    func testSalaryIncome() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月15日09:30收入人民币12,500.00元，摘要：代发工资，余额13,734.56元【招商银行】"))
        XCTAssertEqual(d.kind, .salary)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertNil(d.counterparty, "「代发工资」是交易性质，不是交易对方")
    }

    func testTransferInFromPerson() throws {
        let d = try XCTUnwrap(single("张三于10月24日10:01向您尾号0427的账户转账500.00元，余额1,734.56元。【招商银行】"))
        XCTAssertEqual(d.kind, .transferIn)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.counterparty, "张三")
    }

    func testTransferOutWithSeparateFee() throws {
        let parsed = parse("您尾号6621卡10月24日11:20跨行转出1,000.00元，手续费2.00元，余额998.00元。【工商银行】")
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertEqual(parsed.events.count, 2)
        let main = parsed.events[0].draft
        let fee = parsed.events[1].draft
        XCTAssertEqual(main.kind, .transferOut)
        XCTAssertEqual(main.amount.digits, "1,000.00")
        XCTAssertNil(main.includedFee)
        XCTAssertEqual(fee.kind, .fee)
        XCTAssertEqual(fee.amount.digits, "2.00")
        XCTAssertFalse(fee.isSplitFee)
        XCTAssertEqual(fee.cardTail, "6621")
        XCTAssertEqual(main.balanceAfter?.digits, "998.00")
    }

    func testFeeIncludedInTotalIsSplitNotDoubleCounted() throws {
        let parsed = parse("您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        XCTAssertEqual(parsed.events.count, 2)
        let main = parsed.events[0].draft
        XCTAssertEqual(main.amount.digits, "1,002.00")
        XCTAssertEqual(main.includedFee?.digits, "2.00")
        XCTAssertEqual(parsed.events[1].draft.kind, .fee)
        XCTAssertTrue(parsed.events[1].draft.isSplitFee)
    }

    func testRefund() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡收到退款人民币99.00元，商户：京东商城。【中国银行】"))
        XCTAssertEqual(d.kind, .refund)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.counterparty, "京东商城")
    }

    func testCreditCardRepaymentReceived() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡于10月20日还款成功，金额3,000.00元已入账。【中国银行】"))
        XCTAssertEqual(d.kind, .repayment)
        XCTAssertEqual(d.direction, .inflow)
    }

    func testDebitRepaymentDirectionResolvedLater() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月20日10:00还款3,000.00元，余额734.56元【招商银行】"))
        XCTAssertEqual(d.kind, .repayment)
        XCTAssertNil(d.direction, "方向由账户类型决定")
    }

    func testLoanInterestCharge() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月21日扣收贷款利息人民币86.40元，余额648.16元。【招商银行】"))
        XCTAssertEqual(d.kind, .interestCharge)
        XCTAssertEqual(d.direction, .outflow)
    }

    func testInterestIncome() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月21日结息入账3.27元，余额737.83元。【招商银行】"))
        XCTAssertEqual(d.kind, .interestIncome)
        XCTAssertEqual(d.direction, .inflow)
    }

    func testStandaloneAnnualFee() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月22日扣收年费200.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .fee)
        XCTAssertEqual(d.amount.digits, "200.00")
    }

    func testCashDepositAndWithdrawal() throws {
        let deposit = try XCTUnwrap(single("您尾号0427账户10月22日现金存入2,000.00元，余额2,737.83元【招商银行】"))
        XCTAssertEqual(deposit.kind, .deposit)
        XCTAssertEqual(deposit.direction, .inflow)
        let withdrawal = try XCTUnwrap(single("您尾号0427账户10月22日ATM取款500.00元，余额2,237.83元【招商银行】"))
        XCTAssertEqual(withdrawal.kind, .withdrawal)
        XCTAssertEqual(withdrawal.direction, .outflow)
    }

    func testReversalOfPurchase() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月23日消费撤销人民币1,280.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .reversal)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.status, .posted)
    }

    func testGenericDebitWithoutKindIsOther() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月22日支出人民币300.00元，余额1,937.83元【招商银行】"))
        XCTAssertEqual(d.kind, .other)
        XCTAssertEqual(d.direction, .outflow)
    }

    // MARK: 状态：失败、预授权、冻结

    func testFailedPayment() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日在苹果商店消费68.00元交易失败，原因：余额不足。【中国银行】"))
        XCTAssertEqual(d.status, .failed)
    }

    func testPreAuthorizationIsHold() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日在某某酒店预授权人民币2,000.00元。【中国银行】"))
        XCTAssertEqual(d.status, .hold)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testPreAuthorizationCompletionIsPosted() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月26日在某某酒店预授权完成人民币1,650.00元。【中国银行】"))
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testPreAuthorizationReleased() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月26日预授权撤销人民币2,000.00元。【中国银行】"))
        XCTAssertEqual(d.status, .holdReleased)
        XCTAssertEqual(d.direction, .inflow)
    }

    // MARK: 非交易信息

    func testVerificationCodeIsFiltered() {
        let parsed = parse("【招商银行】您正在进行网上支付，金额100.00元，验证码：482913，请勿泄露。")
        XCTAssertEqual(parsed.classification, .verificationCode)
        XCTAssertTrue(parsed.events.isEmpty)
    }

    func testSecurityWarningMentioningCodeIsNotOTP() throws {
        let d = try XCTUnwrap(single("您尾号0427的储蓄卡10月24日15:10消费人民币20.00元，余额1,214.56元。银行不会索要验证码。【招商银行】"))
        XCTAssertEqual(d.amount.digits, "20.00")
    }

    func testMarketingIsFiltered() {
        XCTAssertEqual(parse("【某银行】尊敬的客户，信用卡分期优惠来袭，最高可借50,000元，详询客服，回T退订").classification, .marketing)
    }

    func testRepaymentReminderIsNotATransaction() {
        XCTAssertEqual(parse("【中国银行】您尾号8810的信用卡本期账单应还款额3,000.00元，最低还款300.00元，到期还款日11月05日，请按时还款。").classification, .reminder)
        XCTAssertEqual(parse("您尾号8810的信用卡将于10月25日自动扣款3,000.00元，请确保账户资金充足。【中国银行】").classification, .reminder)
    }

    func testStatementEmailIsNotReparsed() {
        let parsed = parse("<html><body><p>尊敬的客户：</p><table><tr><td>10/03</td><td>星巴克</td><td>38.00</td></tr></table></body></html>", source: .email, subject: "中国银行信用卡电子账单")
        XCTAssertEqual(parsed.classification, .statement)
    }

    func testBalanceOnlyNeverInventsTransaction() {
        let parsed = parse("您尾号0427账户截至10月24日16:00的可用余额为1,234.56元。【招商银行】")
        XCTAssertEqual(parsed.classification, .balanceSnapshot)
        XCTAssertTrue(parsed.events.isEmpty)
        XCTAssertEqual(parsed.balances.first?.amount.digits, "1,234.56")
        XCTAssertEqual(parsed.balances.first?.cardTail, "0427")
    }

    func testCreditLimitChangeIsNotMoneyMovement() {
        XCTAssertEqual(parse("您尾号8810的信用卡固定额度已调整为50,000元，即日生效。【中国银行】").classification, .creditLimitChange)
    }

    func testUnrecognizedGoesToPending() {
        XCTAssertEqual(parse("【某银行】您的账户信息已更新。").classification, .unrecognized)
    }

    // MARK: 金额歧义、币种

    func testMultipleTransactionAmountsInOneSentenceAreAmbiguous() {
        let parsed = parse("您尾号0427账户10月24日消费100.00元实际扣款95.00元【招商银行】")
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertTrue(parsed.events.allSatisfy { $0.issue == .ambiguousAmount })
    }

    func testYenSymbolInChineseTextPrefersCNY() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日消费¥45.00【招商银行】"))
        XCTAssertEqual(d.amount.currencyCandidates, [.cny, .jpy])
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
    }

    func testForeignCurrencyCode() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日消费USD 25.99，商户：AMAZON。【中国银行】"))
        XCTAssertEqual(d.amount.currencyCandidates, [.usd])
        XCTAssertEqual(d.counterparty, "AMAZON")
    }

    func testAmountWithoutCurrencyHasNoCandidates() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日消费45.00，余额1,000.00【招商银行】"))
        XCTAssertTrue(d.amount.currencyCandidates.isEmpty, "交给账户币种决定，不按设备地区猜")
    }

    // MARK: 邮件

    func testEmailHTMLIgnoresQuotedHistory() throws {
        let html = """
        <html><body><div>尊敬的客户：</div><div>您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40，余额EUR 1,180.90。</div>
        <blockquote><div>您尾号3305的借记卡于2026-10-20 08:00在BAECKEREI消费EUR 3.20。</div></blockquote></body></html>
        """
        let d = try XCTUnwrap(single(html, source: .email, sender: "notice@example-bank.eu", subject: "交易提醒"))
        XCTAssertEqual(d.amount.digits, "23.40")
        XCTAssertEqual(d.counterparty, "DM DROGERIE")
        XCTAssertEqual(d.transactionTime, WallClock(year: 2026, month: 10, day: 24, hour: 12, minute: 40))
    }

    func testEmailReplyHistoryIsStripped() throws {
        let text = """
        您尾号3305的借记卡于2026-10-24 12:40消费EUR 23.40。
        -----Original Message-----
        您尾号3305的借记卡于2026-10-20 08:00消费EUR 3.20。
        """
        let d = try XCTUnwrap(single(text, source: .email))
        XCTAssertEqual(d.amount.digits, "23.40")
    }

    func testEmailWithMultipleTransactions() {
        let text = """
        交易提醒
        您尾号3305的借记卡于2026-10-24 09:10在BAECKEREI消费EUR 3.20。
        您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40。
        您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40。
        """
        let parsed = parse(text, source: .email)
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertEqual(parsed.events.map(\.draft.amount.digits), ["3.20", "23.40"], "重复行只保留一次，不只取第一笔")
        XCTAssertEqual(parsed.events.map(\.draft.partIndex), [0, 2])
    }

    func testForwardedBankEmailUsesForwardedBody() throws {
        let text = """
        ---------- Forwarded message ----------
        From: notice@example-bank.eu
        Date: 24.10.2026
        Subject: 交易提醒
        您尾号3305的借记卡于2026-10-24 12:40消费EUR 23.40。
        """
        let d = try XCTUnwrap(single(text, source: .email))
        XCTAssertEqual(d.amount.digits, "23.40")
    }

    // MARK: 尾号与日期

    func testCardTailFormats() {
        XCTAssertEqual(parse("卡号**0042于10月24日消费30.00元").events.first?.draft.cardTail, "0042")
        XCTAssertEqual(parse("Card *9912 debited EUR 5.00 on 24 Oct 2026").events.first?.draft.cardTail, "9912")
        XCTAssertEqual(parse("您的借记卡账户0007于10月24日支出100.00元").events.first?.draft.cardTail, "0007")
    }

    func testTwoTailsMarkCounterpartyAccount() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日向尾号6621账户转账200.00元，余额500.00元【招商银行】"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.counterpartyTail, "6621")
        XCTAssertEqual(d.kind, .transferOut)
    }

    func testYearInferenceAcrossNewYear() {
        // 1 月 2 日收到「12月31日」的通知 → 上一年
        var calendar = Self.calendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ref = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9))!
        let parsed = MessageParser.parse(MessageContext(text: "您尾号0427账户12月31日23:50消费10.00元", source: .sms, sender: nil, subject: nil, referenceDate: ref, calendar: calendar))
        XCTAssertEqual(parsed.events.first?.draft.transactionTime?.year, 2026)
    }

    func testAmbiguousSlashDateKeepsNoDate() {
        let parsed = parse("Card ending 3305 debited EUR 5.00 on 03/04/2026 10:00")
        let time = parsed.events.first?.draft.transactionTime
        XCTAssertNil(time?.month, "03/04 无法区分日/月时不写日期")
        XCTAssertEqual(time?.hour, 10)
    }

    func testFullWidthDigitsAndPunctuation() throws {
        let d = try XCTUnwrap(single("您尾号０４２７账户１０月２４日消费人民币３８．００元【招商银行】"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.amount.digits, "38.00")
    }
}
