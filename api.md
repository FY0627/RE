可以接入免费数据，但**免费、实时、可公开展示、准确性有保障，不能默认同时满足**。对你的记账 App，建议这样选：

| 用途               | 接口                                                         | 免费条件与限制                                               |
| ------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| 汇率换算、资产估值 | [Frankfurter](https://frankfurter.dev/)                      | 无需密钥，来自央行和官方来源；主要每天更新，**不是实时汇率** |
| 低频获取实时汇率   | [Alpha Vantage](https://www.alphavantage.co/documentation/#currency-exchange) | 需免费密钥，标准免费额度每天 25 次；默认授权为个人非商业使用，公开 App 要另确认展示授权。[额度](https://www.alphavantage.co/support/)、[条款](https://www.alphavantage.co/terms_of_service/) |
| 黄金、白银行情     | [Gold-api.com](https://gold-api.com/docs)                    | 当前价格接口免费、无需密钥，允许商业 App 使用；官方要求缓存约 30 秒，但不保证数据准确性与可靠性。[文档](https://gold-api.com/llms.txt)、[条款](https://gold-api.com/terms) |

**零成本起步，我会选 Frankfurter＋Gold-api.com**，用于账本换算和贵金属参考估值；界面分别标明「每日参考汇率」和「最新参考行情」。

接入流程是 `App → 你的后端接口 → 数据提供商`：

1. 后端统一请求和缓存，避免每个用户重复消耗额度；有密钥的接口也放在后端。
2. 返回价格、币种、单位、来源和**行情时间**。请求失败保留旧数据，并标明已过期。
3. 每笔账保存当时采用的汇率；资产估值可以使用最新价格，避免历史账单随行情变化。

如果报价单位是美元/金衡盎司，可换算为：

```
人民币/克 = 美元/金衡盎司 × USD/CNY ÷ 31.1034768
```

一金衡盎司等于 31.1034768 克。[NIST 换算资料](https://www.nist.gov/system/files/documents/2017/05/09/Precious-Metals-Conversion-Information-march2015.pdf) 如果汇率是每日数据，换算后的人民币价格也要注明这一点。