//
//  AvatarStudioModel.swift
//  DigitalCompanion
//
//  角色工坊的状态模型:加载底模 USDZ → 建 AvatarComposer → 中转 UI 编辑 →
//  存/取 AvatarRecipe(走 CompanionStorage,和 chat/memory 同轨同步)。
//
//  开发期底模:avatar_base_dev.usdz(spike 产物,双发型 + 2 捏脸 morph)。
//  正式底模就位后只换资产文件,这里不用动 —— manifest 是运行时扫出来的。
//

import Foundation
import RealityKit
import SwiftUI
import AVFoundation
import CompanionCore
import CompanionAvatar

@MainActor
@Observable
final class AvatarStudioModel {

    enum StudioState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 正在编辑的角色 id(新建后、保存前不入库 —— 是个"悬空"id)
    private(set) var editingPersonaID: String = CustomPersonaStore.defaultCustomID

    /// 已保存的自定义角色(角色条数据源;保存/删除后刷新)
    private(set) var savedCharacters: [CharacterPersona] = []

    /// 当前编辑目标是否还没保存过
    var isEditingUnsaved: Bool { CustomPersonaStore.persona(id: editingPersonaID) == nil }

    /// 删除角色后回调(参数 = 被删的 personaID;AppModel 用来在"删的是当前
    /// 聊天角色"时切回内置角色 + 清模型缓存)
    var onDeleted: ((String) -> Void)?

    private func refreshSavedCharacters() {
        savedCharacters = CustomPersonaStore.loadAll()
    }

    private(set) var state: StudioState = .idle
    private(set) var characterRoot: Entity?

    /// 当前底模(女/男)。资产、部件库、composer 都按底模成套切换
    private(set) var selectedBase: AvatarBase = .female
    private var composer: AvatarComposer?
    private var storage: (any CompanionStorage)?

    /// 可观察的配方镜像。AvatarComposer 不是 @Observable,视图直接读
    /// composer.recipe 不会建立依赖 → 选中高亮/滑杆不刷新。
    /// 所有 UI 读取走这份镜像,每次 composer 操作后同步。
    private(set) var recipeMirror: AvatarRecipe = .default

    /// 底模的 idle 动画。角色工坊必须播动画:裙类部件在 VRoid 里是
    /// 下摆外张着建模的(靠运行时弹簧垂落),我们的物理烘在动画里,
    /// bind pose 直接看是"翘起来"的。
    private var idleAnimation: AnimationResource?

    private func syncMirror() {
        if let composer { recipeMirror = composer.recipe }
    }

    private func playIdle() {
        guard let idleAnimation, let characterRoot else { return }
        characterRoot.playAnimation(idleAnimation.repeat())
    }

    /// 保存反馈(nil = 无提示)
    private(set) var saveFeedback: String?

    // MARK: - 人设(和外观一起在角色工坊编辑)

    /// 角色名字(空 → 保存时落默认名)
    var personaName: String = ""

    /// 性格描述(空 → 保存时落默认性格)
    var personaPersonality: String = ""

    /// 保存后回调(AppModel 清模型缓存用,保证下次进沉浸空间用新配方)
    var onSaved: (() -> Void)?

    // MARK: - 声线

    /// Apple 声线预设 id(nil = 未选,按 personaID 默认)
    var selectedApplePreset: String?

    /// Fish Audio reference ID(空 = 不指定 Fish 音色)
    var fishVoiceID: String = ""

    /// Fish key 是否已配置(声线页的 Fish 区按此显隐)
    var hasFishKey: Bool {
        KeychainService.load(forAccount: KeychainService.fishAudioAPIKeyAccount) != nil
    }

    /// 试听用独立合成器 —— 不碰全局 TTSService 的 profile
    @ObservationIgnored private let previewSynthesizer = AVSpeechSynthesizer()

    /// 选中并试听一个 Apple 预设
    func previewApplePreset(_ id: String) {
        selectedApplePreset = id
        guard let choice = AppleVoiceProfile.customChoices.first(where: { $0.id == id }) else { return }
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "嗨,今天过得怎么样?想跟我聊点什么呀?")
        utterance.voice = TTSService.bestVoice(language: "zh-CN",
                                               identifier: choice.profile.voiceIdentifier,
                                               gender: choice.profile.preferredGender)
        utterance.pitchMultiplier = choice.profile.pitch
        utterance.rate = choice.profile.rate
        previewSynthesizer.speak(utterance)
    }

    /// 从 Fish 声库按"底模性别 + 性格关键词"自动推荐
    func autoPickFishVoice() {
        if let v = FishVoiceLibrary.autoPick(base: selectedBase, personality: personaPersonality) {
            fishVoiceID = v.id
            saveFeedback = "已推荐:\(v.name)"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                saveFeedback = nil
            }
        }
    }

    // MARK: - AI 完善人设

    /// 正在调 LLM 生成
    private(set) var isGenerating = false

    /// 最近一次生成的完整角色卡(保存时优先使用;性格以输入框最终值为准)
    private(set) var generatedCard: PersonaCardGenerator.Card?

    /// 生成 = 名字 + 性格种子 + 外观提示 → 完整角色卡;
    /// 成功后把完善的性格回填输入框(用户可继续手改)
    func generatePersona(provider: LLMProvider) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        let name = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let card = try await PersonaCardGenerator.generate(
                name: name.isEmpty ? "小伙伴" : name,
                seedPersonality: personaPersonality,
                appearanceHint: appearanceHint(),
                provider: provider
            )
            generatedCard = card
            personaPersonality = card.personality
        } catch {
            saveFeedback = "生成失败:\(error.localizedDescription)"
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                saveFeedback = nil
            }
        }
    }

    /// 外观提示:当前发型/服饰的显示名(供 LLM 关联气质,不进 description)
    private func appearanceHint() -> String? {
        var parts: [String] = []
        if let h = selectedHair { parts.append(Self.partLabel(h)) }
        if let o = selectedOutfit { parts.append(Self.partLabel(o)) }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    // MARK: - UI 数据源

    var manifest: AvatarManifest? { composer?.manifest }

    /// 部件按前缀分两类:发型(hair*)/ 服饰(outfit*),各自单选
    var hairGroups: [AvatarManifest.PartGroup] {
        manifest?.partGroups.filter { $0.id.hasPrefix("hair") } ?? []
    }
    var outfitGroups: [AvatarManifest.PartGroup] {
        manifest?.partGroups.filter { $0.id.hasPrefix("outfit") } ?? []
    }
    var selectedHair: String? { recipeMirror.parts.first { $0.hasPrefix("hair") } }
    var selectedOutfit: String? { recipeMirror.parts.first { $0.hasPrefix("outfit") } }

    func morphWeight(_ name: String) -> Float {
        recipeMirror.morphs[name] ?? 0
    }

    /// morph 逻辑名 → 中文标签(没配的显示原名,提醒该补)
    static let morphLabels: [String: String] = [
        "eyes_h":      "眼睛横长",
        "eyes_v":      "眼睛纵长",
        "face_width":  "脸型宽度",
        "brow_height": "眉毛高度",
        "brow_thick":  "眉毛粗细",
        "ear_size":    "耳朵大小",
        // spike 底模的旧名,留着兼容
        "eyes_big":    "眼睛大小",
        "face_wide":   "脸型宽度",
    ]

    /// 部件组 id → 显示名("hair0" → "发型 基础","outfit2" → "服饰 2")
    static func partLabel(_ id: String) -> String {
        if id.hasPrefix("hair")   { return "发型 \(partShortLabel(id))" }
        if id.hasPrefix("outfit") { return "服饰 \(partShortLabel(id))" }
        return id
    }

    /// 按钮上用的短名(分区标题已标明类别):"hair0" → "基础","outfit2" → "2"
    static func partShortLabel(_ id: String) -> String {
        let n = id.hasPrefix("hair") ? String(id.dropFirst("hair".count))
              : id.hasPrefix("outfit") ? String(id.dropFirst("outfit".count))
              : id
        return n == "0" ? "基础" : n
    }

    /// 发色预设(名称, RGB)—— tint 是乘法,预设值偏亮才不会把贴图压黑
    static let hairPresets: [(String, AvatarRecipe.RecipeColor)] = [
        ("原色", .init(r: 1.0, g: 1.0, b: 1.0)),
        ("亚麻", .init(r: 1.0, g: 0.92, b: 0.78)),
        ("粉",   .init(r: 1.0, g: 0.68, b: 0.78)),
        ("青",   .init(r: 0.55, g: 0.95, b: 0.9)),
        ("紫",   .init(r: 0.8, g: 0.65, b: 1.0)),
    ]

    // MARK: - 生命周期

    func load(storage: any CompanionStorage) async {
        guard state == .idle || state.isFailure else { return }
        self.storage = storage
        refreshSavedCharacters()
        // 初始编辑目标:第一个已保存角色;一个都没有 → 新建空槽
        let target = savedCharacters.first?.id ?? CustomPersonaStore.allocateID()
        await switchEditing(to: target)
    }

    // MARK: - 多角色槽位

    /// 切换编辑目标(当前未保存的改动丢弃)。id 不在库中 = 编辑一个新空槽。
    func switchEditing(to id: String) async {
        state = .loading
        editingPersonaID = id
        generatedCard = nil
        // 先读该角色的外观存档决定底模(资产按底模分套:custom_{f|m}_*)
        let savedRecipe = try? await storage?.loadAvatarRecipe(personaID: id)
        let base = savedRecipe.flatMap { AvatarBase(rawValue: $0.baseID) } ?? .female
        do {
            try await loadBase(base, applying: savedRecipe)
            if let existing = CustomPersonaStore.persona(id: id) {
                personaName = existing.name
                personaPersonality = existing.personality ?? ""
                selectedApplePreset = existing.appleVoicePreset
                fishVoiceID = existing.voiceId ?? ""
            } else {
                personaName = ""
                personaPersonality = ""
                selectedApplePreset = nil
                fishVoiceID = ""
            }
            state = .ready
        } catch {
            state = .failed("加载失败: \(error.localizedDescription)")
        }
    }

    /// 新建角色(分配新 id,保存前不入库)
    func createNewCharacter() async {
        await switchEditing(to: CustomPersonaStore.allocateID())
    }

    /// 删除当前角色:persona + 外观配方 + 聊天记录 + 长期记忆一并清除,
    /// 然后切到剩余的第一个角色(或新空槽)
    func deleteCurrent() async {
        guard !isEditingUnsaved else { return }
        let id = editingPersonaID
        CustomPersonaStore.delete(id: id)
        if let storage {
            try? await storage.deleteAvatarRecipe(personaID: id)
            try? await storage.deleteChatSnapshot(personaID: id)
            try? await storage.deleteMemorySnapshot(personaID: id)
        }
        refreshSavedCharacters()
        onDeleted?(id)
        await switchEditing(to: savedCharacters.first?.id ?? CustomPersonaStore.allocateID())
    }

    /// 切换底模(女↔男):换底模资产 + 新 composer。
    /// 部件不跨底模(各底模部件库独立),滑杆值和发色保留。
    func switchBase(_ base: AvatarBase) async {
        guard base != selectedBase, state == .ready else { return }
        var carry = composer?.recipe ?? .default
        carry.parts = []
        carry.baseID = base.rawValue
        state = .loading
        do {
            try await loadBase(base, applying: carry)
            state = .ready
        } catch {
            state = .failed("切换底模失败: \(error.localizedDescription)")
        }
    }

    private struct StudioError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 加载指定底模的 idle 资产 → 建 composer → 应用配方(缺类补默认)→ 播 idle
    private func loadBase(_ base: AvatarBase, applying recipe: AvatarRecipe?) async throws {
        let name = base.idleFileName
        var found: URL? = nil
        for ext in ["usdz", "usdc"] {
            found = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext,
                                   subdirectory: "CustomAvatarAssets")
            if found != nil { break }
        }
        guard let url = found else {
            throw StudioError(message: "底模资产 \(name) 不在 bundle 里")
        }
        let entity = try await Entity(contentsOf: url)
        let composer = try AvatarComposer(character: entity)
        try composer.apply(recipe ?? .default)

        // 换底模前的旧实体从场景摘掉(RealityView update 闭包按 parent==nil 挂新的)
        characterRoot?.removeFromParent()

        self.composer = composer
        self.selectedBase = base
        syncMirror()
        // 兜底:配方净化后缺类(跨底模/旧部件名)→ 补该底模默认部件
        if selectedHair == nil, let h = hairGroups.first?.id {
            selectPart(h)
        }
        if selectedOutfit == nil, let o = outfitGroups.first?.id {
            selectPart(o)
        }

        self.characterRoot = entity
        self.idleAnimation = entity.availableAnimations.first
        playIdle()
        // 换部件重建 mesh 后重播,保证裙摆物理(烘在动画里)始终生效
        composer.onRebuild = { [weak self] _ in self?.playIdle() }
    }

    // MARK: - 编辑操作(全部同步,UI 直接调)

    /// 单选一个部件组;同前缀(hair/outfit)内互斥,另一类的选择保留
    func selectPart(_ id: String) {
        guard let composer else { return }
        let prefix = id.hasPrefix("hair") ? "hair" : "outfit"
        var parts = composer.recipe.parts.filter { !$0.hasPrefix(prefix) }
        parts.append(id)
        do {
            try composer.setParts(parts)
        } catch {
            state = .failed("换部件失败: \(error.localizedDescription)")
        }
        syncMirror()
    }

    func setMorph(_ name: String, _ value: Float) {
        composer?.setMorph(name, weight: value)
        syncMirror()
    }

    func setHairColor(_ color: AvatarRecipe.RecipeColor) {
        composer?.setColor(zone: "hair", color)
        syncMirror()
    }

    func setHairColor(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        setHairColor(AvatarRecipe.RecipeColor(r: Float(r), g: Float(g), b: Float(b)))
    }

    // MARK: - 存 / 重置

    /// 保存 = 外观配方 + 人设双写。之后角色出现在切换菜单里,
    /// 聊天/记忆/外观全部按 editingPersonaID 关联。
    func save() async {
        guard let composer, let storage else { return }
        do {
            var recipe = composer.recipe
            recipe.baseID = selectedBase.rawValue
            try await storage.saveAvatarRecipe(recipe, personaID: editingPersonaID)
            let trimmedFish = fishVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = VoiceSelection(
                applePreset: selectedApplePreset,
                fishVoiceID: trimmedFish.isEmpty ? nil : trimmedFish
            )
            let persona: CharacterPersona
            if let card = generatedCard {
                persona = CustomPersonaFactory.make(
                    id: editingPersonaID,
                    name: personaName,
                    personality: personaPersonality,
                    base: selectedBase,
                    voice: voice,
                    card: card
                )
            } else if let existing = CustomPersonaStore.persona(id: editingPersonaID) {
                // 只改了外观/名字/性格 → 保留既有角色卡的开场白/示例对话等丰富字段
                persona = CustomPersonaFactory.update(
                    existing,
                    name: personaName,
                    personality: personaPersonality,
                    base: selectedBase,
                    voice: voice
                )
            } else {
                persona = CustomPersonaFactory.make(
                    id: editingPersonaID,
                    name: personaName,
                    personality: personaPersonality,
                    base: selectedBase,
                    voice: voice
                )
            }
            CustomPersonaStore.upsert(persona)
            refreshSavedCharacters()
            personaName = persona.name   // 空名落默认后回填 UI
            onSaved?()
            saveFeedback = "已保存,\(persona.name) 已加入角色列表"
        } catch {
            saveFeedback = "保存失败: \(error.localizedDescription)"
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            saveFeedback = nil
        }
    }

    func reset() {
        guard let composer else { return }
        let defaults = [
            composer.manifest.partGroups.first { $0.id.hasPrefix("hair") }?.id,
            composer.manifest.partGroups.first { $0.id.hasPrefix("outfit") }?.id,
        ].compactMap { $0 }
        try? composer.apply(AvatarRecipe(parts: defaults))
        syncMirror()
    }
}

private extension AvatarStudioModel.StudioState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
