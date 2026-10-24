import BKModel

/// 解析用到的关键词表。新增银行格式时，优先在这里补词，再在 `ParserSamples` 测试里补脱敏样例。
enum Lexicon {
    // MARK: 整条通知的类别

    static let verificationCode = Rx(#"验证码|校验码|动态码|动态密码|短信密码|一次性密码|\bOTP\b|one[- ]time (?:password|code)|verification code|security code|passcode|bestätigungscode|\bm?TAN\b"#)
    /// 正文里真的给出了一个验证码（只提到「验证码」字样的安全提示不算）
    static let verificationCodeValue = Rx(#"(?:验证码|校验码|动态码|动态密码|短信密码|一次性密码)\s*(?:是|为)?\s*[：:]?\s*[A-Za-z0-9]{4,8}(?![\d])|(?<![\d.])\d{4,8}\s*(?:是|为)?\s*(?:您的?)?(?:本次)?(?:验证码|校验码|动态码|动态密码)|(?:\bOTP\b|one[- ]time (?:password|code)|verification code|security code|passcode|bestätigungscode)\s*(?:is|:|ist)?\s*[：:]?\s*\d{4,8}|\d{4,8}\s+is your (?:otp|verification code|code)"#)
    static let statement = Rx(#"电子账单|对账单|月结单|账单明细|本期账单明细|e-?statement|monthly statement|statement of account|kontoauszug"#)
    static let reminder = Rx(#"还款提醒|账单提醒|扣款提醒|温馨提示.{0,20}还款|到期还款日|最后还款日|账单日|最低还款|应还款?额|本期应还|账单已出|已出账|payment due|due date|minimum payment|statement (?:is )?ready|将于|将在|即将|预计.{0,6}(?:扣款|扣收|还款|入账)|请于|请在.{0,12}前|请确保|请保证|请存入|请及时还款|请按时还款|will be (?:debited|charged|deducted)"#)
    static let completed = Rx(#"已还款|还款成功|成功还款|已入账|已到账|已收到|已扣款|已于|扣款成功|has been (?:credited|debited|received)|was (?:charged|debited|credited)|received your payment"#)
    static let marketing = Rx(#"退订|回T\b|回TD|回复TD|拒收请回|unsubscribe|优惠|活动|抽奖|立减|领取|特惠|福利|专享|邀请|免费|promo|offer|最高可(?:借|贷|享|领)|额度高达|申请|办理|分期|诚邀|恭喜"#)
    static let limitChange = Rx(#"(?:临时|固定|信用|可用)?额度.{0,10}(?:调整|提升|提高|恢复|降低|调低|调为|生效|到期)|credit limit (?:increase|change|adjust)"#)
    static let failed = Rx(#"失败|未成功|不成功|未能成功|被拒|拒绝交易|交易拒绝|余额不足|declined|\bfailed\b|unsuccessful|not successful|abgelehnt"#)

    // MARK: 金额角色（金额前面最近的标签决定这个数字是什么）

    enum Role: Int {
        case transaction
        case balance
        case creditLimit
        case fee
        case cumulative
        case due
        case points
    }

    static let roleLabels: [(Role, Rx)] = [
        (.balance, Rx(#"可用余额|账户余额|活期余额|余额|结余|\bbalance\b|avl\.? ?bal|avail(?:able)? bal|\bbal\b|kontostand|saldo"#)),
        (.creditLimit, Rx(#"可用额度|信用额度|剩余额度|临时额度|额度|available credit|credit limit|available limit|verfügbarer rahmen"#)),
        (.fee, Rx(#"手续费|服务费|工本费|年费|管理费|短信费|\bfees?\b|gebühr"#)),
        (.cumulative, Rx(#"累计|合计|总计|共计|本月消费|当月消费|\btotal\b"#)),
        (.due, Rx(#"最低还款|应还款?额?|本期账单金额|账单金额|minimum payment|amount due|statement balance"#)),
        (.points, Rx(#"积分|\bpoints\b|里程"#)),
        (.transaction, Rx(#"消费|支付|支出|收入|转入|转出|汇入|汇出|存入|取出|取款|取现|入账|到账|扣款|扣费|扣收|扣除|划扣|还款|退款|退货|冲正|撤销|结息|利息|扣息|工资|代发|金额|交易|付款|收款|充值|提现|预授权|冻结|解冻|debited|credited|charged|spent|paid|received|refund(?:ed)?|withdrawn|withdrawal|deposited?|purchase|payment|amount|transaction|transfer(?:red)?|abgebucht|gutgeschrieben|belastet"#)),
    ]

    static let includedFee = Rx(#"含\s*(?:手续费|费用|服务费)|including (?:a )?fee|incl\.? fee"#)
    /// 数字后面紧跟这些字，说明它不是金额（笔数、期数、天数、百分比……）
    static let nonAmountSuffix = Rx(#"^\s*(?:笔|次|期|天|日|个月|月|年|%|％|分钟|小时|岁|位|张|号|人|件|points?\b|x\b)"#)

    // MARK: 交易性质（离金额最近的关键词优先）

    struct KindRule: Sendable {
        let rx: Rx
        let kind: TransactionKind
        let direction: FlowDirection?
        let status: SettlementStatus
        /// 只有「转账 / 汇款」，没说转入还是转出
        let transferGeneric: Bool

        init(_ pattern: String, _ kind: TransactionKind, _ direction: FlowDirection?, status: SettlementStatus = .posted, transferGeneric: Bool = false) {
            rx = Rx(pattern)
            self.kind = kind
            self.direction = direction
            self.status = status
            self.transferGeneric = transferGeneric
        }
    }

    static let kindRules: [KindRule] = [
        KindRule(#"预授权完成"#, .purchase, .outflow),
        KindRule(#"预授权撤销|撤销预授权|预授权取消|authori[sz]ation (?:released|reversed|cancell?ed)"#, .purchase, .inflow, status: .holdReleased),
        KindRule(#"解冻|解除冻结|unfrozen|released hold"#, .other, .inflow, status: .holdReleased),
        KindRule(#"预授权|pre-?authori[sz]ation|authori[sz]ation hold|vormerkung"#, .purchase, .outflow, status: .hold),
        KindRule(#"冻结|暂扣|预扣|on hold|frozen"#, .other, .outflow, status: .hold),
        KindRule(#"冲正|撤销|冲销|撤单|reversal|reversed|storniert|storno"#, .reversal, nil),
        KindRule(#"退款|退货|退回|退税|返还|refund(?:ed)?|erstattung|rückerstattung"#, .refund, .inflow),
        KindRule(#"还款|repayment|payment received|payment thank you|received your payment"#, .repayment, nil),
        KindRule(#"扣息|利息扣收|扣收利息|贷款利息|透支利息|interest charged?|sollzinsen"#, .interestCharge, .outflow),
        KindRule(#"结息|利息入账|利息收入|付息|存款利息|interest (?:paid|credited|earned)|zinsgutschrift|利息"#, .interestIncome, .inflow),
        KindRule(#"手续费|年费|管理费|服务费|短信费|扣费|\bfees?\b|gebühr"#, .fee, .outflow),
        KindRule(#"工资|薪资|薪金|代发|奖金|salary|payroll|gehalt|lohn"#, .salary, .inflow),
        KindRule(#"取款|取现|\bATM\b|支取|cash withdrawal|withdrawal|withdrawn|abhebung|bargeld"#, .withdrawal, .outflow),
        KindRule(#"存款|现金存入|存入现金|cash deposit|einzahlung"#, .deposit, .inflow),
        KindRule(#"向您(?:尾号\s*[*xX•]*\d{4})?的?(?:账户|账号|卡)?(?:转账|汇款)|转入|汇入|收款|来账|转账收入|转账存入|received from|transfer from|incoming transfer|überweisung von"#, .transferIn, .inflow),
        KindRule(#"转出|汇出|转账支出|向[^，,。；;\n]{1,20}(?:转账|汇款)|付款给|transfer(?:red)? to|sent to|outgoing transfer|überweisung an"#, .transferOut, .outflow),
        KindRule(#"转账|汇款|\btransfer\b|überweisung"#, .transferOut, nil, transferGeneric: true),
        KindRule(#"消费|刷卡|网上支付|快捷支付|网银支付|支付|购物|扣款|划扣|purchase|spent|charged|card payment|payment (?:at|to)|\bPOS\b|kartenzahlung|einkauf"#, .purchase, .outflow),
    ]

    static let inflowCue = Rx(#"收入|入账|到账|存入|收到|退回|返还|credited|received|deposited|eingang|gutgeschrieben|gutschrift"#)
    static let outflowCue = Rx(#"支出|扣除|扣减|扣款|扣收|debited|\bdebit\b|abgebucht|belastet|belastung"#)

    static let summaryField = Rx(#"(?:摘要|用途|附言|交易类型|业务类型|备注|description)\s*[：:]\s*([^，,。；;\n]{1,30})"#)
}
