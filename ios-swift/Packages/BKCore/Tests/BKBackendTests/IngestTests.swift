import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

final class IngestTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend(path: String? = nil) throws -> LedgerBackend {
        let now = self.now
        let database = try path.map { try Database(path: $0) } ?? Database.inMemory()
        return LedgerBackend(database: database, calendar: calendar, clock: { now })
    }

    func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-ingest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.sqlite").path
    }

    @discardableResult
    func addAccount(_ backend: LedgerBackend, bank: String = "cmb", bankName: String = "招商银行", last4: String, type: CardType = .debit, currency: CurrencyCode = .cny) async throws -> Account {
        try await backend.addAccount(AccountDraft(name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: currency, paletteID: "ocean"))
    }

    let purchase = "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元，余额1,234.56元。"

    // MARK: 基本入账

    func testPurchaseIsRecordedWithAllFields() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        XCTAssertEqual(result.outcome, .recorded)
        XCTAssertEqual(result.recordedCount, 1)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        let r = rows[0].record
        XCTAssertEqual(r.accountID, account.id)
        XCTAssertEqual(r.amountMinor, 3800)
        XCTAssertEqual(r.currency, .cny)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.counterparty, "星巴克咖啡")
        XCTAssertEqual(r.balanceAfterMinor, 123_456)
        XCTAssertNil(r.receivedAt, "系统没提供接收时间时不伪造")
        XCTAssertEqual(r.processedAt, now)
        XCTAssertEqual(rows[0].last4, "0427")
        let status = try await backend.automationStatus()
        XCTAssertEqual(status[account.id]?.lastSuccessAt, now)
        XCTAssertEqual(status[account.id]?.lastSuccessSource, .sms)
    }

    func testAccountCurrencyUsedWhenMessageHasNone() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "x", bankName: "Example Bank", last4: "3305", currency: .eur)
        _ = try await backend.ingest(IngestRequest(text: "Card ending 3305 debited 12,50 for purchase at REWE on 24.10.2026 13:02", source: .sms))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.currency, .eur)
        XCTAssertEqual(r.amountMinor, 1250)
    }

    // MARK: 幂等与并发

    func testSameInputTwiceIsIdempotent() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        let second = try await backend.ingest(IngestRequest(text: purchase + "  ", source: .sms, sender: "95555"))
        XCTAssertEqual(second.outcome, .duplicateInput)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testConcurrentSameInputRecordsOnce() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let text = purchase
        try await withThrowingTaskGroup(of: IngestResult.self) { group in
            for _ in 0..<20 { group.addTask { try await backend.ingest(IngestRequest(text: text, source: .sms, sender: "95555")) } }
            for try await _ in group {}
        }
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testTwoConnectionsToSameFileDoNotDoubleRecord() async throws {
        // 模拟两个自动化同时命中、由两个独立连接写入同一个数据库文件
        let path = tempPath()
        let first = try makeBackend(path: path)
        try await addAccount(first, last4: "0427")
        let second = try makeBackend(path: path)
        let text = purchase
        async let a = first.ingest(IngestRequest(text: text, source: .sms, sender: "95555"))
        async let b = second.ingest(IngestRequest(text: text, source: .sms, sender: "95555"))
        let outcomes = try await [a.outcome, b.outcome].sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(Set(outcomes), [.recorded, .duplicateInput])
        let count = try await first.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testDistinctIdenticalTextsWithDifferentReceivedTimesAreNotSilentlyMerged() async throws {
        // 两条完全相同的短信、系统给出不同接收时间：可能是两笔真实交易，不能静默合并
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let text = "您尾号0427账户10月24日14:30消费5.00元【招商银行】"
        _ = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: now.addingTimeInterval(-60)))
        let second = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: now))
        XCTAssertEqual(second.outcome, .pending)
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .possibleDuplicate)
        // 用户确认是另一笔真实交易
        try await backend.confirmPending(id: pending[0].id, accountID: pending[0].candidateAccountIDs[0])
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: 跨来源

    func testSmsAndEmailForSameTransactionMerge() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427的储蓄卡于2026年10月24日14:30消费人民币38.00元。【招商银行】", source: .sms, sender: "95555"))
        let email = try await backend.ingest(IngestRequest(text: "<p>您尾号0427的储蓄卡于2026-10-24 14:30在星巴克咖啡消费人民币38.00元。</p>", source: .email, sender: "notice@cmbchina.com", subject: "交易提醒"))
        XCTAssertEqual(email.outcome, .mergedDuplicate)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        let detail = try await backend.recordDetail(id: rows[0].id)
        XCTAssertEqual(Set(detail.evidence.map(\.source)), [.sms, .email])
    }

    func testWeakCrossSourceMatchGoesToPending() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户消费人民币38.00元【招商银行】", source: .sms))
        let email = try await backend.ingest(IngestRequest(text: "您尾号0427的储蓄卡消费人民币38.00元。", source: .email, sender: "notice@cmbchina.com"))
        XCTAssertEqual(email.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .possibleDuplicate)
        try await backend.ignorePending(id: item.id)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1, "用户确认重复：不新增，原记录增加来源证据")
        let detail = try await backend.recordDetail(id: rows[0].id)
        XCTAssertEqual(detail.evidence.count, 2)
    }

    func testSameAmountSameMerchantSameSourceDifferentTimesAreBothKept() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:01在地铁消费3.00元，余额100.00元【招商银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:40在地铁消费3.00元，余额97.00元【招商银行】", source: .sms))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: 账户匹配

    func testSameTailAcrossBanksUsesSender() async throws {
        let backend = try makeBackend()
        let cmb = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms, sender: "95555"))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, cmb.id)
    }

    func testSameTailWithoutBankEvidenceGoesToPendingAndCanBeConfirmed() async throws {
        let backend = try makeBackend()
        let cmb = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        let result = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .ambiguousAccount)
        XCTAssertEqual(item.candidateAccountIDs.count, 2)
        try await backend.confirmPending(id: item.id, accountID: cmb.id)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, cmb.id)
        XCTAssertEqual(r.amountMinor, 2000)
        let remaining = try await backend.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    func testBoundAccountResolvesSameTail() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        let icbc = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms, boundAccountID: icbc.id))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, icbc.id)
    }

    func testBoundAccountDoesNotOverrideDifferentTail() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "1111")
        let b = try await addAccount(backend, last4: "2222")
        _ = try await backend.ingest(IngestRequest(text: "您尾号2222账户10月24日消费20.00元【招商银行】", source: .sms, boundAccountID: a.id))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, b.id, "正文尾号优先于自动化绑定")
    }

    func testMessageWithoutTailNeedsConfirmation() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "1111")
        let result = try await backend.ingest(IngestRequest(text: "【招商银行】您的账户10月24日消费20.00元", source: .email, boundAccountID: a.id))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .missingCardTail)
        XCTAssertEqual(item.candidateAccountIDs, [a.id])
    }

    func testNotificationBeforeAccountCreationIsRecordedAfterAdding() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .noMatchingAccount)
        try await addAccount(backend, last4: "0427")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
        let open = try await backend.pendingCount()
        XCTAssertEqual(open, 0)
    }

    func testPendingCannotBeUsedForManualEntry() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        let other = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "9999")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms))
        let item = try await backend.openPendingItems()[0]
        do {
            try await backend.confirmPending(id: item.id, accountID: other.id)
            XCTFail("不在候选里的账户不能确认")
        } catch BackendError.accountNotACandidate {}
        _ = a
        // 无法识别的通知只能忽略
        _ = try await backend.ingest(IngestRequest(text: "【某银行】您尾号0427的账户信息已更新。", source: .sms))
        let unrecognized = try await backend.openPendingItems().first { $0.reason == .unrecognized }!
        do {
            try await backend.confirmPending(id: unrecognized.id, accountID: a.id)
            XCTFail("无法识别的通知不能确认入账")
        } catch BackendError.confirmationNotAllowed {}
    }

    // MARK: 非交易信息

    func testFilteredMessagesAreLoggedNotDropped() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】验证码：482913，您正在支付100.00元。", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】尊敬的客户，分期优惠，最高可借50,000元，回T退订", source: .sms))
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(Set(log.map(\.classification)), [.verificationCode, .marketing])
        XCTAssertNil(log.first { $0.classification == .verificationCode }?.rawText, "验证码正文不保存")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
    }

    func testEmptyInputIsLogged() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: "   ", source: .sms))
        XCTAssertEqual(result.classification, .empty)
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.first?.classification, .empty)
    }

    func testFailedAndHoldAreKeptButNotCounted() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月24日在苹果商店消费68.00元交易失败。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月24日在某某酒店预授权人民币2,000.00元。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(Set(rows.map(\.record.status)), [.failed, .hold])
        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertTrue(stats.currencies.isEmpty)
        XCTAssertEqual(stats.failedCount, 1)
        XCTAssertEqual(stats.holdCount, 1)
    }

    // MARK: 余额

    func testBalanceUsesNotificationTimeNotArrivalOrder() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元，余额900.00元【招商银行】", source: .sms))
        // 较早的一条迟到
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日09:00消费100.00元，余额910.00元【招商银行】", source: .sms))
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.bankReported?.amountMinor, 90_000)
        XCTAssertEqual(summary?.ledgerDerivedMinor, 90_000)
        XCTAssertEqual(summary?.recordsAfterBase, 0)
    }

    func testDerivedBalanceUnknownWithoutBase() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元【招商银行】", source: .sms))
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertNil(summary?.bankReported)
        XCTAssertNil(summary?.ledgerDerivedMinor, "没有银行余额基准时显示未知")
    }

    func testDerivedBalanceAddsLaterRecords() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户2026年10月24日09:00消费10.00元，余额900.00元【招商银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户2026年10月24日11:00收入人民币50.00元【招商银行】", source: .sms))
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.bankReported?.amountMinor, 90_000)
        XCTAssertEqual(summary?.ledgerDerivedMinor, 95_000)
        XCTAssertEqual(summary?.recordsAfterBase, 1)
    }

    // MARK: 多币种账户

    func testMultiCurrencyAccountKeepsBalancesPerCurrency() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: nil, bankName: "恒生银行", last4: "8801", cardType: .debit, currency: .hkd, paletteID: "ocean",
            openingBalanceMinor: 1_000_00, extraCurrencies: [.usd, .hkd, .cny], extraOpeningBalances: [.usd: 200_00]
        ))
        XCTAssertEqual(account.extraCurrencies, [.usd, .cny], "主币种和重复项被去掉")
        XCTAssertEqual(account.currencies, [.hkd, .usd, .cny])

        _ = try await backend.ingest(IngestRequest(text: "您尾号8801的账户于10月24日14:30消费美元12.50元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8801的账户于10月24日15:30消费港币100.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(120)))
        // 只写了「元」：记为主币种
        _ = try await backend.ingest(IngestRequest(text: "您尾号8801的账户于10月24日16:30消费20.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(180)))
        // ¥ 在中文通知里可能是人民币或日元：账户持有人民币，记为人民币
        _ = try await backend.ingest(IngestRequest(text: "您尾号8801的账户于10月24日17:30消费¥30.00【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(240)))

        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(Set(rows.map(\.record.currency)), [.usd, .hkd, .cny])

        let balances = try XCTUnwrap(try await backend.balanceSummaries()[account.id])
        XCTAssertEqual(balances.items.map(\.currency), [.hkd, .usd, .cny])
        XCTAssertEqual(balances.item(.hkd)?.ledgerDerivedMinor, 1_000_00 - 100_00 - 20_00)
        XCTAssertEqual(balances.item(.usd)?.ledgerDerivedMinor, 200_00 - 12_50)
        XCTAssertNil(balances.item(.cny)?.ledgerDerivedMinor, "人民币没有起点，余额未知")

        try await backend.setOpeningBalance(accountID: account.id, currency: .cny, amountMinor: 500_00)
        var updated = try await backend.balanceSummaries()[account.id]
        XCTAssertEqual(updated?.item(.cny)?.ledgerDerivedMinor, 500_00 - 30_00, "之后到达的人民币流水加到初始余额上")

        // 去掉人民币：它的初始余额一起删除，已有流水保留
        try await backend.updateCardInfo(accountID: account.id, name: "", cardNumber: nil, extraCurrencies: [.usd])
        let stored = try await backend.accounts().first { $0.id == account.id }
        XCTAssertEqual(stored?.extraCurrencies, [.usd])
        XCTAssertNil(stored?.openingBalance(.cny))
        updated = try await backend.balanceSummaries()[account.id]
        XCTAssertEqual(updated?.items.map(\.currency), [.hkd, .usd])
        let count = try await backend.recordCount(accountID: account.id)
        XCTAssertEqual(count, 4)
    }

    func testSingleCurrencyAccountStillResolvesYenSymbolByPreference() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427", currency: .usd)
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费¥30.00【招商银行】", source: .sms))
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.first?.record.currency, .cny, "账户不持有候选币种时按通知里的首选币种")
    }

    // MARK: 汇率

    func testExchangeRateFeedParsesAndConvertsWithMinorUnits() throws {
        let json = #"{"result":"success","base_code":"USD","time_last_update_unix":1792540800,"rates":{"USD":1,"CNY":7.2,"HKD":7.8,"JPY":150,"BAD":0}}"#
        let rates = try ExchangeRateFeed.parse(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(rates.base, .usd)
        XCTAssertEqual(rates.updatedAt, Date(timeIntervalSince1970: 1_792_540_800))
        XCTAssertNil(rates.rate(CurrencyCode("BAD")), "无效汇率被丢弃")
        XCTAssertEqual(rates.convert(100_00, from: .usd, to: .cny), 720_00)
        XCTAssertEqual(rates.convert(780_00, from: .hkd, to: .cny), 720_00)
        XCTAssertEqual(rates.convert(1_00, from: .usd, to: .jpy), 150, "日元没有小数位")
        XCTAssertEqual(rates.convert(-150, from: .jpy, to: .usd), -1_00)
        XCTAssertNil(rates.convert(1_00, from: CurrencyCode("XYZ"), to: .cny))
        XCTAssertEqual(rates.convert(1_23, from: CurrencyCode("XYZ"), to: CurrencyCode("XYZ")), 1_23)

        XCTAssertThrowsError(try ExchangeRateFeed.parse(Data(#"{"result":"error","error-type":"x"}"#.utf8), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateFeed.parse(Data("not json".utf8), fetchedAt: now))
    }

    func testCardInfoValidatesCardNumberAgainstLast4() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        try await backend.updateCardInfo(accountID: account.id, name: " 工资卡 ", cardNumber: "6225 8801 1234 0427")
        var stored = try await backend.accounts().first
        XCTAssertEqual(stored?.name, "工资卡")
        XCTAssertEqual(stored?.cardNumber, "6225880112340427", "去掉空格保存")

        for invalid in ["6225880112340428", "1234", "6225-8801-12a4-0427"] {
            do {
                try await backend.updateCardInfo(accountID: account.id, name: "工资卡", cardNumber: invalid)
                XCTFail("accepted \(invalid)")
            } catch {
                XCTAssertEqual(error as? BackendError, .invalidAccount(.invalidCardNumber))
            }
        }

        // 名称留空恢复默认名称；卡号留空清除
        try await backend.updateCardInfo(accountID: account.id, name: "", cardNumber: "")
        stored = try await backend.accounts().first
        XCTAssertEqual(stored?.name, "招商银行借记卡")
        XCTAssertNil(stored?.cardNumber)
    }

    func testCardFaceIsStoredAndTextScaleClamped() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        try await backend.updateCardFace(accountID: account.id, paletteID: "midnight", face: CardFace(imageID: "img", textColor: 0x112233, textScale: 5))
        let stored = try await backend.accounts().first
        XCTAssertEqual(stored?.paletteID, "midnight")
        XCTAssertEqual(stored?.face.imageID, "img")
        XCTAssertEqual(stored?.face.textColor, 0x112233)
        XCTAssertEqual(stored?.face.textScale, CardFace.textScaleRange.upperBound)
    }

    func testOpeningBalanceIsBaseUntilBankReportsBalance() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_000
        ))
        XCTAssertEqual(account.openingBalanceMinor, 100_000)
        XCTAssertEqual(account.openingBalanceAt, now)
        // 填写初始余额之前就到达的通知不重复计入
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:00消费20.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(-3600)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:40收入人民币50.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(120)))
        var summaries = try await backend.balanceSummaries()
        var summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertNil(summary.bankReported, "初始余额不冒充银行通知余额")
        XCTAssertEqual(summary.base, .opening)
        XCTAssertEqual(summary.ledgerDerivedMinor, 104_000)
        XCTAssertEqual(summary.ledgerDerivedCurrency, .cny)
        XCTAssertEqual(summary.recordsAfterBase, 2)

        // 之后收到带余额的通知：银行余额更新，成为新的起点
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日15:00消费5.00元，余额1,035.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(180)))
        summaries = try await backend.balanceSummaries()
        summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.base, .bankReported)
        XCTAssertEqual(summary.bankReported?.amountMinor, 103_500)
        XCTAssertEqual(summary.ledgerDerivedMinor, 103_500)
        XCTAssertEqual(summary.openingBalanceMinor, 100_000, "初始余额仍单独保留")
    }

    func testOpeningBalanceSetLaterReplacesOlderBankBalanceAndCanBeCleared() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日09:00消费10.00元，余额900.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(-7200)))
        try await backend.setOpeningBalance(accountID: account.id, amountMinor: -50_000)
        var summaries = try await backend.balanceSummaries()
        var summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.base, .opening, "比银行余额更晚填写的初始余额作为起点")
        XCTAssertEqual(summary.bankReported?.amountMinor, 90_000, "银行通知余额照常保留")
        XCTAssertEqual(summary.ledgerDerivedMinor, -50_000)

        try await backend.setOpeningBalance(accountID: account.id, amountMinor: nil)
        summaries = try await backend.balanceSummaries()
        summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.base, .bankReported)
        XCTAssertEqual(summary.ledgerDerivedMinor, 90_000)
        XCTAssertNil(summary.openingBalanceMinor)

        do {
            try await backend.setOpeningBalance(accountID: "missing", amountMinor: 1)
            XCTFail("不存在的账户")
        } catch BackendError.notFound {}
    }

    func testMessageWithoutMoneyOrTailIsFilteredNotPending() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: "明天下午我要去银行办点事，晚点回你", source: .sms))
        XCTAssertEqual(result.classification, .noFinancialContent)
        XCTAssertEqual(result.outcome, .filtered)
        let pending = try await backend.pendingCount()
        XCTAssertEqual(pending, 0, "关键词误触发的普通短信不进待处理")
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.first?.classification, .noFinancialContent, "但会留在接收日志里")
    }

    func testBalanceOnlyMessageCreatesNoRecord() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户截至10月24日16:00的可用余额为1,234.56元。【招商银行】", source: .sms))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.bankReported?.amountMinor, 123_456)
    }

    // MARK: 内部转账、还款、退款

    func testInternalTransferBetweenOwnCardsIsLinkedAndExcludedFromStats() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】", source: .sms, sender: "95555"))
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】", source: .sms, sender: "95588"))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2, "两边流水都保留")
        XCTAssertEqual(Set(rows.map(\.record.accountID)), [a.id, b.id])
        XCTAssertNotNil(rows[0].record.transferGroupID)
        XCTAssertEqual(rows[0].record.transferGroupID, rows[1].record.transferGroupID)
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 0)
        XCTAssertEqual(cny.incomeMinor, 0)
        XCTAssertEqual(cny.internalTransferMinor, 100_000)
    }

    func testCreditCardRepaymentFromOwnDebitIsNotDoubleCounted() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月10日消费3,000.00元。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月20日10:00还款3,000.00元，余额734.56元【招商银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡于10月20日还款成功，金额3,000.00元已入账。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 3)
        let repayments = rows.filter { $0.record.kind == .repayment }
        XCTAssertEqual(Set(repayments.map(\.record.direction)), [.inflow, .outflow])
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 300_000, "只有信用卡消费计入支出，还款不再重复计为支出")
        XCTAssertEqual(cny.incomeMinor, 0)
    }

    func testRefundKeepsOriginalAndLinks() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月20日消费人民币99.00元，商户：京东商城。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡收到退款人民币99.00元，商户：京东商城。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2, "退款不覆盖、不删除原交易")
        let refund = try XCTUnwrap(rows.first { $0.record.kind == .refund })
        let original = try XCTUnwrap(rows.first { $0.record.kind == .purchase })
        XCTAssertEqual(refund.record.relatedRecordID, original.id)
        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.netExpenseMinor, 0)
    }

    func testIncludedFeeSplitSumsToTotal() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.record.amountMinor).reduce(0, +), 100_200)
        XCTAssertEqual(Set(rows.map(\.record.kind)), [.transferOut, .fee])
    }

    // MARK: 备注与保留期限

    func testOnlyNoteIsEditable() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        let before = try await backend.records()[0].record
        try await backend.updateNote(recordID: before.id, note: "和同事喝咖啡")
        let after = try await backend.records()[0].record
        XCTAssertEqual(after.note, "和同事喝咖啡")
        var expected = before
        expected.note = "和同事喝咖啡"
        XCTAssertEqual(after, expected, "其他字段保持不变")
    }

    func testRawContentPurgedAfterRetentionButFingerprintKept() async throws {
        var current = now
        let database = try Database.inMemory()
        let clockBox = ClockBox(now)
        let backend = LedgerBackend(database: database, calendar: calendar, clock: { clockBox.value })
        try await addAccount(backend, last4: "0427")
        try await backend.setRawRetentionDays(7)
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        current = current.addingTimeInterval(8 * 86_400)
        clockBox.value = current
        let purged = try await backend.purgeExpiredRawContent()
        XCTAssertEqual(purged, 1)
        let log = try await backend.ingestLog()
        XCTAssertNil(log[0].rawText)
        let again = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        XCTAssertEqual(again.outcome, .duplicateInput, "清理正文后仍能识别重复输入")
    }

    func testAddAccountValidation() async throws {
        let backend = try makeBackend()
        do {
            _ = try await addAccount(backend, last4: "12a4")
            XCTFail()
        } catch BackendError.invalidAccount(.invalidLast4) {}
        try await addAccount(backend, last4: "0001")
        do {
            _ = try await addAccount(backend, last4: "0001")
            XCTFail()
        } catch BackendError.invalidAccount(.duplicateAccount) {}
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.map(\.last4), ["0001"])
    }

    func testPaginationIsStable() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        for minute in 0..<7 {
            _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日10:0\(minute)消费1.0\(minute)元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(Double(minute) * 60)))
        }
        var cursor: RecordCursor?
        var seen: [String] = []
        repeat {
            let page = try await backend.records(before: cursor, limit: 3)
            seen += page.map(\.id)
            cursor = page.last.map { RecordCursor(effectiveAt: $0.record.effectiveAt, id: $0.id) }
            if page.count < 3 { break }
        } while true
        XCTAssertEqual(seen.count, 7)
        XCTAssertEqual(Set(seen).count, 7)
    }
}

final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
