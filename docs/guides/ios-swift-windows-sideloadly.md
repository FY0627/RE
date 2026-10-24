# Windows 11 + iPhone：下载 IPA、用 Sideloadly 安装、设置自动记账

适用：没有 Mac，只有 Windows 11 电脑和 iPhone（本项目按 iPhone 16 Pro / iOS 27.0.1 编写）。
构建在 GitHub Actions 上完成（[ADR 0009](../decisions/0009-ios-swift-ci-sideloadly.md)），签名在你自己的电脑上用你自己的 Apple 账户完成。

> Apple 账户密码只输入到你本机的 Sideloadly / Apple 登录流程中。不要放进仓库、GitHub Secrets 或发给任何人。
> Sideloadly 是第三方工具，它会用你的 Apple 账户向 Apple 申请免费的开发证书；请只从官网下载。

## 1. 下载 IPA

1. 打开仓库的 Actions 页面：`https://github.com/FY0627/RE/actions/workflows/ios-swift-build.yml`，进入最新一次绿色（成功）的运行。
2. 页面底部 **Artifacts** 里下载名为 `Bookkeeping-<版本>-b<构建号>-<提交前8位>` 的产物（需要登录 GitHub）。
3. 解压得到 `.ipa`、`.ipa.sha256`、`build-info.txt`、`ipa-verification.txt`，以及 `screenshots/` 目录（模拟器上用演示数据截的浅色 / 深色界面图，可在安装前预览本次构建；某次截图失败时这个目录可能缺失，不影响 IPA）。
4. 在 PowerShell 中校验：

   ```powershell
   Get-FileHash .\Bookkeeping-*.ipa -Algorithm SHA256
   Get-Content .\Bookkeeping-*.ipa.sha256
   ```

   两个哈希值必须一致；也可以与运行页面上「IPA」注释里的 sha256 对照。

## 2. 安装 Sideloadly 及其依赖

1. 只从官网 <https://sideloadly.io/> 下载 Windows 版并安装。
2. Sideloadly 要求**网页版**（非 Microsoft Store 版）的 iTunes 和 iCloud。若已装了商店版，先卸载，再从 Apple 官网下载网页安装包安装（Sideloadly 官网页面提供了链接）。
3. 安装后重启电脑。

## 3. 连接并信任 iPhone

1. 用数据线连接 iPhone 与电脑，解锁 iPhone。
2. iPhone 弹出「要信任此电脑吗？」→ 选「信任」并输入锁屏密码。
3. Sideloadly 左上角设备列表里应能看到你的 iPhone。

## 4. 签名并安装

1. 把 `.ipa` 拖进 Sideloadly。
2. 「Apple Account」填你自己的 Apple 账户，点 **Start**，按提示输入密码与双重认证验证码。**不需要付费开发者账户。**
3. **Bundle ID 保持不变**：默认是 `com.example.bookkeepingApp.swift`。
   如果 Sideloadly 报告该 Bundle ID 已被占用，在 Advanced Options 里设置一个你自己的固定 ID（例如 `com.example.bookkeepingApp.swift.<你的缩写>`），
   **以后每次安装都用同一个 ID 和同一个 Apple 账户**，否则会被当成另一个 App：数据不能保留，快捷指令里的动作引用也会失效。
4. 不要勾选会删除或修改 App 能力的选项；本 App 不需要任何额外权限（无 App Group、推送、iCloud）。

## 5. 在 iPhone 上允许运行

按 iOS 实际出现的提示操作（以设备显示为准）：

1. **开发者模式**：`设置 › 隐私与安全性 › 开发者模式` 打开，按提示重启并确认。
   （开发证书签名的 App 在 iOS 16 及以后需要开启；安装过此类 App 后该开关才会出现。）
2. **信任开发者**：`设置 › 通用 › VPN 与设备管理`，在「开发者 App」下找到你的 Apple 账户 → 信任。此步需要联网验证。
3. 打开「日常记账」，确认能看到首页。

## 6. 确认快捷指令能发现 App 动作

1. 打开「快捷指令」→ 任意新建一个快捷指令 → 添加操作 → 搜索「日常记账」。
2. 应能看到「记录银行动账通知」。看不到时：先打开一次「日常记账」App，再回到快捷指令搜索；仍看不到请记录 iOS 版本并反馈。

## 7. 设置自动记账并做一次真实验证

1. 在 App「资产」页上拉右下角加号（或点空卡片）添加银行卡：银行、后四位（前导 0 会保留）、卡类型、币种。
2. 保存后进入「设置自动记账」，按页面里的短信或邮件步骤在快捷指令里创建自动化（**立即运行**）。
   页面上的步骤会写明这张卡的尾号和建议的筛选条件。
3. 等下一条**真实**的银行动账短信 / 邮件。不需要打开记账 App。
4. 打开 App → 卡片详情顶部状态应变为「已验证 · 最近一次接收 …」，首页出现这笔流水。
5. 按 [真机验收清单](ios-swift-device-checklist.md) 分别在「其他 App 前台」「锁屏」「App 未启动」「无网络」条件下各验证一次，并记录结果。

## 8. 更新、续签与数据保留

| 情况 | 做法 | 数据 |
|---|---|---|
| 新版本 IPA | 用 Sideloadly、**同一 Apple 账户、同一 Bundle ID** 直接安装覆盖。**不要先删除旧 App。** | 覆盖安装按 iOS 规则保留 App 数据（需真机确认，见清单） |
| 免费签名到期（约 7 天） | 到期前用同一个 IPA 重新安装一次即可续签；也可用 Sideloadly 的自动续签（需电脑开着并与 iPhone 同网络） | 保留 |
| 已经过期 | App 打不开、自动化运行失败；重新签名安装后恢复。过期期间到达的通知不会被补记 | 保留（未删除 App 时） |
| 删除 App | 本地账本随之删除，无云备份 | **丢失** |

免费 Apple 账户的已知限制（以 Apple / Sideloadly 实际提示为准）：签名约 7 天有效；同时安装的侧载 App 数量有限（常见为 3 个）；
每 7 天可注册的 App ID 数量有限（常见为 10 个），频繁更换 Bundle ID 会很快用完。

## 9. 常见问题

- **快捷指令每次都问我是否运行**：自动化没选「立即运行」。编辑自动化改为立即运行。
- **每次运行都有系统通知**：在该自动化里关闭「运行时通知」。这是系统行为，不是 App 弹窗。
- **状态一直「待验证」**：在「我的 › 自动记账状态」看接收日志。没有任何记录说明自动化没有触发；有「空输入」说明「通知内容」没有选「快捷指令输入」。
- **记到了待处理**：打开首页的待处理入口，从系统给出的候选账户中确认或忽略。
