import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 参考 MOZE 基础记账的部分：支出 / 收入 / 转帐、分类和自动归类、首页合并显示、手动记账、合成一单、按分类统计。
final class LedgerTypeTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    @discardableResult
    func addAccount(_ backend: LedgerBackend, bank: String = "cmb", bankName: String = "招商银行", last4: String, type: CardType = .debit) async throws -> Account {
        try await backend.addAccount(AccountDraft(name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: .cny, paletteID: "ocean"))
    }

    func ingest(_ backend: LedgerBackend, _ text: String, at date: Date? = nil) async throws {
        _ = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: date))
    }

    func category(_ backend: LedgerBackend, _ name: String, type: CategoryType = .expense) async throws -> LedgerCategory {
        let all = try await backend.categories()
        return try XCTUnwrap(all.first { $0.name == name && $0.type == type })
    }

    // MARK: 类型

    func testEntryTypesFollowKindDirectionAndTransfers() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "您尾号0427账户10月22日ATM取款500.00元，余额2,237.83元【招商银行】")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元。")
        try await ingest(backend, "您尾号0427账户10月24日15:00代发工资8,000.00元【招商银行】")
        let rows = try await backend.records()
        let types = Dictionary(uniqueKeysWithValues: rows.map { ($0.record.kind, $0.record.entryType) })
        XCTAssertEqual(types[.withdrawal], .transfer, "取现金是转帐，不算支出")
        XCTAssertEqual(types[.purchase], .expense)
        XCTAssertEqual(types[.salary], .income)

        let transfers = try await backend.records(filter: RecordFilter(entryType: .transfer))
        XCTAssertEqual(transfers.map(\.record.kind), [.withdrawal])
        XCTAssertEqual(transfers.first?.category?.name, "存取现金", "转帐按交易性质对应到转帐分类")
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 38_00)
        XCTAssertEqual(cny.incomeMinor, 8_000_00)
        XCTAssertEqual(cny.transferMinor, 500_00)
    }

    // MARK: 自动归类

    func testFeeSalaryAndInterestAreCategorizedAutomatically() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        try await ingest(backend, "您尾号6621账户10月24日15:00代发工资8,000.00元【工商银行】")
        let rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.kind == .fee }?.category?.name, "手续费")
        XCTAssertEqual(rows.first { $0.record.kind == .salary }?.category?.name, "工资")
        XCTAssertNil(rows.first { $0.record.kind == .transferOut }?.category, "转给谁不知道：待分类")
    }

    func testCategoryIsRememberedByCounterpartyAndMealGuessedByTime() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "您尾号8810的信用卡10月20日12:10消费人民币25.00元，商户：财付通-美团。【中国银行】")
        try await ingest(backend, "您尾号8810的信用卡10月21日19:05消费人民币31.00元，商户：财付通-美团。【中国银行】")
        var waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.count, 2)

        let lunch = try await category(backend, "午餐")
        try await backend.setCategory(recordID: try XCTUnwrap(waiting.first { $0.record.amountMinor == 25_00 }?.id), categoryID: lunch.id, note: "牛肉面")
        waiting = try await backend.uncategorized()
        XCTAssertTrue(waiting.isEmpty, "同一个对方还没分类的一起归类")
        var rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.amountMinor == 25_00 }?.record.note, "牛肉面")
        XCTAssertEqual(rows.first { $0.record.amountMinor == 31_00 }?.category?.name, "晚餐", "按交易时间猜三餐")

        try await ingest(backend, "您尾号8810的信用卡10月24日08:10消费人民币12.00元，商户：财付通-美团。【中国银行】")
        rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.amountMinor == 12_00 }?.category?.name, "早餐", "记住了对方，下次自动归类")
        XCTAssertEqual(rows.first { $0.record.amountMinor == 12_00 }?.category?.parentName, "饮食")
    }

    func testPaymentChannelWithoutMerchantIsNotRemembered() async throws {
        XCTAssertNil(CounterpartyKey.normalize("财付通"))
        XCTAssertNil(CounterpartyKey.normalize("支付宝（中国）网络技术有限公司"))
        XCTAssertNil(CounterpartyKey.normalize("Tenpay"))
        XCTAssertEqual(CounterpartyKey.normalize("财付通-美团"), "财付通-美团")
        XCTAssertEqual(CounterpartyKey.normalize(" Star Bucks "), "starbucks")

        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日10:30在财付通消费人民币20.00元。")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日11:30在财付通消费人民币60.00元。")
        let waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.count, 2)
        let shopping = try await category(backend, "日用品")
        try await backend.setCategory(recordID: waiting[0].id, categoryID: shopping.id)
        let still = try await backend.uncategorizedCount()
        XCTAssertEqual(still, 1, "看不出商户：不一起归类")
    }

    func testRefundFollowsOriginalCategoryAndReducesIt() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "您尾号8810的信用卡10月20日消费人民币99.00元，商户：京东商城。【中国银行】")
        let firstWaiting = try await backend.uncategorized()
        let original = try XCTUnwrap(firstWaiting.first)
        let clothes = try await category(backend, "衣着")
        try await backend.setCategory(recordID: original.id, categoryID: clothes.id)
        try await ingest(backend, "您尾号8810的信用卡收到退款人民币40.00元，商户：京东商城。【中国银行】")

        let rows = try await backend.records()
        let refund = try XCTUnwrap(rows.first { $0.record.kind == .refund })
        XCTAssertEqual(refund.record.entryType, .expense)
        XCTAssertTrue(refund.record.isRefund)
        XCTAssertEqual(refund.category?.id, clothes.id, "退款跟着原交易的分类")
        XCTAssertEqual(rows.first { $0.id == original.id }?.refundedMinor, 40_00)

        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.netExpenseMinor, 59_00)
        XCTAssertEqual(cny.incomeMinor, 0, "退款不算收入")
        XCTAssertEqual(cny.expenseCategories.first { $0.categoryID == clothes.id }?.amountMinor, 59_00)
    }

    func testUnconfirmedTransferIsCategorizedOrRememberedAsOwn() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "您尾号0427账户10月20日10:00向张三转账500.00元【招商银行】")
        try await ingest(backend, "您尾号0427账户10月21日10:00向李四转账200.00元【招商银行】")
        let waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.count, 2, "没确认对方的转账也在待分类里")

        let gift = try await category(backend, "人情")
        let li = try XCTUnwrap(waiting.first { $0.record.counterparty == "李四" })
        try await backend.setCategory(recordID: li.id, categoryID: gift.id)
        let zhang = try XCTUnwrap(waiting.first { $0.record.counterparty == "张三" })
        try await backend.setTransferParty(recordID: zhang.id, party: .own, remember: true)

        var rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.id == li.id }?.record.transferParty, .other, "选了分类就是转给别人")
        XCTAssertEqual(rows.first { $0.id == zhang.id }?.record.entryType, .transfer)

        try await ingest(backend, "您尾号0427账户10月24日10:00向张三转账300.00元【招商银行】")
        try await ingest(backend, "您尾号0427账户10月24日11:00向李四转账100.00元【招商银行】")
        rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.amountMinor == 300_00 }?.record.entryType, .transfer, "记住了张三是自己的账户")
        let second = try XCTUnwrap(rows.first { $0.record.amountMinor == 100_00 })
        XCTAssertEqual(second.record.transferParty, .other)
        XCTAssertEqual(second.category?.id, gift.id)
        let count = try await backend.uncategorizedCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: 首页合并显示

    func testFeedMergesTransferPairsFeesAndHidesFailedHolds() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】")
        try await ingest(backend, "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】")
        try await ingest(backend, "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        try await ingest(backend, "您尾号0427账户10月24日在苹果商店消费68.00元交易失败。【招商银行】")

        let all = try await backend.records()
        XCTAssertEqual(all.count, 5)
        let feed = try await backend.records(filter: RecordFilter(feed: true, mergeFees: true))
        XCTAssertEqual(feed.count, 2, "转帐两边一行、手续费合到那一笔、失败的不进首页")
        let pair = try XCTUnwrap(feed.first { $0.record.entryType == .transfer })
        XCTAssertEqual(pair.record.accountID, a.id, "留下转出那边")
        XCTAssertEqual(pair.peer?.text, "工商银行 ·6621")
        let remit = try XCTUnwrap(feed.first { $0.record.kind == .transferOut && $0.record.accountID == b.id })
        XCTAssertEqual(remit.feeMinor, 2_00)

        let detail = try await backend.records(filter: RecordFilter(accountID: b.id, mergeFees: true))
        XCTAssertEqual(detail.count, 2, "卡片详情里转入那边还在，手续费合并")
        let searched = try await backend.records(filter: RecordFilter(text: "转帐", feed: true))
        XCTAssertEqual(searched.count, 1, "按类型名称也能搜")
    }

    // MARK: 手动记账

    func testManualEntryExpenseAndCreditCardRepayment() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean", openingBalanceMinor: 500_00))
        let card = try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        let debit = try await addAccount(backend, last4: "0427")
        XCTAssertFalse(cash.isCard)
        XCTAssertEqual(cash.displayTitle, "现金")

        let snack = try await category(backend, "饮料零食")
        let time = now.addingTimeInterval(60)
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 15_00, currency: .cny, categoryID: snack.id, counterparty: "便利店", note: "可乐", time: time))
        let last = try await backend.lastManualAccountID()
        XCTAssertEqual(last, cash.id)
        let ids = try await backend.addRecord(ManualEntry(type: .transfer, accountID: debit.id, toAccountID: card.id, amountMinor: 300_00, currency: .cny, time: time))
        XCTAssertEqual(ids.count, 2)

        let rows = try await backend.records()
        let expense = try XCTUnwrap(rows.first { $0.record.accountID == cash.id })
        XCTAssertEqual(expense.record.source, .manual)
        XCTAssertEqual(expense.category?.id, snack.id)
        XCTAssertEqual(expense.record.note, "可乐")
        let repayments = rows.filter { $0.record.kind == .repayment }
        XCTAssertEqual(repayments.count, 2, "转进信用卡算还款")
        XCTAssertTrue(repayments.allSatisfy { $0.record.entryType == .transfer && $0.record.transferGroupID != nil })

        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[cash.id]?.primary?.ledgerDerivedMinor, 485_00)
        let log = try await backend.ingestLog()
        XCTAssertTrue(log.isEmpty, "手动记账不进接收日志")

        // 现金没有卡号：通知里的「0000」不会对上它
        _ = try await backend.ingest(IngestRequest(text: "您尾号0000账户10月24日消费10.00元【招商银行】", source: .sms))
        let cashRows = try await backend.records(accountID: cash.id)
        XCTAssertEqual(cashRows.count, 1)
    }

    func testBankMessageAfterManualEntryAsksIfSame() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        let entry = ManualEntry(type: .expense, accountID: account.id, amountMinor: 38_00, currency: .cny, note: "咖啡", time: now.addingTimeInterval(-3600))
        try await backend.addRecord(entry)
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0427的储蓄卡于10月24日15:58在星巴克咖啡消费人民币38.00元。", source: .sms, receivedAt: now))
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .possibleDuplicate, "手动记过的不再记一次，问是不是同一笔")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)

        let similar = try await backend.similarRecords(to: entry)
        XCTAssertEqual(similar.count, 1, "手动记之前也能查到已有的一笔")
    }

    // MARK: 合成一单

    func testOrderPaidWithTwoCardsMergesIntoOneRow() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在京东消费人民币700.00元。", at: now)
        try await ingest(backend, "您尾号8810的信用卡10月24日14:31消费人民币300.00元，商户：京东商城。【中国银行】", at: now.addingTimeInterval(60))
        let rows = try await backend.records()
        let first = try XCTUnwrap(rows.first { $0.record.amountMinor == 700_00 })
        let candidates = try await backend.orderCandidates(recordID: first.id)
        let second = try XCTUnwrap(candidates.first)
        XCTAssertEqual(second.record.amountMinor, 300_00)
        XCTAssertTrue(LedgerBackend.likelySameOrder(first.record, second.record))

        let home = try await category(backend, "日用品")
        try await backend.setCategory(recordID: first.id, categoryID: home.id)
        try await backend.mergeOrder(recordIDs: [first.id, second.id])
        var feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed[0].orderTotalMinor, 1_000_00)
        XCTAssertEqual(feed[0].orderParts.count, 2)
        XCTAssertEqual(feed[0].category?.id, home.id, "分类统一成一个")
        let detail = try await backend.recordDetail(id: feed[0].id)
        XCTAssertEqual(detail.orderMembers.count, 1)

        try await backend.splitOrder(recordID: first.id)
        feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 2)
        XCTAssertTrue(feed.allSatisfy { $0.category?.id == home.id }, "拆开后分类保留")
    }

    // MARK: 分类管理

    func testCategoriesCanBeEditedAndDeletingMovesRecords() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在宠物店消费人民币88.00元。")
        let pets = try await backend.addCategory(CategoryDraft(type: .expense, parentID: nil, name: " 宠物 ", symbol: "pawprint"))
        XCTAssertEqual(pets.name, "宠物")
        let food = try await backend.addCategory(CategoryDraft(type: .expense, parentID: pets.id, name: "猫粮", symbol: "pawprint"))
        do {
            _ = try await backend.addCategory(CategoryDraft(type: .expense, parentID: food.id, name: "第三层", symbol: "tag"))
            XCTFail("最多两层")
        } catch BackendError.invalidCategory {}

        let waiting = try await backend.uncategorized()
        let record = try XCTUnwrap(waiting.first)
        try await backend.setCategory(recordID: record.id, categoryID: food.id)
        try await backend.updateCategory(id: food.id, name: "猫粮和猫砂", symbol: "cart")
        var row = try await backend.records().first
        XCTAssertEqual(row?.category?.fullName, "宠物 · 猫粮和猫砂")

        try await backend.deleteCategory(id: pets.id, moveRecordsTo: nil)
        row = try await backend.records().first
        XCTAssertNil(row?.category, "删除分类：记录回到待分类，不删记录")
        let categories = try await backend.categories()
        XCTAssertFalse(categories.contains { $0.id == pets.id || $0.id == food.id })

        let fee = try await category(backend, "手续费")
        do {
            try await backend.deleteCategory(id: fee.id, moveRecordsTo: nil)
            XCTFail("系统分类不能删")
        } catch BackendError.categoryLocked {}
        try await backend.updateCategory(id: fee.id, name: "银行手续费", symbol: "doc.text")
    }

    func testMergeCategoryMovesRecordsAndRules() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在健身房消费人民币200.00元。")
        let sport = try await category(backend, "运动")
        let waiting = try await backend.uncategorized()
        let record = try XCTUnwrap(waiting.first)
        try await backend.setCategory(recordID: record.id, categoryID: sport.id)
        let fun = try await category(backend, "娱乐")
        try await backend.mergeCategory(id: sport.id, into: fun.id)
        let row = try await backend.records().first
        XCTAssertEqual(row?.category?.id, fun.id)

        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日15:30在健身房消费人民币50.00元。")
        let rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.amountMinor == 50_00 }?.category?.id, fun.id, "记住的规则跟着合并")
    }

    func testStatsGroupByTopLevelCategory() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        let rent = try await category(backend, "房租")
        for (amount, id) in [(20_00, lunch.id), (30_00, dinner.id), (2_000_00, rent.id)] as [(Int64, String)] {
            try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: amount, currency: .cny, categoryID: id, time: now))
        }
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 5_00, currency: .cny, time: now))
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseCategories.map(\.name), ["居住", "饮食", "待分类"])
        let food = try XCTUnwrap(cny.expenseCategories.first { $0.name == "饮食" })
        XCTAssertEqual(food.amountMinor, 50_00)
        XCTAssertEqual(food.children.map(\.name), ["晚餐", "午餐"])
        let filtered = try await backend.records(filter: RecordFilter(categoryID: try XCTUnwrap(food.categoryID)))
        XCTAssertEqual(filtered.count, 2, "按大类查包括它的小类")
    }

    func testEditingTypeChangesKindAndKeepsCategoryConsistent() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元。")
        let all = try await backend.records()
        let row = try XCTUnwrap(all.first)
        let snack = try await category(backend, "饮料零食")
        try await backend.setCategory(recordID: row.id, categoryID: snack.id)

        var fields = RecordEdit.fields(for: .expense, refund: true, transferDirection: .outflow, original: row.record)
        XCTAssertEqual(fields.kind, .refund)
        XCTAssertEqual(fields.direction, .inflow)
        fields = RecordEdit.fields(for: .transfer, refund: false, transferDirection: .outflow, original: row.record)
        XCTAssertEqual(fields.kind, .transferOut)
        XCTAssertEqual(fields.party, .own)
        try await backend.updateRecord(id: row.id, RecordEdit(
            accountID: row.record.accountID, amountMinor: 38_00, currency: .cny, direction: fields.direction, kind: fields.kind,
            counterparty: row.record.counterparty, time: nil, note: "", transferParty: fields.party
        ))
        let after = try await backend.records()
        let updated = try XCTUnwrap(after.first)
        XCTAssertEqual(updated.record.entryType, .transfer)
        XCTAssertNil(updated.record.categoryID, "转帐不保存分类")
    }
}
