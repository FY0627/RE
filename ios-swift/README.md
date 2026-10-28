# 日常记账 · iOS 原生 Swift 版

独立于 Flutter 的 iOS 版本（[ADR 0006](../docs/decisions/0006-ios-native-swift.md)）。只依赖用户自己的 iPhone：
账户、流水、解析规则和设置保存在本机 SQLite；没有服务器、云数据库、远程解析或账号系统。
App 不联网；净资产换算用的汇率由快捷指令下载后导入（[ADR 0011](../docs/decisions/0011-ios-swift-multi-currency-and-rates.md)）。

## 目录

```
ios-swift/
├── Bookkeeping.xcodeproj/         手写工程（objectVersion 77），含共享 scheme「Bookkeeping」
├── Config/Info.plist
├── Bookkeeping/                   App target（文件夹同步，新增 .swift 文件无需改工程）
│   ├── App/                       入口、共享服务 AppServices、界面状态 LedgerStore
│   ├── Intents/                   App Intent「记录银行动账通知」、AccountEntity、AppShortcuts
│   ├── UI/                        Shell（系统 TabView）、Home、Assets（卡包与已停用卡包、详情转场、卡片信息、卡面编辑、管理银行卡）、Stats、Profile、Pending
│   ├── Diagnostics/               单变量性能开关、帧率/内存指标
│   └── Assets.xcassets
├── Packages/BKCore/               纯 Swift 业务核心（无 UI 依赖）
│   ├── Sources/BKModel/           值类型：账户、流水、金额（整数最小单位）
│   ├── Sources/BKDatabase/        SQLite3 封装、迁移、DAO
│   ├── Sources/BKBackend/         解析、匹配、去重、入账、统计（LedgerBackend）
│   └── Tests/                     单元测试（脱敏构造样例）
└── ci/                            GitHub Actions 调用的脚本
```

依赖方向：`App → BKBackend → BKDatabase → BKModel`，App 不 import `BKDatabase`（CI 检查）。

## 构建（GitHub Actions）

工作流 [`.github/workflows/ios-swift-build.yml`](../.github/workflows/ios-swift-build.yml) 在 `xcode-27` runner 上：

1. 打印并校验工具链（Xcode、Swift、iOS SDK、部署目标 ≤ iOS 27.0.1）；
2. `swift test`（macOS 主机）+ `xcodebuild test`（iOS 模拟器）运行 BKCore 测试。模拟器按目标设备选择：优先 iPhone 16 Pro，其次其他 iPhone Pro，不使用双屏机型（[`ci/pick-simulator.sh`](ci/pick-simulator.sh)）；
3. 构建 Release / iphoneos / arm64、不签名的 `Bookkeeping.app`；
4. 校验可执行文件、Mach-O 平台、Info.plist、依赖、资源与 App Intents 元数据，打包为 `Payload/Bookkeeping.app` 的 IPA；
5. 上传 IPA（含 SHA-256 与 build-info）和诊断产物。

推送 `ios-swift` 分支或在 Actions 页面手动运行（可选指定 Xcode 路径）。

## 本地（Windows）运行核心测试

没有 Mac 也可以用 Docker 在 Linux 上跑 `BKCore` 的全部测试（SwiftUI 部分只能在 CI 编译）：

```sh
# 一次性：带 SQLite 头文件的 Swift 镜像
printf 'FROM swift:latest\nRUN apt-get update && apt-get install -y libsqlite3-dev\n' | docker build -t bk-swift -
# 运行测试（PowerShell / Git Bash 均可，路径换成你的仓库位置）
docker run --rm -v "<仓库>/ios-swift/Packages/BKCore:/pkg" -w /pkg bk-swift swift test
```

## 卡包与详情转场

和 Apple 钱包一样用 UIKit + Core Animation（[ADR 0012](../docs/decisions/0012-ios-swift-wallet-core-animation.md)）：
动画交给系统渲染进程播放，主线程读流水、生成列表行都不影响。选中卡上面的卡缩小收到它后面，下面的卡向下落出屏幕，
详情内容从屏幕底下整块升起；返回时内容整块退到屏幕底下。

- `UI/Assets/WalletController.swift`：卡包、卡片位置和转场、手势。每张卡一个视图，在两个滚动区上层按滚动距离摆放；
  打开 / 关闭时改模型位置并加叠加动画，动画途中滚动、再点都从当前位置平滑转向。状态栏高度从窗口读取。
- `UI/Assets/WalletDetailList.swift`：详情列表（`UICollectionView` + 固定高度的流式布局）。余额区 `AccountDetailSummary`
  和每行流水仍由 SwiftUI 画，放在关掉安全区的 `UIHostingController` 里；格子高度事先量好，不做自适应高度。
- `UI/Assets/CardMotion.swift`：弹簧和曲线参数（与 SwiftUI 的 `spring(response:dampingFraction:)` 换算一致），
  收到后面的卡的缩放比例 `behindScale`。卡片不做 3D 倾斜（会让卡片之间的上下层错乱）。
- `UI/Assets/WalletTopBar.swift`：顶部按钮，UIKit 液态玻璃（同一个玻璃容器里的三块玻璃，共用部分在 `UI/Common/GlassControls.swift`）。
  卡包里「+」和「更多」合成一个胶囊；打开详情时「+」那一半像水滴一样分出来、冲过一点再弹回，变成选时间段的胶囊，左边凝结出返回按钮；
  返回时沿原路并回去，并好后整个胶囊鼓一下再弹回。移动途中两块玻璃之间拉出水滴一样的细颈，停下时正好断开（融合距离和停下的间距差不多大）。
- 屏幕外的卡隐藏起来不画；打开 / 关闭详情时只有起点或终点在屏幕上的卡做动画（`WalletController.cullCards`）。
- `UI/Assets/AssetsView.swift`：SwiftUI 外壳，标签栏显隐、弹出页面、标题区和净资产卡。
- 卡面仍是 SwiftUI 的 `WalletCardView`，阴影只画在一个圆角矩形上；转场时卡面不重新计算，只是整张移动。

## 多币种与汇率

- 账户有一个主币种，多币种账户另有其他币种；余额按「卡 × 币种」分别推算，卡片和流水始终是原币种。
- 卡里没有的币种的交易按主币种扣款，计入主币种余额：用户在流水编辑里填的实际扣款优先，
  否则按交易当天的汇率估算（那天没有用记录当天的，再没有用最近的一天；`BKBackend/ChargeCalculator.swift`，[ADR 0013](../docs/decisions/0013-ios-swift-record-editing-and-foreign-charges.md)）。
- 币种从汇率数据源支持的全部 160 多个币种里选（`UI/Common/CurrencyPicker.swift`，按拼音首字母分组、侧边 A–Z 索引，搜索框在最下面）。
- 「我的 › 币种与汇率」选择主要币种；有汇率时资产页净资产按主要币种换算合计（`App/ExchangeRateStore.swift`）。
- 汇率来源：快捷指令自动化「获取 URL 内容」→ App 动作「导入汇率」（`Intents/ImportExchangeRatesIntent.swift`）。
  完整的汇率表原样保存：最新一份在本机缓存，另外按天存进账本（`RateDAO`），以前的日期都保留。

## 流水

参考 MOZE 的基础记账（[ADR 0014](../docs/decisions/0014-ios-swift-entry-types-and-categories.md)）：只看支出 / 收入 / 转帐三种类型，每笔有分类和备注。

- 首页一笔钱只占一行：转帐两边合成「招行 → 工行」，同一条通知拆出的手续费写在那一笔下面，合成的一单只占一行；失败、冻结只在卡片详情里。
  标题按「备注 → 交易对方 → 分类名」，图标是分类图标（`UI/Common/{RecordRowView,RecordDisplay}.swift`）。
- 分类在「我的 › 分类」里自己管（`UI/Profile/CategoryManagerView.swift`），选分类的格子在 `UI/Common/CategoryGrid.swift`
  （放在列表的分组里：点有小类的大类先选上它，小类在下一行展开，分组的框往下变大，大类那一行不动；只会有一个选中）。
  自动记账只把手续费、扣息、工资、利息和退款归类，不猜；
  其余是「待分类」，在「待处理」里点一笔、选分类、点「确定」。
- 首页右上角「+」手动记一笔（`UI/Home/AddRecordView.swift`）：现金、电子钱包，或通知还没接上的消费。
  先选币种（任何一种，默认主要币种；选币种页面和添加账户时一样，最上面先列自己的账户里有的币种）再选账户；账户没有这个币种时按它的主币种扣款（入账），
  空着按当天汇率估算（提示大概多少），银行实际扣了多少可以直接填。转帐两边各自算。编辑流水也一样。
- 首页最上面的本月支出、本月收入、结余换算成「我的」里选的主要币种（外币交易有实际扣款用实际扣款，否则按当天汇率；
  没有汇率的币种不算进去，下面写一行小字）。
- 流水详情里分类只显示（改分类在「编辑」里），备注直接写；一单用了几张卡时可以「合并」成一单，也可以拆开。
- 流水详情右上角「编辑」（`UI/Common/RecordEditor.swift`）：支出 / 收入 / 转帐、退款、金额、币种、分类、账户、交易对方、时间、备注、实际扣款；
  转帐还能选另一边是哪个账户（那边有对得上的一笔就配成一对，没有就补记一笔；手动补记的那笔跟着这一笔改）。
  来源和通知原文不能改。只在详情最下面删除（首页不能左滑删除），点了在按钮旁边弹出小菜单确认；
  收到它的那条通知仍记着，再来也不会重新记上。首页金额太长时缩小一点，不换行。余额从校准余额那一刻算起，比它早的流水换账户不影响余额（编辑页会写明）。
- 首页搜索（`UI/Home/HomeTopBar.swift`，和资产页顶部按钮同一种 UIKit 液态玻璃，共用 `UI/Common/GlassControls.swift`）：
  标题右边是「+」（记一笔）和圆形搜索按钮，点搜索后「+」先像水滴一样并进圆里，搜索框紧接着从圆里向左分出来，
  标题的位置再分出「全部 / 支出 / 收入 / 转帐」的下拉按钮，圆留在原地变成关闭按钮；关闭时把展开动画倒过来播放，
  快缩完时「+」从圆里分出来、冲过一点再弹回。圆不用系统的交互玻璃（按住时它浮在上层、不和分出来的玻璃融合），按下的反馈自己做；
  列表滚到标题行下面时垫一层磨砂背景（`UI/Common/TitleBar.swift` 的 `TopBarBackdrop`，搜索展开时也一直在）；
  交易对方、备注、分类、账户、银行、尾号、类型、金额都能搜。首页不用系统导航栏，标题和按钮在同一行，和资产页一样；不做下拉刷新。
- 卡片详情：多币种的卡按币种分开看流水（币种在「交易记录」旁边选），时间段在右上角的胶囊里选；余额在卡片上，校准余额在卡片信息里。
- 统计（`UI/Stats/StatsView.swift`）：右上角的时间段胶囊选看哪段时间（和卡片详情一样）；分段控件选「按币种」
  （支出、收入、结余，按分类排，点进去看小类和每一笔）或「按账户」（进出多少，点进去看每一笔）；转帐不算收支。
  标题「统计」和时间段胶囊在同一行，和资产页一样高（`UI/Common/TitleBar.swift`）。
- 「我的」的标题行也和资产页一样高，滚动时的磨砂背景和首页一样。选币种页面的列表不跟着键盘变矮（收起键盘时搜索框后面不会露出一块）。

## 卡片信息与卡面

- **添加银行卡**：银行直接输入，按输入列出对得上的银行全称（`BKModel/BankCatalog.swift`，约 180 家，中英文、繁体、拼音首字母、
  日文、韩文都能搜），列表里没有的用输入的名称；每个币种的初始余额紧跟在选好的币种下面（下拉选余额或欠款，再填金额）。
  点输入框以外的地方收起键盘（整个 App 都是，`UI/Common/KeyboardDismissal.swift`），键盘上方不加按钮。
- **现金、电子钱包**：添加账户时选「现金」或「电子钱包」，只填名称、币种和初始余额。没有卡号（尾号存占位 `0000`），不参与尾号匹配。
  现金用「记一笔」手动记；电子钱包选了是哪个钱包（支付宝、微信支付……），它发来的、没写银行卡号的通知自动记到这里，
  同一个钱包有几个账户时进待处理让你选。
- **卡片信息 › 编辑**：账户名称、卡类型、主币种、其他币种、各币种的校准余额（就是初始余额：余额对不上时填现在实际有多少）、卡号、账号；
  银行和尾号不能改。校准余额的输入框空着，原来的金额灰色显示在框里，不填就不变。
- **卡号**：自动记账只用后四位匹配。完整卡号是选填的，在卡片详情 › 卡片信息里填写，只保存在本机 SQLite，默认遮住显示。
- **卡面图片**：选图时用 ImageIO 一次性按卡片比例居中裁剪、缩小到卡片的屏幕像素（最大 1200px 宽）存成 JPEG，
  放在 `Application Support/Ledger/CardFaces/`，数据库只存文件标识。显示时后台解码并缓存（`CardFaceImages`），
  卡包滚动和详情转场只绘制已解码的位图。换图、移除或取消编辑时删除不再使用的文件。
- **停用**：卡片信息里，或资产页「更多 › 管理银行卡」里停用（`accounts.archived`）。停用的卡不参与自动记账匹配和净资产，
  流水保留，在资产页最下方以灰色卡包显示，可以点开详情，也可以重新启用。

## 安装到 iPhone

见 [Windows + Sideloadly 安装指南](../docs/guides/ios-swift-windows-sideloadly.md) 与 [真机验收清单](../docs/guides/ios-swift-device-checklist.md)。

## 自动记账

见 [features/ios-swift-auto-bookkeeping.md](../docs/features/ios-swift-auto-bookkeeping.md)。
