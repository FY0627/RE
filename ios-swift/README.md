# 日常记账 · iOS 原生 Swift 版

独立于 Flutter 的 iOS 版本（[ADR 0006](../docs/decisions/0006-ios-native-swift.md)）。只依赖用户自己的 iPhone：
账户、流水、解析规则和设置保存在本机 SQLite；没有服务器、云数据库、远程解析或账号系统。

## 目录

```
ios-swift/
├── Bookkeeping.xcodeproj/         手写工程（objectVersion 77），含共享 scheme「Bookkeeping」
├── Config/Info.plist
├── Bookkeeping/                   App target（文件夹同步，新增 .swift 文件无需改工程）
│   ├── App/                       入口、共享服务 AppServices、界面状态 LedgerStore
│   ├── Intents/                   App Intent「记录银行动账通知」、AccountEntity、AppShortcuts
│   ├── UI/                        Shell（翻页、玻璃底栏、加号上拉）、Home、Assets、Stats、Profile、Pending
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
2. `swift test`（macOS 主机）+ `xcodebuild test`（iOS 模拟器）运行 BKCore 测试。模拟器按目标设备选择：优先 iPhone 16 Pro，其次其他 iPhone Pro，不使用双屏机型（[`ci/pick-simulator.sh`](ci/pick-simulator.sh)，第 5 步截图同样如此）；
3. 构建 Release / iphoneos / arm64、不签名的 `Bookkeeping.app`；
4. 校验可执行文件、Mach-O 平台、Info.plist、依赖、资源与 App Intents 元数据，打包为 `Payload/Bookkeeping.app` 的 IPA；
5. 在 iOS 模拟器上运行 Debug 版，浅色 / 深色各截首页、资产、统计、我的、待处理（[`ci/screenshots.sh`](ci/screenshots.sh)；App 以截图模式启动，使用独立的临时账本和虚构演示数据，见 [`ScreenshotMode.swift`](Bookkeeping/Diagnostics/ScreenshotMode.swift)，Release 构建中不生效）。截图失败只留警告，不影响 IPA；
6. 上传 IPA（含 SHA-256、build-info 与 `screenshots/`）和诊断产物。

推送 `ios-swift` 分支或在 Actions 页面手动运行（可选指定 Xcode 路径）。

## 本地（Windows）运行核心测试

没有 Mac 也可以用 Docker 在 Linux 上跑 `BKCore` 的全部测试（SwiftUI 部分只能在 CI 编译）：

```sh
# 一次性：带 SQLite 头文件的 Swift 镜像
printf 'FROM swift:latest\nRUN apt-get update && apt-get install -y libsqlite3-dev\n' | docker build -t bk-swift -
# 运行测试（PowerShell / Git Bash 均可，路径换成你的仓库位置）
docker run --rm -v "<仓库>/ios-swift/Packages/BKCore:/pkg" -w /pkg bk-swift swift test
```

## 安装到 iPhone

见 [Windows + Sideloadly 安装指南](../docs/guides/ios-swift-windows-sideloadly.md) 与 [真机验收清单](../docs/guides/ios-swift-device-checklist.md)。

## 自动记账

见 [features/ios-swift-auto-bookkeeping.md](../docs/features/ios-swift-auto-bookkeeping.md)。
