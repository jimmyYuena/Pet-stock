---
name: pet-stock-user-acceptance
description: Enforce user-only runtime and visual acceptance for the Pet-stock/持仓宠物 project while allowing explicit release publishing. Use for every task in this repository, especially SwiftUI, window behavior, animations, stock data, packaging, UI work, and GitHub releases. Prevent Codex from launching, debugging, testing, visually inspecting, or accepting the application; when the user requests a release to GitHub, allow building, packaging, artifact verification, committing, pushing, and uploading the release without additional permission.
---

# 持仓宠物：仅用户验收

## 核心规则

只修改代码和静态文件。将运行、调试、测试、视觉检查和最终验收全部交给用户。

默认禁止执行以下操作：

- 启动或操作持仓宠物应用，包括 `run-dev.sh`、`open`、Xcode Run 和直接执行 `StockPet`。
- 在非发布任务中编译、构建、打包或运行测试。
- 使用 Computer Use、浏览器自动化、截图或其他界面工具检查应用。
- 模拟点击、悬停、拖动、窗口缩放、通知或股票搜索。
- 修改 `UserDefaults` 或其他本机应用运行状态来验证功能。
- 声称功能“正常”“已验证”“测试通过”或“符合设计”。

除非用户明确表示“本次暂停仅用户验收规则”或“允许 Codex 调试”，否则后续出现“修复”“完成”等要求也不构成运行或验收授权。

## GitHub 发布例外

当用户明确要求“发布”“打包并提交 GitHub”或“提交代码和安装包”时，将其视为发布授权，无需再询问是否允许打包。可以直接：

- 编译发布产物，运行 `build-native.sh`。
- 生成 DMG，执行代码签名、Plist、校验和完整性检查。
- 扫描密钥与提交范围，提交并推送代码。
- 创建或更新 GitHub Release，上传 DMG 安装包。

发布例外不允许启动应用、Computer Use、界面调试、交互测试或视觉验收。构建和安装包完整性检查属于发布流程，不代表用户验收。

## 工作方式

1. 阅读必要代码和项目说明。
2. 实现用户要求，保持改动范围最小。
3. 只做不执行项目代码的静态检查，例如检查 diff、路径、配置文本和明显语法结构。
4. 不因缺少运行验证而阻塞代码修改。
5. 将所有动态结果标记为未验证，交给用户实际运行确认。

## 交付格式

最终回复必须包含：

- 修改了什么。
- 涉及哪些文件。
- 非发布任务明确写出：`未运行、未调试、未代替用户验收。`
- 发布任务明确写出：`已构建发布包；未启动应用、未进行界面调试、未代替用户验收。`
- 一份简短的用户验收清单，列出用户需要手动检查的交互和预期结果。

如果发现只有运行后才能判断的问题，说明风险和需要用户观察的现象，不自行运行。
