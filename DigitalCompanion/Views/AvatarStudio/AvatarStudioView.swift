//
//  AvatarStudioView.swift
//  DigitalCompanion
//
//  捏人间(volumetric 窗口):角色模型立在中间,控制面板作为
//  RealityView attachment 飘在右侧 —— visionOS 原生的"对着 3D 模型捏"。
//
//  面板三区:发型(单选)/ 捏脸(滑杆)/ 发色(预设 + 自选)。
//  数据源全部来自 composer.manifest 运行时扫描,换底模资产零改动。
//

import SwiftUI
import RealityKit
import CompanionCore
import CompanionAvatar

struct AvatarStudioView: View {

    @Environment(AppModel.self) private var appModel
    @State private var model = AvatarStudioModel()
    @State private var pickedColor: Color = .white
    @State private var page: StudioPage = .style
    @State private var showDeleteConfirm = false

    /// 角色在音量窗里的摆位(窗原点在几何中心;模型 ~1.5m 高)
    private static let characterScale: Float = 0.8
    private static let characterY: Float = -0.62

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = "studioRoot"
            content.add(root)

            if let panel = attachments.entity(for: "controlPanel") {
                panel.position = [0.42, 0.05, 0.15]
                content.add(panel)
            }
        } update: { content, attachments in
            // 模型加载完成后挂进场景(update 会被多次调用,用 parent 判重)
            if let character = model.characterRoot,
               character.parent == nil,
               let root = content.entities.first(where: { $0.name == "studioRoot" }) {
                character.scale = .init(repeating: Self.characterScale)
                character.position = [0, Self.characterY, 0]
                root.addChild(character)
            }
        } attachments: {
            Attachment(id: "controlPanel") {
                controlPanel
            }
        }
        .task {
            // 保存后清模型缓存:下次进沉浸空间即用新外观
            model.onSaved = { appModel.clearModelCache() }
            // 删除的是当前聊天角色 → 切回内置角色,避免悬空 persona
            model.onDeleted = { deletedID in
                appModel.clearModelCache()
                if appModel.currentPersona?.id == deletedID {
                    appModel.switchCharacter(to: "oc")
                }
            }
            await model.load(storage: appModel.storage)
        }
    }

    // MARK: - 控制面板

    @ViewBuilder
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("捏人间")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                if let feedback = model.saveFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            switch model.state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载底模中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .ready:
                editorSections
            }
        }
        .padding(24)
        .frame(width: 340)
        .glassBackgroundEffect()
    }

    /// 面板分页。加新页 = 这里加 case + pageContent 加分支,其余全自动。
    enum StudioPage: String, CaseIterable, Identifiable {
        case persona = "人设"
        case style   = "造型"
        case face    = "捏脸"
        case color   = "发色"
        case voice   = "声线"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .persona: return "person.text.rectangle"
            case .style:   return "tshirt"
            case .face:    return "slider.horizontal.3"
            case .color:   return "paintpalette"
            case .voice:   return "waveform"
            }
        }
    }

    @ViewBuilder
    private var editorSections: some View {
        // —— 角色条:已保存角色 + 新建(多槽位)——
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.savedCharacters, id: \.id) { c in
                    let isCurrent = model.editingPersonaID == c.id
                    Button {
                        Task { await model.switchEditing(to: c.id) }
                    } label: {
                        Text(c.name)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isCurrent ? .accentColor : .secondary.opacity(0.25))
                }
                if model.isEditingUnsaved {
                    Text("新角色·未保存")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Button {
                    Task { await model.createNewCharacter() }
                } label: {
                    Image(systemName: "plus")
                        .font(.footnote)
                        .padding(6)
                }
                .disabled(model.isEditingUnsaved)
            }
        }

        // 页签
        Picker("", selection: $page) {
            ForEach(StudioPage.allCases) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        // 当前页内容(固定高度,页间切换面板不跳动)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(height: 300)

        Divider()

        // —— 操作(所有页共用,固定底部)——
        HStack {
            Button("重置", role: .destructive) {
                model.reset()
            }
            Spacer()
            Button {
                Task { await model.save() }
            } label: {
                Label("保存角色", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let manifest = model.manifest {
            switch page {
            case .persona:
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("名字", icon: "signature")
                    TextField("如:小雨", text: $model.personaName)
                        .textFieldStyle(.roundedBorder)
                    sectionTitle("性格", icon: "sparkles")
                    TextField("如:开朗爱笑,嘴上毒舌心里柔软…",
                              text: $model.personaPersonality, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    // —— AI 完善(用用户自己的 LLM key 扩写成完整角色卡)——
                    Button {
                        Task { await model.generatePersona(provider: appModel.selectedProvider) }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isGenerating {
                                ProgressView().controlSize(.mini)
                                Text("生成中…")
                            } else {
                                Image(systemName: "wand.and.stars")
                                Text(model.generatedCard == nil ? "AI 完善人设" : "重新生成")
                            }
                        }
                        .font(.footnote)
                    }
                    .disabled(model.isGenerating || !appModel.isAPIKeyConfigured)
                    if !appModel.isAPIKeyConfigured {
                        Text("需要先在设置里配置 API Key")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // 删除角色(仅已保存的;连带清聊天/记忆/外观存档)
                    if !model.isEditingUnsaved {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除该角色", systemImage: "trash")
                                .font(.footnote)
                        }
                        .confirmationDialog(
                            "删除「\(model.personaName)」?聊天记录和记忆会一并清除,不可恢复。",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("删除", role: .destructive) {
                                Task { await model.deleteCurrent() }
                            }
                        }
                    }

                    // 生成结果预览(开场白最能体现效果;背景/示例对话一并入卡)
                    if let card = model.generatedCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("开场白", systemImage: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(card.firstMessage)
                                .font(.caption)
                            if let scenario = card.scenario {
                                Text(scenario)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        Text("性格已回填上方输入框,可以继续手改;保存时以输入框为准")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .style:
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("底模", icon: "figure.arms.open")
                    Picker("", selection: Binding(
                        get: { model.selectedBase },
                        set: { newBase in Task { await model.switchBase(newBase) } }
                    )) {
                        ForEach(AvatarBase.allCases) { base in
                            Text(base.displayName).tag(base)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("切换底模会重置发型/服饰选择,捏脸和发色保留")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                partSection(title: "发型", icon: "comb",
                            groups: model.hairGroups, selected: model.selectedHair)
                partSection(title: "服饰", icon: "tshirt",
                            groups: model.outfitGroups, selected: model.selectedOutfit)

            case .face:
                if manifest.morphs.isEmpty {
                    Text("该底模没有捏脸滑杆")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(manifest.morphs, id: \.self) { morph in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AvatarStudioModel.morphLabels[morph] ?? morph)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.morphWeight(morph) },
                                set: { model.setMorph(morph, $0) }
                            ),
                            in: 0...1
                        )
                    }
                }

            case .voice:
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Apple 声线", icon: "speaker.wave.2")
                    Text("点按即试听;不选则用系统默认声线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(AppleVoiceProfile.customChoices, id: \.id) { choice in
                            let isSelected = model.selectedApplePreset == choice.id
                            Button {
                                model.previewApplePreset(choice.id)
                            } label: {
                                Text(choice.name)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isSelected ? .accentColor : .secondary.opacity(0.25))
                        }
                    }

                    Divider()

                    sectionTitle("Fish Audio 音色", icon: "fish")
                    if model.hasFishKey {
                        if !FishVoiceLibrary.all.isEmpty {
                            Button {
                                model.autoPickFishVoice()
                            } label: {
                                Label("按性格自动推荐", systemImage: "wand.and.stars")
                                    .font(.footnote)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(FishVoiceLibrary.all) { v in
                                    let isSelected = model.fishVoiceID == v.id
                                    Button {
                                        model.fishVoiceID = isSelected ? "" : v.id
                                    } label: {
                                        Text(v.name)
                                            .font(.footnote)
                                            .lineLimit(1)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(isSelected ? .accentColor : .secondary.opacity(0.25))
                                }
                            }
                        } else {
                            Text("声库为空 —— 在 FishVoiceLibrary.json 里添加音色后,这里会出现可选列表和自动推荐")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        TextField("或直接填 Fish reference ID", text: $model.fishVoiceID)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                        Text("留空 = 用 Fish 默认音色;聊天时 Fish 优先,无网络回退 Apple")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("配置 Fish Audio API Key 后可选择云端音色")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .voice:
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Apple 声线", icon: "speaker.wave.2")
                    Text("点按即试听;不选则用系统默认声线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(AppleVoiceProfile.customChoices, id: \.id) { choice in
                            let isSelected = model.selectedApplePreset == choice.id
                            Button {
                                model.previewApplePreset(choice.id)
                            } label: {
                                Text(choice.name)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isSelected ? .accentColor : .secondary.opacity(0.25))
                        }
                    }

                    Divider()

                    sectionTitle("Fish Audio 音色", icon: "fish")
                    if model.hasFishKey {
                        if !FishVoiceLibrary.all.isEmpty {
                            Button {
                                model.autoPickFishVoice()
                            } label: {
                                Label("按性格自动推荐", systemImage: "wand.and.stars")
                                    .font(.footnote)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(FishVoiceLibrary.all) { v in
                                    let isSelected = model.fishVoiceID == v.id
                                    Button {
                                        model.fishVoiceID = isSelected ? "" : v.id
                                    } label: {
                                        Text(v.name)
                                            .font(.footnote)
                                            .lineLimit(1)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(isSelected ? .accentColor : .secondary.opacity(0.25))
                                }
                            }
                        } else {
                            Text("声库为空 —— 在 FishVoiceLibrary.json 里添加音色后,这里会出现可选列表和自动推荐")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        TextField("或直接填 Fish reference ID", text: $model.fishVoiceID)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                        Text("留空 = 用 Fish 默认音色;聊天时 Fish 优先,无网络回退 Apple")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("配置 Fish Audio API Key 后可选择云端音色")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

            case .color:
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("发色", icon: "paintpalette")
                    HStack(spacing: 10) {
                        ForEach(AvatarStudioModel.hairPresets, id: \.0) { name, c in
                            Button {
                                model.setHairColor(c)
                            } label: {
                                Circle()
                                    .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                        ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: pickedColor) { _, newColor in
                                model.setHairColor(newColor)
                            }
                    }
                    Text("提示:染色与贴图是乘法,浅发色部件的染色效果最好")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .fontWeight(.semibold)
    }

    @ViewBuilder
    private func partSection(title: String, icon: String,
                             groups: [AvatarManifest.PartGroup],
                             selected: String?) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(title, icon: icon)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        let isSelected = selected == group.id
                        Button {
                            model.selectPart(group.id)
                        } label: {
                            // 短名(分区标题已标类别),字号收一档,不再截断成"…"
                            Text(AvatarStudioModel.partShortLabel(group.id))
                                .font(.footnote)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isSelected ? .accentColor : .secondary.opacity(0.25))
                    }
                }
            }
        }
    }
}
