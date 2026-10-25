# 文档与代码索引

用途：从「问题」直接定位到「该读的文档」和「该看的代码」，不用通读整个仓库。

> **维护规则**：新增、移动或删除模块、文档、决策时，必须同步更新本文件。

## 按问题查

| 问题 / 关键词 | 先读文档 | 再看代码 |
|---|---|---|
| 整体架构、分层，某段代码该放在哪 | [architecture/overview.md](architecture/overview.md) | 各层根目录 |
| 卡顿、掉帧、内存高、低端机体验 | [architecture/performance.md](architecture/performance.md) | `app/lib/shared/rendering/`、对应的 `app/lib/features/<模块>/` |
| 记账流水：新增 / 编辑 / 删除账单 | [architecture/overview.md](architecture/overview.md) | `app/lib/features/ledger/` → `backend/lib/src/ledger/` → `database/lib/src/` |
| 资产账户、卡包 | [architecture/overview.md](architecture/overview.md) | `app/lib/features/assets/` → `backend/lib/src/assets/` |
| 统计、报表、汇总结果不对 | [architecture/overview.md](architecture/overview.md) | `app/lib/features/stats/` → `backend/lib/src/stats/` |
| 设置、外观、「我的」页面 | — | `app/lib/features/profile/` |
| 表结构、数据库迁移、查询慢 | [decisions/0003](decisions/0003-database-sqlite-drift.md) | `database/lib/src/{tables,daos,migrations}/` |
| 多端同步：配对失败、连不上、数据冲突 | [features/sync.md](features/sync.md) | `app/lib/features/sync/` → `backend/lib/src/sync/` |
| 自动记账：金额 / 商户 / 时间解析错误 | [features/auto-bookkeeping.md](features/auto-bookkeeping.md) | `backend/lib/src/auto_entry/` |
| 自动记账：悬浮窗、截屏、OCR、快捷指令 | [features/auto-bookkeeping.md](features/auto-bookkeeping.md) | `native/android/`、`native/ios/`、`native/lib/` |
| 为什么选 X 而不选 Y | [decisions/](decisions/) | — |
| 开发环境、运行、测试、性能测量 | [guides/development.md](guides/development.md) | `.github/workflows/ci.yml` |
| 原型里某个效果是怎么实现的 | [architecture/performance.md#原型参考](architecture/performance.md#原型参考) | `prototype` 分支的 `lib/` |
| **iOS Swift 版**：整体结构、分层 | [ios-swift/README.md](../ios-swift/README.md)、[decisions/0006](decisions/0006-ios-native-swift.md) | `ios-swift/` |
| iOS Swift 版：短信 / 邮件自动记账、解析、去重、待处理 | [features/ios-swift-auto-bookkeeping.md](features/ios-swift-auto-bookkeeping.md)、[decisions/0008](decisions/0008-ios-swift-shortcuts-app-intent.md) | `ios-swift/Bookkeeping/Intents/` → `ios-swift/Packages/BKCore/Sources/BKBackend/` |
| iOS Swift 版：表结构、迁移、事务、并发 | [decisions/0007](decisions/0007-ios-swift-sqlite.md) | `ios-swift/Packages/BKCore/Sources/BKDatabase/` |
| iOS Swift 版：卡包、详情转场、添加卡「+」、卡片信息与卡号、卡面编辑（自定义图片）、初始余额 | [ios-swift/README.md](../ios-swift/README.md)、[decisions/0010](decisions/0010-ios-swift-card-number-and-face.md) | `ios-swift/Bookkeeping/UI/{Assets,Shell}/` |
| iOS Swift 版：卡顿、性能开关、帧率指标 | [guides/ios-swift-device-checklist.md](guides/ios-swift-device-checklist.md) | `ios-swift/Bookkeeping/Diagnostics/` |
| iOS Swift 版：CI 构建、IPA、Sideloadly 安装与续签 | [guides/ios-swift-windows-sideloadly.md](guides/ios-swift-windows-sideloadly.md)、[decisions/0009](decisions/0009-ios-swift-ci-sideloadly.md) | `.github/workflows/ios-swift-build.yml`、`ios-swift/ci/` |

## 按目录查

| 目录 | 职责 |
|---|---|
| `app/` | 前端（Flutter），只负责展示和交互，通过 `bk_backend` 访问数据 |
| `app/lib/app/` | 根组件：MaterialApp、主题、路由、服务注入 |
| `app/lib/features/ledger/` | 明细 / 记账页 |
| `app/lib/features/assets/` | 资产账户与卡包页 |
| `app/lib/features/stats/` | 统计页 |
| `app/lib/features/profile/` | 「我的」与设置页 |
| `app/lib/features/sync/` | 同步页：显示 / 扫描二维码、同步进度 |
| `app/lib/shared/widgets/` | 跨页面复用的普通组件 |
| `app/lib/shared/rendering/` | 高性能自定义渲染（RenderObject、绘制缓存等） |
| `backend/` | 后端（纯 Dart，运行在手机内），对外的入口是 `lib/bk_backend.dart` |
| `backend/lib/src/ledger/` | 记账服务 |
| `backend/lib/src/assets/` | 资产账户服务 |
| `backend/lib/src/stats/` | 统计服务（SQL 聚合） |
| `backend/lib/src/sync/` | 同步：变更日志、合并、局域网传输 |
| `backend/lib/src/auto_entry/` | 自动记账：OCR 文本 → 账单候选的规则解析 |
| `database/` | 数据库（纯 Dart，SQLite + drift），对外的入口是 `lib/bk_database.dart` |
| `database/lib/src/tables/` | 表定义 |
| `database/lib/src/daos/` | 数据访问对象 |
| `database/lib/src/migrations/` | 版本迁移 |
| `native/` | 原生能力插件：Dart 接口在 `lib/`，实现在 `android/`（Kotlin）和 `ios/`（Swift） |
| `ios-swift/` | iOS 原生 Swift 版（独立工程，不依赖 Flutter），见 [ios-swift/README.md](../ios-swift/README.md) |
| `ios-swift/Bookkeeping/` | App target：SwiftUI 界面、App Intents、性能诊断 |
| `ios-swift/Packages/BKCore/` | 纯 Swift 业务核心：`BKModel` 值类型、`BKDatabase` SQLite、`BKBackend` 解析与入账 |
| `ios-swift/ci/` | GitHub Actions 调用的测试、构建、打包、校验脚本 |
| `docs/` | 文档（见下表） |

## 文档目录

| 目录 | 内容 |
|---|---|
| [architecture/](architecture/) | [overview.md](architecture/overview.md)：分层与约定；[performance.md](architecture/performance.md)：性能规范与待验证项 |
| [decisions/](decisions/) | 架构决策记录（ADR）：[0001 本地优先](decisions/0001-local-first-no-server.md)、[0002 后端 Dart](decisions/0002-backend-dart.md)、[0003 数据库](decisions/0003-database-sqlite-drift.md)、[0004 同步](decisions/0004-sync-qr-lan.md)、[0005 自动记账](decisions/0005-auto-bookkeeping-screenshot-ocr.md)、[0006 iOS 改用原生 Swift](decisions/0006-ios-native-swift.md)、[0007 iOS Swift 数据库](decisions/0007-ios-swift-sqlite.md)、[0008 iOS Swift 自动记账接入](decisions/0008-ios-swift-shortcuts-app-intent.md)、[0009 iOS Swift 构建与分发](decisions/0009-ios-swift-ci-sideloadly.md)、[0010 iOS Swift 卡号与卡面](decisions/0010-ios-swift-card-number-and-face.md) |
| [features/](features/) | 功能设计：[sync.md](features/sync.md)、[auto-bookkeeping.md](features/auto-bookkeeping.md)、[ios-swift-auto-bookkeeping.md](features/ios-swift-auto-bookkeeping.md) |
| [guides/](guides/) | [development.md](guides/development.md)：环境、命令、性能测量方法；[ios-swift-windows-sideloadly.md](guides/ios-swift-windows-sideloadly.md)：Windows 下载 IPA、Sideloadly 安装与续签；[ios-swift-device-checklist.md](guides/ios-swift-device-checklist.md)：真机验收清单 |
