# 炉边系列 — 审核备注与提交清单

两款 App 已在 App Store Connect 中创建。2026-11-08 登录实查：iOS `6782957287` 与 visionOS `6782938484` 的 1.0 版本均为“准备提交”；**尚未上传构建、上传截图、填写后台资料或提交审核**。

| 实查项目 | 炉边·随身 iOS | 炉边 visionOS |
| --- | --- | --- |
| 构建版本 | 未关联 | 未关联 |
| 截图 | 0 张 | 0 张 |
| 产品页推广文本、描述、关键词、支持网址 | 空白 | 空白 |
| 隐私政策网址 / App Privacy 问卷 | 空白 / 尚未开始 | 空白 / 尚未开始 |
| 审核联系信息、备注 | 空白 | 空白 |
| “需要登录” | 当前被勾选，需按实际功能核对 | 当前被勾选，需按实际功能核对 |
| 审核通过后发布 | 当前选中自动发布，需由所有者确认 | 当前选中自动发布，需由所有者确认 |

App 信息中的副标题也为空；年龄分级、内容权利、销售范围和欧盟交易者状态仍需逐项核对。英文商店文案已有本地草稿 [`listing-en.md`](listing-en.md)，尚未在后台创建英文商店本地化。产品所有者已确认“炉边·随身”本次只面向 iPhone；iOS target 的 `TARGETED_DEVICE_FAMILY` 已改为 `1`，无需提供 iPad 截图。

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
| 炉边 | `../zh-Hans/VisionPro/05-gesture-interaction.png` | 3840×2160 |
| 炉边 | `../zh-Hans/VisionPro/06-character-workshop.png` | 3840×2160 |
| 炉边 | `../zh-Hans/VisionPro/07-movement-modes.png` | 3840×2160 |

以上是简体中文本地化素材。英文版也已生成 `../en/iPhone/01-listens.png` 至 `05-remembers.png`（5 张）和 `../en/VisionPro/01-spatial-chat.png` 至 `07-movement-modes.png`（7 张）。英文角色工坊使用手动取景的 `../en/VisionPro/06-avatar-studio-raw.jpeg`。上传最终合成图，不上传 `*-raw.png` 或 `*-raw.jpeg`。App Store Connect 每个设备尺寸可上传 1–10 张；按实际页面提示选择槽位。iPhone 原版 1320×2868 成品属于“带灵动岛的大屏”尺寸；现已额外生成 `../zh-Hans/iPhone-6.3/` 与 `../en/iPhone-6.3/` 各 5 张 1206×2622 成品，可用于当前网页默认的“中屏”槽位。visionOS 槽位接受 3840×2160。尺寸标准：[Apple Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。
手势图展示的是模拟器中的操作引导页和预置挥手动画，不是模拟器成功识别手势的画面；手势识别须在 Vision Pro 真机验证。移动模式图展示“自主”已选中及预置坐姿动画；模拟器不支持真实空间平面检测，自动寻座与移动效果须在 Vision Pro 真机确认。

中英文角色工坊图均使用手动调整取景的模拟器截图，人物脚部和地面关系已由开发者复核。两张原图右下角仍有模拟器操作控件；英文图的页签文字也有截断，正式上传前建议换成隐藏控件、使用最新英文 UI 构建的截图。

## 上架前待办

| 优先级 | 事项 | 当前情况 / 需要你决定 |
| --- | --- | --- |
| 必须 | 上传两个 Release 构建并检查 App 图标 | 工程已指定 `AppIcon`，iPhone 有 1024×1024 图标，visionOS 有分层图标；截图中的 App Store Connect 仍显示占位图标，可能因为构建尚未关联，需上传后核对。 |
| 已修复，待构建上传 | 构建显示名与后台名称一致 | Debug/Release 构建已显式设置“炉边”和“炉边·随身”；设备 Release 无签名编译通过，并检查了生成的 Info.plist。 |
| 必须 | 提供公开的支持网址、隐私政策网址和联系邮箱 | GitHub Pages 两个网址已于 2026-11-08 返回 HTTP 200：支持 `https://bruce5800.github.io/DigitalCompanion-OC/`；隐私 `https://bruce5800.github.io/DigitalCompanion-OC/privacy.html`；联系邮箱 `zhuolun66@gmail.com`。已给两端应用增加入口，仍需填入 App Store Connect。 |
| 必须 | App Privacy 问卷 | 核查 AI 服务商、Fish Audio、系统语音识别、iCloud 的数据流与各服务商政策；不要直接选择“不收集数据”。 |
| 必须 | 审核功能可测 | 准备专用低额度 AI API Key，仅填 App Store Connect 审核备注；确认两端正常对话，Vision Pro 的语音/空间功能可测。 |
| 必须 | 年龄分级、内容权利、定价和销售范围 | 按实际内容与商业模式填写；AI 生成内容的分级问题需如实回答，不能直接沿用其它 App 的“4+”。 |
| 必须 | 欧盟交易者状态 | 截图顶部提示：若向欧盟地区分发，需提供/确认交易者状态；不向欧盟分发则检查销售范围。 |
| 必须 | 出口合规 | 两端生成的设备 Release Info.plist 均为 `ITSAppUsesNonExemptEncryption=false`；仍需按实际加密使用情况核对后台问卷。 |
| 建议 | 完善密钥管理 | 两端已提供隐私/支持入口；API Key 设置页有保存和覆盖，但未见删除按钮。隐私草稿中相关措辞需在正式版功能确认后定稿。 |
| 已修复，待真机验证 | 更新不准确的权限文案 | Vision Pro 的 `NSWorldSensingUsageDescription` 已改为“识别周围空间中的平面与座位”，不再称追踪位置。 |
| 建议 | 核对截图与正式构建 | 截图由 Debug 演示数据生成；复核 Release UI、真实字体/图标、人物和聊天窗位置。演示数据必须仅 Debug 生效。 |

## 需要你提供或确认的值

- 运营者/版权主体；联系邮箱及两个 HTTPS 网址已在上文列出，请确认沿用。
- 免费还是付费、销售国家/地区、欧盟交易者状态。
- 两款 App 现支持界面中英切换；如果 App Store Connect 同时启用英文商店本地化，还需填写英文商店文案。
- 用于审核的专用 AI API Key（**不要发在聊天或提交到仓库**，只在 App Store Connect 的审核备注中填写）。
