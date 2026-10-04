import Foundation
import CryptoKit
import SQLite3

nonisolated struct AnkiWord: Sendable {
    var word: String
    var meaning: String
    var context: String
    var subject: String
    var subjectID: UUID
}

nonisolated enum AnkiExporter {
    /// Anki's legacy package format: a schema-11 SQLite collection and a JSON media map in ZIP.
    /// Schema reference: https://github.com/ankitects/anki/blob/main/rslib/src/storage/schema11.sql
    @concurrent static func export(words: [AnkiWord], destination: URL, deckName: String) async throws {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = folder.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeCollection(words: words, at: contents.appendingPathComponent("collection.anki2"), deckName: deckName)
        try Data("{}".utf8).write(to: contents.appendingPathComponent("media"))
        let archive = folder.appendingPathComponent("export.apkg")
        let process = await GUIProcess(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                       arguments: ["-c", "-k", "--norsrc", contents.path, archive.path])
        let result = try await process.run(timeout: 60)
        guard result.status == 0 else { throw AnkiExportError("Anki 파일을 묶을 수 없습니다: \(result.errorOutput)") }
        try Task.checkCancellation()
        let manager = FileManager.default
        let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: replacement) }
        let staged = replacement.appendingPathComponent("export.apkg")
        try manager.copyItem(at: archive, to: staged)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw AnkiExportError("Anki 파일을 저장할 경로가 일반 파일이 아닙니다.")
            }
            _ = try manager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else { try manager.moveItem(at: staged, to: destination) }
    }

    private static func writeCollection(words: [AnkiWord], at url: URL, deckName: String) throws {
        let db = try AnkiDatabase(url: url)
        try db.execute(schema)
        try db.execute("BEGIN TRANSACTION")
        let now = Date().timeIntervalSince1970
        let seconds = Int64(now)
        let milliseconds = Int64(now * 1000)
        let modelID: Int64 = 2_026_100_300
        let title = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "영한번역" : title
        let deckID = SHA256.hash(data: Data(name.utf8)).prefix(6).reduce(Int64(0)) { ($0 << 8) | Int64($1) } + 2
        let fields: [[String: Any]] = ["Word", "Meaning", "Context", "Subject"].enumerated().map { index, field in
            ["name": field, "ord": index, "font": "Arial", "size": 20, "rtl": false, "sticky": false, "media": []]
        }
        let model: [String: Any] = [
            "id": String(modelID), "name": "영한번역 단어", "type": 0, "mod": seconds, "usn": -1,
            "sortf": 0, "did": deckID, "flds": fields, "tags": [], "vers": [], "latexsvg": false,
            "latexPre": "", "latexPost": "", "req": [[0, "all", [0]]],
            "css": ".card{font-family:-apple-system,Arial,sans-serif;text-align:center;line-height:1.5;padding:24px}.word{font-size:34px}.subject{font-size:13px;color:#888;margin-top:12px}.meaning{font-size:26px;color:#b33}.context{font-size:15px;margin-top:16px;white-space:normal}",
            "tmpls": [["name": "Word → Meaning", "ord": 0, "did": NSNull(), "bafmt": "", "bqfmt": "", "bfont": "", "bsize": 0,
                       "qfmt": "<div class=\"word\">{{Word}}</div><div class=\"subject\">{{Subject}}</div>",
                       "afmt": "{{FrontSide}}<hr id=\"answer\"><div class=\"meaning\">{{Meaning}}</div><div class=\"context\">{{Context}}</div>"]]
        ]
        func deck(_ id: Int64, _ name: String) -> [String: Any] {
            ["id": id, "name": name, "mod": seconds, "usn": -1, "desc": "", "dyn": 0, "conf": 1,
             "collapsed": false, "extendNew": 0, "extendRev": 0,
             "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0]]
        }
        let configuration: [String: Any] = ["curDeck": deckID, "activeDecks": [deckID], "curModel": String(modelID),
                                             "nextPos": words.count + 1, "sortType": "noteFld", "sortBackwards": false]
        try db.execute("INSERT INTO col VALUES(1, ?, ?, ?, 11, 0, -1, 0, ?, ?, ?, '{}', '{}')",
                       [String(seconds), String(milliseconds), String(milliseconds), try json(configuration),
                        try json([String(modelID): model]), try json(["1": deck(1, "Default"), String(deckID): deck(deckID, name)])])
        var seen = Set<String>()
        var ordinal: Int64 = 0
        for entry in words {
            try Task.checkCancellation()
            let word = clean(entry.word).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let subject = clean(entry.subject)
            let identity = entry.subjectID.uuidString + "\u{1f}" + word.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(identity).inserted else { continue }
            ordinal += 1
            let noteID = milliseconds + ordinal
            let guid = SHA256.hash(data: Data(identity.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            let checksum = Insecure.SHA1.hash(data: Data(word.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let fields = [word, entry.meaning, entry.context, subject].map { html(clean($0)) }.joined(separator: "\u{1f}")
            try db.execute("INSERT INTO notes VALUES(?, ?, ?, ?, -1, '', ?, ?, ?, 0, '')",
                           [String(noteID), guid, String(modelID), String(seconds), fields, word, String(checksum)])
            try db.execute("INSERT INTO cards VALUES(?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 2500, 0, 0, 0, 0, 0, 0, '')",
                           [String(noteID), String(noteID), String(deckID), String(seconds), String(ordinal)])
        }
        guard ordinal > 0 else { throw AnkiExportError("내보낼 단어가 없습니다.") }
        try db.execute("COMMIT")
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: "\u{fffd}")
            .replacingOccurrences(of: "\u{1f}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static let schema = """
    CREATE TABLE col(id INTEGER PRIMARY KEY, crt INTEGER NOT NULL, mod INTEGER NOT NULL, scm INTEGER NOT NULL, ver INTEGER NOT NULL, dty INTEGER NOT NULL, usn INTEGER NOT NULL, ls INTEGER NOT NULL, conf TEXT NOT NULL, models TEXT NOT NULL, decks TEXT NOT NULL, dconf TEXT NOT NULL, tags TEXT NOT NULL);
    CREATE TABLE notes(id INTEGER PRIMARY KEY, guid TEXT NOT NULL, mid INTEGER NOT NULL, mod INTEGER NOT NULL, usn INTEGER NOT NULL, tags TEXT NOT NULL, flds TEXT NOT NULL, sfld INTEGER NOT NULL, csum INTEGER NOT NULL, flags INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE TABLE cards(id INTEGER PRIMARY KEY, nid INTEGER NOT NULL, did INTEGER NOT NULL, ord INTEGER NOT NULL, mod INTEGER NOT NULL, usn INTEGER NOT NULL, type INTEGER NOT NULL, queue INTEGER NOT NULL, due INTEGER NOT NULL, ivl INTEGER NOT NULL, factor INTEGER NOT NULL, reps INTEGER NOT NULL, lapses INTEGER NOT NULL, left INTEGER NOT NULL, odue INTEGER NOT NULL, odid INTEGER NOT NULL, flags INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE TABLE revlog(id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL, ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL, factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL);
    CREATE TABLE graves(usn INTEGER NOT NULL, oid INTEGER NOT NULL, type INTEGER NOT NULL);
    CREATE INDEX ix_notes_usn ON notes(usn);
    CREATE INDEX ix_cards_usn ON cards(usn);
    CREATE INDEX ix_revlog_usn ON revlog(usn);
    CREATE INDEX ix_cards_nid ON cards(nid);
    CREATE INDEX ix_cards_sched ON cards(did,queue,due);
    CREATE INDEX ix_revlog_cid ON revlog(cid);
    CREATE INDEX ix_notes_csum ON notes(csum);
    """
}

nonisolated private struct AnkiExportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated private final class AnkiDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw AnkiExportError("Anki 데이터 파일을 만들 수 없습니다.")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ arguments: [String] = []) throws {
        if arguments.isEmpty {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
            return
        }
        let statement: OpaquePointer
        if let prepared = statements[sql] { statement = prepared }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statements[sql] = prepared; statement = prepared
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient) == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func failure() -> AnkiExportError {
        AnkiExportError("Anki 데이터 저장 실패: \(String(cString: sqlite3_errmsg(handle)))")
    }
}
