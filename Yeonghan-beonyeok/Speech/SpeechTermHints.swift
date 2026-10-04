import Foundation
import PDFKit

nonisolated enum SpeechTermHints {
    static func extract(from url: URL, pageIndex: Int) async -> [String] {
        let task = Task.detached(priority: .utility) {
            autoreleasepool {
                guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return [String]() }
                let current = min(max(pageIndex, 0), pdf.pageCount - 1)
                var pages: [String] = []
                var characters = 0
                // Keep the current page even in large documents, and bound PDF text work before recording begins.
                for index in [current] + Array(0..<min(pdf.pageCount, 400)).filter({ $0 != current }) {
                    if Task.isCancelled || characters >= 1_000_000 { break }
                    let text = String((pdf.page(at: index)?.string ?? "").prefix(min(80_000, 1_000_000 - characters)))
                    pages.append(text)
                    characters += text.count
                }
                guard !Task.isCancelled else { return [String]() }
                return candidates(page: pages.first ?? "", document: pages.joined(separator: "\n"))
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func candidates(page: String, document: String) -> [String] {
        let stop: Set<String> = ["this", "that", "with", "from", "then", "than", "into", "when", "which", "where", "there", "these", "those", "have", "will", "each", "also", "only", "some", "such", "more", "most", "other", "their", "about", "between", "after", "before", "while", "because", "what", "does", "using", "used"]
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*"#)
        func ranked(_ text: String) -> [String] {
            var terms: [String: (text: String, count: Int, order: Int)] = [:]
            let source = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let match else { return }
                let word = source.substring(with: match.range), key = word.lowercased()
                guard !stop.contains(key), word.count <= 64,
                      word.count >= 4 || (word.count >= 2 && word == word.uppercased()) else { return }
                if var term = terms[key] { term.count += 1; terms[key] = term }
                else { terms[key] = (word, 1, terms.count) }
            }
            return terms.values.sorted { $0.count == $1.count ? $0.order < $1.order : $0.count > $1.count }.map(\.text)
        }
        var seen: Set<String> = []
        return Array((Array(ranked(page).prefix(20)) + ranked(document)).filter { seen.insert($0.lowercased()).inserted }.prefix(60))
    }

}
