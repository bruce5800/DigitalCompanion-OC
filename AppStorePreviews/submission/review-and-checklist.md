# 炉边系列 — 审核备注与提交清单

两款 App 在 App Store Connect 中已创建，但截图显示仍为“准备提交”和占位图标。本清单用于整理材料，**没有上传构建、填写后台或提交审核**。

## App Review Information → Notes（建议英文粘贴，密钥只在后台填写）

### 炉边·随身（iPhone）

> Fireside Pocket is a text-chat companion app with three original characters. No account is required. On launch, choose a character and open a chat. The app offers limited scripted replies without setup; full AI chat requires a user-provided API key. For review, please choose DeepSeek in Settings → API Key Configuration and enter the dedicated review key provided below. Then return to a chat and send a message. You can switch characters, edit the user persona and avatar, and inspect or delete memory in Settings.
>
> Review API key: [PASTE A LIMITED, VALID REVIEW KEY IN APP STORE CONNECT ONLY]
>
> AI requests are sent directly to the selected provider. Chat and memory use the user's iCloud Documents when available and fall back to on-device storage otherwise. The key is stored in Keychain. No login or developer-hosted server is required for the current flow.

### 炉边（Apple Vision Pro）

> Fireside is a spatial companion app for Apple Vision Pro. No account is required. Open the app, select one of the original characters, and enter the immersive experience. The character appears in the user's space; the chat window is positioned beside the character. Text chat is available without microphone permission. Voice input requires microphone and speech-recognition permission. Apple system speech can be used without a Fish Audio key; Fish Audio voice selection is optional.
>
> Full AI chat requires a user-provided API key. For review, choose DeepSeek in the API Key setup screen and enter the dedicated review key below, then send a text message or speak to the character. Without a key the app only offers limited scripted replies.
>
> Review API key: [PASTE A LIMITED, VALID REVIEW KEY IN APP STORE CONNECT ONLY]
>
> Hand tracking and world sensing support spatial character interaction. Chat and memory use the user's iCloud Documents when available and fall back to on-device storage otherwise.

审核前请实机/模拟器按以上路径逐步走通并调整文案。审核专用密钥建议设置低额度、可撤销；**不要提交到 Git 或放进截图**。App Review 要能完整访问需审核的功能：[Apple Review Information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

## 截图上传顺序

| App | 文件 | 像素 |
| --- | --- | --- |
| 炉边·随身 | `../zh-Hans/iPhone/01-listens.png` | 1320×2868 |
| 炉边·随身 | `../zh-Hans/iPhone/02-thinks-with-you.png` | 1320×2868 |
| 炉边·随身 | `../zh-Hans/iPhone/03-small-joys.png` | 1320×2868 |
| 炉边·随身 | `../zh-Hans/iPhone/04-your-avatar.png` | 1320×2868 |
| 炉边·随身 | `../zh-Hans/iPhone/05-remembers.png` | 1320×2868 |
| 炉边 | `../zh-Hans/VisionPro/01-spatial-chat.png` | 3840×2160 |
| 炉边 | `../zh-Hans/VisionPro/02-companion-oc.png` | 3840×2160 |
| 炉边 | `../zh-Hans/VisionPro/03-companion-sg.png` | 3840×2160 |
| 炉边 | `../zh-Hans/VisionPro/04-companion-xo.png` | 3840×2160 |

以上是简体中文本地化素材，上传最终合成图，不上传 `*-raw.png`。App Store Connect 每个设备尺寸可上传 1–10 张；按实际页面提示选择槽位。尺寸标准：[Apple Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。

## 上架前待办

| 优先级 | 事项 | 当前情况 / 需要你决定 |
| --- | --- | --- |
| 必须 | 上传两个 Release 构建并检查 App 图标 | 工程已指定 `AppIcon`，iPhone 有 1024×1024 图标，visionOS 有分层图标；截图中的 App Store Connect 仍显示占位图标，可能因为构建尚未关联，需上传后核对。 |
| 必须 | 构建显示名与后台名称一致 | 当前 Xcode 工程没有显式 `CFBundleDisplayName`；需在 Release 构建上确认主屏幕分别显示“炉边”和“炉边·随身”。 |
| 必须 | 提供公开的支持网址、隐私政策网址和联系邮箱 | 目前只有本地草稿，不能把文件路径填入 App Store Connect；隐私政策还需 App 内可访问。 |
| 必须 | App Privacy 问卷 | 核查 AI 服务商、Fish Audio、系统语音识别、iCloud 的数据流与各服务商政策；不要直接选择“不收集数据”。 |
| 必须 | 审核功能可测 | 准备专用低额度 AI API Key，仅填 App Store Connect 审核备注；确认两端正常对话，Vision Pro 的语音/空间功能可测。 |
| 必须 | 年龄分级、内容权利、定价和销售范围 | 按实际内容与商业模式填写；AI 生成内容的分级问题需如实回答，不能直接沿用其它 App 的“4+”。 |
| 必须 | 欧盟交易者状态 | 截图顶部提示：若向欧盟地区分发，需提供/确认交易者状态；不向欧盟分发则检查销售范围。 |
| 必须 | 出口合规 | visionOS `Info.plist` 已有 `ITSAppUsesNonExemptEncryption=false`；iOS 构建和后台问卷仍需按实际使用加密情况核对。 |
| 建议 | 完善 App 内隐私和密钥管理 | 当前设置页未见隐私政策入口；API Key 设置页有保存和覆盖，但未见删除按钮。隐私草稿中相关措辞需在正式版功能确认后定稿。 |
| 建议 | 更新不准确的权限文案 | Vision Pro 的 `NSWorldSensingUsageDescription` 写着“追踪您的位置”，实际用途应准确表述为角色在空间中的定位/交互，避免让用户误以为做地理位置追踪。 |
| 建议 | 核对截图与正式构建 | 截图由 Debug 演示数据生成；复核 Release UI、真实字体/图标、人物和聊天窗位置。演示数据必须仅 Debug 生效。 |

## 需要你提供或确认的值

- 运营者/版权主体、公开联系邮箱、支持和隐私政策的 HTTPS 发布位置。
- 免费还是付费、销售国家/地区、欧盟交易者状态。
- 两款 App 是否只上简体中文；若还上其他本地化，需要另备文案和截图。
- 用于审核的专用 AI API Key（**不要发在聊天或提交到仓库**，只在 App Store Connect 的审核备注中填写）。
