import Foundation
import NaturalLanguage

nonisolated enum TextSelectionClassifier {
    /// Ambiguous short selections stay expressions; the reader also offers an explicit override.
    static func isSentence(_ selection: String) -> Bool {
        let text = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»()[]{}"))
        guard text.contains(where: \.isLetter) else { return false }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let words = tagger.tags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                                options: [.omitWhitespace, .omitPunctuation]).map {
            (text: String(text[$0.1]).lowercased(), tag: $0.0, range: $0.1)
        }
        guard !words.isEmpty else { return false }

        // A period attached to one word, an abbreviation, or a version is not enough by itself.
        if let last = text.last, "!?！？".contains(last) { return true }
        if let last = text.last, ".。".contains(last), words.count > 1,
           words.last!.text.allSatisfy(\.isLetter) { return true }

        // NaturalLanguage does not provide Korean lexical classes; use explicit final endings.
        if let last = text.split(separator: " ").last,
           last.range(of: #"[가-힣](?:니다|니까|나요|까요|어요|아요|해요|돼요|예요|이에요|세요|네요|군요|이다|한다|된다|했다|됐다|였다|었다|았다|있다|없다|인가|는가|합시다)$"#,
                      options: .regularExpression) != nil { return true }

        if tagger.dominantLanguage == .english {
            let auxiliaries = ["am", "is", "are", "was", "were", "be", "been", "can", "could", "may", "might", "must", "shall", "should", "will", "would"]
            func isInflected(_ index: Int) -> Bool {
                guard let lemma = tagger.tag(at: words[index].range.lowerBound, unit: .word, scheme: .lemma).0 else { return false }
                return lemma.rawValue.lowercased() != words[index].text
            }
            for index in words.indices where words[index].tag == .verb && index > 0 {
                let verb = words[index].text
                // Infinitives, gerunds, and attributive participles commonly belong to terms.
                guard words[index - 1].text != "to", !verb.hasSuffix("ing") else { continue }
                let subject = words[..<index]
                guard subject.first?.tag != .preposition, subject.first?.tag != .conjunction else { continue }
                let hasSubject = subject.contains { $0.tag == .noun || $0.tag == .pronoun }
                    || ["this", "that", "these", "those"].contains(subject.first?.text ?? "")
                guard hasSubject else { continue }
                // Bare noun + base-form verb often names an operation, rather than forming a clause.
                let explicitSubject = subject.first?.tag == .pronoun || subject.first?.tag == .determiner
                let inflectedVerb = (verb.hasSuffix("s") || verb.hasSuffix("ed")) && isInflected(index)
                let pluralSubject = subject.indices.contains { words[$0].tag == .noun && words[$0].text.hasSuffix("s") && isInflected($0) }
                guard explicitSubject || auxiliaries.contains(verb) || inflectedVerb || pluralSubject else { continue }
                if verb.hasSuffix("ed"), index + 1 < words.count, subject.first?.tag != .pronoun { continue }
                // A dangling auxiliary ("memory is", "we should") is still a fragment.
                if auxiliaries.contains(verb),
                   index == words.count - 1 { continue }
                return true
            }
        }

        // Long selections are passages even when language-specific tagging is unavailable.
        return words.count >= 18
    }

}
