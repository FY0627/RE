import Foundation
import BKModel
import BKDatabase

/// 自动归类：自动记账入账后给流水配上分类，用户选过分类后按交易对方记住。
///
/// 顺序：
/// 1. 转帐不用分类（按交易性质对应到转帐分类，不保存）；
/// 2. 手续费、扣息、工资、利息：通知里写明了，直接归到对应的分类；
/// 3. 退款：跟着原来那笔的分类（从那个分类里减掉）；
/// 4. 按交易对方记住的分类：给「美团」选过一次「饮食」，以后美团的都归到饮食；三餐按交易时间猜早餐、午餐、晚餐；
/// 5. 剩下的是「待分类」。
///
/// 没确认对方的转账：对方记成了自己的账户就算转帐；记过分类就算转给别人、用那个分类；都没有就留给用户确认。
/// 所有函数都在 `Database.write` 的闭包里执行。
struct Categorizer {
    let db: SQLiteConnection
    let calendar: Calendar
    let now: Date

    static func ruleKey(_ type: EntryType, _ counterparty: String) -> String { type.rawValue + "|" + counterparty }
    static func ownKey(_ counterparty: String) -> String { "own|" + counterparty }

    /// 入账后的自动归类；已经有分类的不动
    func categorize(recordID: String) throws {
        guard let record = try RecordDAO.find(db, id: recordID), record.status == .posted, record.categoryID == nil else { return }
        let tree = CategoryTree(try CategoryDAO.all(db))
        let key = CounterpartyKey.normalize(record.counterparty)

        if record.needsTransferConfirmation {
            guard let key else { return }
            if try CounterpartyRuleDAO.categoryID(db, key: Self.ownKey(key)) != nil {
                try RecordDAO.setTransferParty(db, id: record.id, party: .own)
            } else if let id = try CounterpartyRuleDAO.categoryID(db, key: Self.ruleKey(record.entryType, key)) ?? nil,
                      let category = tree.category(id), category.type == CategoryType(record.entryType) {
                try RecordDAO.setTransferParty(db, id: record.id, party: .other)
                try RecordDAO.setCategory(db, ids: [record.id], categoryID: mealAdjusted(category, record: record, tree: tree).id)
            }
            return
        }
        guard let category = try suggestion(for: record, key: key, tree: tree) else { return }
        try RecordDAO.setCategory(db, ids: [record.id], categoryID: category.id)
    }

    func suggestion(for record: LedgerRecord, key: String?, tree: CategoryTree) throws -> LedgerCategory? {
        let type = record.entryType
        guard type != .transfer else { return nil }
        let wanted = CategoryType(type)
        let autoKey: String? = switch record.kind {
        case .fee where type == .expense: CategoryKey.fee
        case .interestCharge where type == .expense: CategoryKey.interestCharge
        case .salary where type == .income: CategoryKey.salary
        case .interestIncome where type == .income: CategoryKey.interestIncome
        default: nil
        }
        if let autoKey, let category = tree.category(autoKey: autoKey), category.type == wanted { return category }
        if record.isRefund, let originID = record.relatedRecordID, let origin = try RecordDAO.find(db, id: originID),
           let category = tree.category(origin.categoryID), category.type == wanted {
            return category
        }
        guard let key, let id = try CounterpartyRuleDAO.categoryID(db, key: Self.ruleKey(type, key)) ?? nil,
              let category = tree.category(id), category.type == wanted else { return nil }
        return mealAdjusted(category, record: record, tree: tree)
    }

    /// 记住的是饮食或某一餐：按交易时间换成早餐、午餐、晚餐（这些分类还在的话）；其他时间、其他分类不变
    func mealAdjusted(_ category: LedgerCategory, record: LedgerRecord, tree: CategoryTree) -> LedgerCategory {
        let meals = [CategoryKey.food, CategoryKey.breakfast, CategoryKey.lunch, CategoryKey.dinner]
        guard let key = category.autoKey, meals.contains(key) else { return category }
        let hour = record.transactionTime?.hour ?? calendar.component(.hour, from: record.effectiveAt)
        guard let meal = CategoryKey.meal(hour: hour), let found = tree.category(autoKey: meal), !found.hidden else { return category }
        return found
    }

    /// 用户给一笔选了分类：记住这个对方，同一个对方还没分类的流水也一起归类（三餐各按自己的时间猜）
    func remember(_ record: LedgerRecord, categoryID: String) throws {
        guard let key = CounterpartyKey.normalize(record.counterparty) else { return }
        let tree = CategoryTree(try CategoryDAO.all(db))
        guard let category = tree.category(categoryID), category.type != .transfer else { return }
        let type = category.type.entryType
        // 记住大类还是小类：三餐记成「饮食」，下次再按时间猜
        let stored = [CategoryKey.breakfast, CategoryKey.lunch, CategoryKey.dinner].contains(category.autoKey ?? "")
            ? (tree.category(autoKey: CategoryKey.food) ?? category) : category
        try CounterpartyRuleDAO.set(db, key: Self.ruleKey(type, key), categoryID: stored.id, at: now)
        try CounterpartyRuleDAO.delete(db, key: Self.ownKey(key))
        for other in try RecordDAO.uncategorizedWithCounterparty(db) where other.id != record.id {
            guard CounterpartyKey.normalize(other.counterparty) == key, other.entryType == type else { continue }
            if other.needsTransferConfirmation { try RecordDAO.setTransferParty(db, id: other.id, party: .other) }
            try RecordDAO.setCategory(db, ids: [other.id], categoryID: mealAdjusted(stored, record: other, tree: tree).id)
        }
    }

    /// 用户确认转账的对方是自己的账户：记住这个对方，同一个对方没确认的转账也一起算转帐
    func rememberOwn(_ record: LedgerRecord) throws {
        guard let key = CounterpartyKey.normalize(record.counterparty) else { return }
        try CounterpartyRuleDAO.set(db, key: Self.ownKey(key), categoryID: nil, at: now)
        for type in [EntryType.expense, .income] { try CounterpartyRuleDAO.delete(db, key: Self.ruleKey(type, key)) }
        for other in try RecordDAO.unconfirmedTransferRecords(db) where other.id != record.id {
            guard CounterpartyKey.normalize(other.counterparty) == key else { continue }
            try RecordDAO.setTransferParty(db, id: other.id, party: .own)
            try RecordDAO.setCategory(db, ids: [other.id], categoryID: nil)
        }
    }
}
