# 持仓宠物 Mac App Store 上架清单

本文档用于 Mac App Store 版本。官网 DMG 继续使用 `release-macos.sh`，两套签名和产物不要混用。

## 1. 账号与标识符

1. 在 Apple Developer 中注册显式 App ID：`com.stockpet.desktop`。
2. 在 App Store Connect 创建 macOS App：
   - 名称：持仓宠物
   - 主语言：简体中文
   - Bundle ID：`com.stockpet.desktop`
   - SKU：建议 `stockpet-macos`
   - 主分类：Finance
3. 创建 Mac App Store provisioning profile，下载为 `.provisionprofile`。
4. 在钥匙串中准备应用分发证书和安装包分发证书。

不要把证书、描述文件、App Store Connect API Key 或密码提交到 Git。

## 2. 商店版权限

`native/StockPet.entitlements` 只声明当前功能需要的权限：

- App Sandbox；
- 出站网络，用于行情和资讯；
- 用户选择文件只读，用于持仓截图；
- 下载目录读写，用于保存分享卡。

不申请摄像头、麦克风、通讯录、定位或全盘访问权限。

## 3. 隐私

- 应用内设置页链接到 `PRIVACY.md`；
- App Store Connect 的 Privacy Policy URL 可先填写：
  `https://github.com/andy304yang/Pet-stock/blob/main/PRIVACY.md`
- 正式提交前建议同步发布到：
  `https://mclarenai.cn/stock-pet/privacy`
- `native/PrivacyInfo.xcprivacy` 声明不追踪，并记录 UserDefaults 的本应用内设置用途。

App Store Connect 隐私问卷仍需由账号持有人根据最终行情供应商的条款填写，不能仅依赖隐私清单自动完成。

## 4. 素材与行情授权

商店构建脚本仅复制脚本内明确列出的公开资源：

- 原创 SwiftUI 行情机器人；
- 项目所有者确认可公开商用的 GPT娘及 2026-07-24 二创角色批次。

不要向商店版本加入未进入公开清单、或在 `THIRD_PARTY_NOTICES.md`
中仍标记为仅本地使用的素材。

当前行情和资讯会访问腾讯、新浪、Yahoo Finance、Nasdaq 与 Alpaca。正式提交前需要确认各服务允许在公开 App 中展示和分发数据，并保留授权或服务协议证据。Apple 可能要求提供。

## 5. 生成商店安装包

证书名称必须与“钥匙串访问”中显示的名称完全一致。所有值只放在当前终端环境中：

```bash
export APP_STORE_APP_IDENTITY='你的应用分发证书名称'
export APP_STORE_INSTALLER_IDENTITY='你的安装包分发证书名称'
export APP_STORE_PROVISIONING_PROFILE='/绝对路径/StockPet_AppStore.provisionprofile'

./build-app-store.sh 0.4.2 11
```

默认同时生成 Apple Silicon 和 Intel 代码，产物位于：

```text
app-store-export/StockPet-v0.4.2-build11.pkg
```

脚本会检查描述文件 Bundle ID、应用签名和安装包签名。它不会保存或输出证书密码。

## 6. 上传与审核

1. 使用 Transporter 上传 `.pkg`。
2. 等待 App Store Connect 处理完成。
3. 先添加到 Mac TestFlight，由用户完成实际验收。
4. 填写版本描述、关键词、支持 URL、隐私政策、年龄分级和版权信息。
5. 上传 1–10 张 16:10、无透明通道的真实截图。
6. 选择构建版本并提交审核。

建议审核备注：

> 持仓宠物是本地运行的桌面行情陪伴工具，不连接券商账户，不执行交易，不托管资金，不提供个性化投资建议。用户可手动录入持仓，也可选择截图在设备端识别。持仓金额和设置保存在本机；行情请求仅向所列数据服务发送证券代码。应用不要求登录。审核人员可点击“免登录示例”体验主要流程。

## 7. 用户验收

商店沙盒版必须由用户手动确认：

- 首次启动、展开和迷你窗口行为；
- 所有行情和资讯接口可以联网；
- 上传持仓截图后仍可识别；
- 分享卡能写入下载目录和剪贴板；
- Alpaca Keychain 保存、读取和删除；
- 系统通知授权与关闭；
- 只出现允许公开分发的宠物素材；
- Intel 与 Apple Silicon 机器的启动情况。
