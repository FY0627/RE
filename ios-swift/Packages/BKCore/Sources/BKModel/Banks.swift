import Foundation

/// 已知银行的识别线索。只用来判断「这条通知来自哪家银行」，帮助同尾号账户消歧。
/// 短信号码、签名和邮箱域名是公开信息，不保证覆盖银行的全部发送渠道；
/// 设置邮件自动化时应以用户收到的实际发件地址为准。
public struct BankProfile: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var smsNumbers: [String]
    public var signatures: [String]
    public var emailDomains: [String]
    public var defaultPaletteID: String

    public init(id: String, name: String, smsNumbers: [String], signatures: [String], emailDomains: [String], defaultPaletteID: String) {
        self.id = id
        self.name = name
        self.smsNumbers = smsNumbers
        self.signatures = signatures
        self.emailDomains = emailDomains
        self.defaultPaletteID = defaultPaletteID
    }
}

public enum BankDirectory {
    public static let all: [BankProfile] = [
        BankProfile(id: "cmb", name: "招商银行", smsNumbers: ["95555"], signatures: ["招商银行", "招行"], emailDomains: ["cmbchina.com"], defaultPaletteID: "graphite-gold"),
        BankProfile(id: "icbc", name: "工商银行", smsNumbers: ["95588"], signatures: ["工商银行", "中国工商银行", "工银"], emailDomains: ["icbc.com.cn"], defaultPaletteID: "crimson"),
        BankProfile(id: "ccb", name: "建设银行", smsNumbers: ["95533"], signatures: ["建设银行", "中国建设银行"], emailDomains: ["ccb.com"], defaultPaletteID: "ocean"),
        BankProfile(id: "boc", name: "中国银行", smsNumbers: ["95566"], signatures: ["中国银行"], emailDomains: ["boc.cn", "bankofchina.com"], defaultPaletteID: "autumn-gold"),
        BankProfile(id: "abc", name: "农业银行", smsNumbers: ["95599"], signatures: ["农业银行", "中国农业银行"], emailDomains: ["abchina.com"], defaultPaletteID: "jade"),
        BankProfile(id: "bocom", name: "交通银行", smsNumbers: ["95559"], signatures: ["交通银行"], emailDomains: ["bankcomm.com"], defaultPaletteID: "ocean"),
        BankProfile(id: "psbc", name: "邮储银行", smsNumbers: ["95580"], signatures: ["邮储银行", "中国邮政储蓄银行"], emailDomains: ["psbc.com"], defaultPaletteID: "jade"),
        BankProfile(id: "cib", name: "兴业银行", smsNumbers: ["95561"], signatures: ["兴业银行"], emailDomains: ["cib.com.cn"], defaultPaletteID: "ocean"),
        BankProfile(id: "citic", name: "中信银行", smsNumbers: ["95558"], signatures: ["中信银行"], emailDomains: ["citicbank.com"], defaultPaletteID: "crimson"),
        BankProfile(id: "spdb", name: "浦发银行", smsNumbers: ["95528"], signatures: ["浦发银行"], emailDomains: ["spdb.com.cn"], defaultPaletteID: "midnight"),
        BankProfile(id: "cmbc", name: "民生银行", smsNumbers: ["95568"], signatures: ["民生银行"], emailDomains: ["cmbc.com.cn"], defaultPaletteID: "jade"),
        BankProfile(id: "ceb", name: "光大银行", smsNumbers: ["95595"], signatures: ["光大银行"], emailDomains: ["cebbank.com"], defaultPaletteID: "violet"),
        BankProfile(id: "pab", name: "平安银行", smsNumbers: ["95511"], signatures: ["平安银行"], emailDomains: ["pingan.com.cn"], defaultPaletteID: "sunset"),
        BankProfile(id: "cgb", name: "广发银行", smsNumbers: ["95508"], signatures: ["广发银行"], emailDomains: ["cgbchina.com.cn"], defaultPaletteID: "crimson"),
        BankProfile(id: "hxb", name: "华夏银行", smsNumbers: ["95577"], signatures: ["华夏银行"], emailDomains: ["hxb.com.cn"], defaultPaletteID: "crimson"),
    ]

    public static func profile(id: String?) -> BankProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 根据短信发件人、邮件发件人和正文签名识别银行。识别不出返回 nil，不猜。
    public static func identify(sender: String?, text: String) -> String? {
        if let sender, !sender.isEmpty {
            let digits = String(sender.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
            if !digits.isEmpty, digits.count <= 16 {
                for bank in all where bank.smsNumbers.contains(where: { digits.hasSuffix($0) }) {
                    return bank.id
                }
            }
            let lowered = sender.lowercased()
            if let at = lowered.lastIndex(of: "@") {
                let domain = lowered[lowered.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
                for bank in all where bank.emailDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                    return bank.id
                }
            }
        }
        // 正文签名：【招商银行】或 [招商银行]；取最长匹配，避免「中国银行」误配「中国工商银行」的情况
        var best: (id: String, length: Int)?
        for bank in all {
            for signature in bank.signatures {
                for wrapped in ["【\(signature)】", "[\(signature)]", "［\(signature)］"] where text.contains(wrapped) {
                    if best == nil || wrapped.count > best!.length { best = (bank.id, wrapped.count) }
                }
            }
        }
        return best?.id
    }
}
