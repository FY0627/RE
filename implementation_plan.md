# Implementation Plan: 严格控制变量测试：仅移除卡面插画装饰并恢复图层缓存（不改毛玻璃） (v17)

## 1. 背景与用户反馈

用户决策：
**“毛玻璃部分可以先不修改吧，只修改贴图试试看，如果效果明显变好了但是还是没到要求的话再着手修改，我们要控制变量，必须知道为什么性能不够”**

为实现最严谨的科学控制变量，准确找出性能损耗归因：
- **毛玻璃相关逻辑完全不改动**：保持 `LiquidGlassSurface` 与 `GestureAddButton` 原汁原味；
- **仅聚焦于卡片渲染内部**：
  1. 移除卡面中由数十个小部件组合绘制的「线条小狗复杂插画」及溢出装饰光泽圈，模拟未来单张静态图片的极简卡面；
  2. 恢复 `SliverWalletCards` 的 `addRepaintBoundaries: true`（上一轮设为 `false` 导致每帧强制重绘卡片，产生 3.5ms 劣化回归）；
  3. 保持 50 张卡片压力数据集。

---

## 2. 范围与边界

- **包含范围**：
  - [`lib/pages/assets_page.dart`](lib/pages/assets_page.dart)：
    - 移除 `_walletCardFace` 中的代码插画 `_cachedPuppyArt()` 与右上角装饰光泽圆；
    - 恢复 `SliverWalletCards` 的 `delegate` 属性 `addRepaintBoundaries: true`；
    - 保持 50 张卡片。
- **排除范围**：
  - **绝不修改** [`lib/widgets/liquid_glass_surface.dart`](lib/widgets/liquid_glass_surface.dart)；
  - **绝不修改** [`lib/widgets/gesture_add_button.dart`](lib/widgets/gesture_add_button.dart)。

---

## 3. 任务分解与合同

### Task T23: 仅移除卡面代码插画装饰并恢复卡片图层缓存
- **目标**：以严格单一变量验证去除卡面复杂图元与恢复缓存贴图对 GPU 光栅化耗时的具体影响。
- **涉及文件**：[`lib/pages/assets_page.dart`](lib/pages/assets_page.dart)
- **输入输出**：
  - `_walletCardFace`：移除 `if (account.isPuppyCard) _cachedPuppyArt()`，移除右上角 `Container` 装饰圆；
  - `SliverWalletCards`：设置 `addRepaintBoundaries: true`；
  - 保留 50 张卡片。
- **验收检查**：
  - `flutter analyze` 0 错误 0 警告；
  - `flutter test test/assets_page_test.dart` 全部通过；
  - 毛玻璃完全不受任何影响。

---

## 4. 恢复与回滚准备
- 当前工作区代码已有完整快照，随时可一键撤回。

---

## Authorization Record

- Status: APPROVED
- Plan Revision: v17
- Operator Selection: A. 批准
- Approved Scope: ALL (Task T23)
- Approved At: 2026-10-10T14:08:57+08:00
- Execution Prerequisites: None
- Handoff Status: READY_FOR_IMPLEMENTATION (Target: implementation)
