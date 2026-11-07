//
//  CustomPersonaFactory.swift
//  DigitalCompanion
//
//  把角色工坊里用户填的"名字 + 性格"合成一份完整的 CharacterPersona。
//  动画映射固定指向 custom_* 资产(捏人底模过管线产出的 12 个动画,
//  与内置角色同一套 Mixamo 动作,所以映射表直接镜像 oc.json)。
//
//  说明:
//  - description/personality 都用用户输入的性格文本 —— MVP 不分字段,
//    后续可以加"用你的 LLM 帮我写人设"流程生成完整卡
//  - depthPrompt 用通用模板兜住角色一致性(名字 + 性格 + 简短回复约束)
//  - availableExpressions 排除 shy:VRoid 基础模型没有 Fcl_FACE_Blush
//

import Foundation
import CompanionCore

/// 角色工坊声线页的选择结果(nil = 不设置/保留原值)
struct VoiceSelection {
    var applePreset: String? = nil
    var fishVoiceID: String? = nil
}

enum CustomPersonaFactory {

    /// 用 AI 生成的完整角色卡构造(角色工坊"AI 完善人设"路径)。
    /// - Parameter personality: 用户在输入框里最终确认的性格文本
    ///   (可能在生成后又手改过,以输入框为准,覆盖卡内值)
    static func make(
        id: String,
        name: String,
        personality: String,
        base: AvatarBase,
        voice: VoiceSelection = .init(),
        card: PersonaCardGenerator.Card
    ) -> CharacterPersona {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "小伙伴" : trimmedName
        let personaText = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPersonality = personaText.isEmpty ? card.personality : personaText

        let reminder = card.depthReminder
            ?? "你是\(displayName)。你的性格:\(finalPersonality)"
        return CharacterPersona(
            id: id,
            name: displayName,
            voiceId: voice.fishVoiceID,
            appleVoicePreset: voice.applePreset,
            animations: Self.animationSet(for: base),
            description: card.description,
            personality: finalPersonality,
            scenario: card.scenario,
            firstMessage: card.firstMessage,
            alternateGreetings: card.alternateGreetings.isEmpty ? nil : card.alternateGreetings,
            exampleDialogs: card.exampleDialogs.isEmpty ? nil : card.exampleDialogs,
            tags: ["自定义", "AI人设"],
            depthPrompt: CharacterPersona.DepthPrompt(
                text: "(记住:\(reminder) 这是纯粹的陪伴关系。回复1-3句话,像面对面聊天般自然。)",
                depth: 6
            ),
            lorebook: nil,
            blinkEnabled: nil,
            availableExpressions: ["smile", "laugh", "sad", "angry", "surprised", "wink"],
            systemPrompt: nil
        )
    }

    static func make(id: String, name: String, personality: String, base: AvatarBase,
                     voice: VoiceSelection = .init()) -> CharacterPersona {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "小伙伴" : trimmedName
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaText = trimmedPersonality.isEmpty
            ? "温暖、真诚、健谈,喜欢倾听,回应体贴又不失幽默。"
            : trimmedPersonality

        return CharacterPersona(
            id: id,
            name: displayName,
            voiceId: voice.fishVoiceID,
            appleVoicePreset: voice.applePreset,
            animations: Self.animationSet(for: base),
            description: personaText,
            personality: personaText,
            scenario: nil,
            firstMessage: "嗨,{{user}}!我是\(displayName)。从今天起就由我陪着你啦——先聊聊,你今天过得怎么样?",
            alternateGreetings: [
                "(朝你挥挥手)来啦!我等你好一会儿了。今天有什么想跟我说的吗?"
            ],
            exampleDialogs: nil,
            tags: ["自定义"],
            depthPrompt: CharacterPersona.DepthPrompt(
                text: "(记住:你是\(displayName)。你的性格:\(personaText) 这是纯粹的陪伴关系。回复1-3句话,像面对面聊天般自然。)",
                depth: 6
            ),
            lorebook: nil,
            blinkEnabled: nil,
            availableExpressions: ["smile", "laugh", "sad", "angry", "surprised", "wink"],
            systemPrompt: nil
        )
    }

    /// 编辑已有角色但没有重新 AI 生成时用:保留既有角色卡的丰富字段
    /// (开场白/示例对话/场景/背景),只更新名字/性格/底模动画表 + 重建深度提醒。
    static func update(
        _ existing: CharacterPersona,
        name: String,
        personality: String,
        base: AvatarBase,
        voice: VoiceSelection = .init()
    ) -> CharacterPersona {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? existing.name : trimmedName
        let personaText = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPersonality = personaText.isEmpty ? (existing.personality ?? "") : personaText

        return CharacterPersona(
            id: existing.id,
            name: displayName,
            voiceId: voice.fishVoiceID ?? existing.voiceId,
            appleVoicePreset: voice.applePreset ?? existing.appleVoicePreset,
            animations: Self.animationSet(for: base),
            description: existing.description,
            personality: finalPersonality,
            scenario: existing.scenario,
            firstMessage: existing.firstMessage,
            alternateGreetings: existing.alternateGreetings,
            exampleDialogs: existing.exampleDialogs,
            tags: existing.tags,
            depthPrompt: CharacterPersona.DepthPrompt(
                text: "(记住:你是\(displayName)。你的性格:\(finalPersonality) 这是纯粹的陪伴关系。回复1-3句话,像面对面聊天般自然。)",
                depth: 6
            ),
            lorebook: existing.lorebook,
            blinkEnabled: existing.blinkEnabled,
            availableExpressions: existing.availableExpressions,
            systemPrompt: nil
        )
    }

    /// 表演(唱歌+跳舞):该底模的舞蹈剪辑和歌曲音频都在 bundle 里才加入 ——
    /// 素材不在场就不出现在动画表里,LLM 也就不会选到它。
    /// 换歌/换舞蹈 = 替换 custom_{f|m}_dance 剪辑和 custom_song 音频,零代码改动。
    private static func performanceMapping(for base: AvatarBase) -> CharacterPersona.AnimationMapping? {
        let clip = base.fileName(clip: "dance")
        let hasClip = ["usdz", "usdc"].contains { ext in
            Bundle.main.url(forResource: clip, withExtension: ext) != nil
                || Bundle.main.url(forResource: clip, withExtension: ext,
                                   subdirectory: "CustomAvatarAssets") != nil
        }
        guard hasClip, PerformanceService.locateAudio(named: "custom_song") != nil else {
            return nil
        }
        return .init(id: "sing", fileName: clip, displayName: "唱歌",
                     emotion: "唱一首歌并跳舞(用户点歌/请求表演时使用)",
                     kind: "performance", audioFile: "custom_song")
    }

    /// 与 oc.json 一一对应的动画映射,fileName 按底模指向 custom_{f|m}_* 资产
    private static func animationSet(for base: AvatarBase) -> [CharacterPersona.AnimationMapping] {
        func f(_ clip: String) -> String { base.fileName(clip: clip) }
        var set: [CharacterPersona.AnimationMapping] = [
            .init(id: "idle",       fileName: f("idle"),            displayName: "站立静止", emotion: "默认站立、平静日常对话时使用"),
            .init(id: "happy",      fileName: f("happy"),           displayName: "开心",     emotion: "心情好、被肯定、收到喜欢的话题、表扬时使用"),
            .init(id: "sadIdle",    fileName: f("sad_idle"),        displayName: "难过站立", emotion: "失落、被否定、提到失约/坏消息时使用"),
            .init(id: "thinking",   fileName: f("thinking"),        displayName: "思考",     emotion: "权衡、犹豫、回答前需要琢磨时使用"),
            .init(id: "thankful",   fileName: f("thankful"),        displayName: "感激",     emotion: "感谢、被照顾、收到关心时使用"),
            .init(id: "waving",     fileName: f("waving"),          displayName: "挥手问候", emotion: "初次见面、重逢、友好打招呼时使用(首条消息常用)"),
            .init(id: "nodYes",     fileName: f("head_nod_yes"),    displayName: "点头",     emotion: "同意、肯定、'嗯/是的/对'时使用"),
            .init(id: "shakeNo",    fileName: f("shaking_head_no"), displayName: "摇头",     emotion: "否定、'不是/不对/不行'时使用"),
            .init(id: "lookAround", fileName: f("look_around"),     displayName: "环顾",     emotion: "好奇、留意周遭、被新事物吸引时使用"),
            .init(id: "talking",    fileName: f("talking"),         displayName: "交谈手势", emotion: "用手势辅助表达观点、解释概念时使用"),
            .init(id: "walk",       fileName: f("walking"),         displayName: "步行",
                  emotion: "走路动作(由系统自动播放,LLM 不要直接选此项)", kind: "walk"),
            .init(id: "sitIdle",    fileName: f("sitting_idle"),    displayName: "坐姿静止",
                  emotion: "坐下后的静态姿势(由系统坐下流程自动播放,LLM 不要直接选此项)", kind: "sit"),
        ]
        if let perf = performanceMapping(for: base) {
            set.append(perf)
        }
        return set
    }
}
