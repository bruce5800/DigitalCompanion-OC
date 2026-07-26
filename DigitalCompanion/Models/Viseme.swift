//
//  Viseme.swift
//  DigitalCompanion
//
//  音素（Viseme）定义和文本到 Viseme 时间线的映射
//

import Foundation

/// 日文五元音 + 闭嘴，对应模型的 blend shape
enum Viseme: String, CaseIterable {
    case a       // あ - 张嘴
    case i       // い - 咧嘴
    case u       // う - 嘟嘴
    case e       // え - 半开
    case o       // お - 圆嘴
    case closed  // ん/无声 - 闭嘴（不驱动任何 shape）

    /// 对应的 USD blend shape 名称（由 02_glb_to_usdc.py 从日文元音重命名而来）
    var shapeName: String {
        switch self {
        case .a: return "viseme_a"  // あ
        case .i: return "viseme_i"  // い
        case .u: return "viseme_u"  // う
        case .e: return "viseme_e"  // え
        case .o: return "viseme_o"  // お
        case .closed: return ""
        }
    }

    /// 所有会驱动口型的 viseme（不含 closed）
    static var vowels: [Viseme] {
        return [.a, .i, .u, .e, .o]
    }
}

/// 时间线上的一个 viseme 片段
struct VisemeSegment {
    let viseme: Viseme
    let startTime: TimeInterval  // 相对于说话开始的时间
    let duration: TimeInterval
    var endTime: TimeInterval { startTime + duration }
}

/// 文本 → Viseme 时间线的映射器
enum VisemeMapper {

    /// 把文本转成拼音（无声调），用于后续提取韵母
    /// 例："你好" -> "ni hao"
    static func toPinyin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        // Mandarin → 带音调的拉丁拼音
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        // 去掉音调符号
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// 把拼音音节的主元音（韵母）映射到 viseme
    /// 规则：取韵母的主元音字母。若找不到返回 nil（静默/辅音）
    static func visemeForSyllable(_ syllable: String) -> Viseme? {
        guard !syllable.isEmpty else { return nil }

        let s = syllable.lowercased()

        // 按较长韵母优先匹配
        // ang/eng/ing/ong
        if s.hasSuffix("ang") { return .a }
        if s.hasSuffix("eng") { return .e }
        if s.hasSuffix("ing") { return .i }
        if s.hasSuffix("ong") { return .o }
        // an/en/in/un
        if s.hasSuffix("an") { return .a }
        if s.hasSuffix("en") { return .e }
        if s.hasSuffix("in") { return .i }
        if s.hasSuffix("un") { return .u }
        // 复合韵母 ai/ao/ei/ou/ui/iu/ie/ue/uo/ia
        if s.hasSuffix("ai") { return .a }
        if s.hasSuffix("ao") { return .a }
        if s.hasSuffix("ei") { return .e }
        if s.hasSuffix("ou") { return .o }
        if s.hasSuffix("ui") { return .u }
        if s.hasSuffix("iu") { return .i }
        if s.hasSuffix("ie") { return .e }
        if s.hasSuffix("ue") { return .e }
        if s.hasSuffix("uo") { return .o }
        if s.hasSuffix("ia") { return .a }

        // 单元音
        if s.hasSuffix("a") { return .a }
        if s.hasSuffix("o") { return .o }
        if s.hasSuffix("e") { return .e }
        if s.hasSuffix("i") { return .i }
        if s.hasSuffix("u") { return .u }
        if s.hasSuffix("v") { return .u }  // ü 转成 v

        // 英文字母元音
        let vowelMap: [Character: Viseme] = ["a": .a, "e": .e, "i": .i, "o": .o, "u": .u]
        for ch in s.reversed() {
            if let v = vowelMap[ch] { return v }
        }

        return nil
    }

    /// 从文本生成 viseme 时间线
    /// - Parameters:
    ///   - text: 要说的文本（中文 + 英文混合）
    ///   - totalDuration: TTS 音频总时长（秒）。若为 nil，按每字 180ms 估算
    /// - Returns: 按时间排序的 viseme 片段数组
    static func schedule(from text: String, totalDuration: TimeInterval? = nil) -> [VisemeSegment] {
        // 1. 切分：把文本按 "字" 切开（中文每个字一个音节；英文空格切分为单词，简单按音节估算）
        let syllables = extractSyllables(from: text)
        guard !syllables.isEmpty else { return [] }

        // 2. 每个音节 → viseme
        let visemes: [Viseme] = syllables.map { visemeForSyllable($0) ?? .a }

        // 3. 按总时长均分
        let perDuration: TimeInterval
        if let total = totalDuration {
            perDuration = total / Double(visemes.count)
        } else {
            perDuration = 0.18  // 每字 180ms 默认估算
        }

        // 4. 生成时间线
        var segments: [VisemeSegment] = []
        for (i, v) in visemes.enumerated() {
            segments.append(VisemeSegment(
                viseme: v,
                startTime: Double(i) * perDuration,
                duration: perDuration
            ))
        }
        return segments
    }

    /// 从文本中提取音节列表
    /// 中文：每个字一个音节（转拼音后用空格分隔）
    /// 英文：按空格切词，每个词算一个音节（简化处理）
    private static func extractSyllables(from text: String) -> [String] {
        var syllables: [String] = []

        for ch in text {
            if ch.isWhitespace || ch.isPunctuation { continue }

            if ch.isASCII {
                // 英文字母：连续累加为一个单词
                if let last = syllables.last, last.unicodeScalars.first.map({ $0.isASCII }) ?? false {
                    syllables[syllables.count - 1] = last + String(ch)
                } else {
                    syllables.append(String(ch))
                }
            } else {
                // 非 ASCII（中文等）：每个字独立，转拼音
                let pinyin = toPinyin(String(ch)).trimmingCharacters(in: .whitespaces)
                if !pinyin.isEmpty {
                    syllables.append(pinyin)
                } else {
                    syllables.append(String(ch))
                }
            }
        }

        return syllables
    }
}
