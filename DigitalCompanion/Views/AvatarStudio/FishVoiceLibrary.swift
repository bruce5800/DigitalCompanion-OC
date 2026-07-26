//
//  FishVoiceLibrary.swift
//  DigitalCompanion
//
//  Fish Audio 音色库:app 内维护的一份 JSON(FishVoiceLibrary.json),
//  每条 = 一个 Fish reference ID + 元信息,捏人间"声线"页据此
//  自动推荐 / 手选。库为空时 UI 退化为手填 ID。
//
//  FishVoiceLibrary.json 格式(直接编辑该文件补充音色):
//  [
//    {"id": "<fish reference id>", "name": "清甜少女", "gender": "f",
//     "tags": ["温柔", "元气"]},
//    {"id": "...", "name": "低音大叔", "gender": "m", "tags": ["沉稳"]}
//  ]
//  gender: "f" / "m" / 缺省(不限);tags 用于按性格关键词自动推荐。
//

import Foundation

struct FishVoice: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    var gender: String?
    var tags: [String]?
}

enum FishVoiceLibrary {

    static let all: [FishVoice] = {
        guard let url = Bundle.main.url(forResource: "FishVoiceLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let voices = try? JSONDecoder().decode([FishVoice].self, from: data) else {
            return []
        }
        return voices
    }()

    /// 自动推荐:性别匹配底模(库条目没标性别的不限)+ 性格文本命中 tags 越多分越高
    static func autoPick(base: AvatarBase, personality: String) -> FishVoice? {
        let wantGender = base == .female ? "f" : "m"
        let candidates = all.filter { $0.gender == nil || $0.gender == wantGender }
        guard !candidates.isEmpty else { return nil }
        func score(_ v: FishVoice) -> Int {
            (v.tags ?? []).reduce(0) { $0 + (personality.contains($1) ? 1 : 0) }
        }
        return candidates.max { score($0) < score($1) }
    }
}
