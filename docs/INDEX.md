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
| `docs/` | 文档（见下表） |

## 文档目录

| 目录 | 内容 |
|---|---|
| [architecture/](architecture/) | [overview.md](architecture/overview.md)：分层与约定；[performance.md](architecture/performance.md)：性能规范与待验证项 |
| [decisions/](decisions/) | 架构决策记录（ADR）：[0001 本地优先](decisions/0001-local-first-no-server.md)、[0002 后端 Dart](decisions/0002-backend-dart.md)、[0003 数据库](decisions/0003-database-sqlite-drift.md)、[0004 同步](decisions/0004-sync-qr-lan.md)、[0005 自动记账](decisions/0005-auto-bookkeeping-screenshot-ocr.md) |
| [features/](features/) | 功能设计：[sync.md](features/sync.md)、[auto-bookkeeping.md](features/auto-bookkeeping.md) |
| [guides/](guides/) | [development.md](guides/development.md)：环境、命令、性能测量方法 |
