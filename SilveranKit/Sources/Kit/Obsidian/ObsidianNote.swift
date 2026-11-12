import Foundation

public struct ObsidianBookInfo: Sendable, Hashable {
    public let bookID: BookID
    public let title: String
    public let subtitle: String?
    public let authors: [String]

    public init(bookID: BookID, title: String, subtitle: String?, authors: [String]) {
        self.bookID = bookID
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
    }

    public init(metadata: BookMetadata) {
        self.init(
            bookID: metadata.id,
            title: metadata.title,
            subtitle: metadata.subtitle,
            authors: (metadata.authors ?? []).compactMap { creator in
                let name = creator.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty ? nil : name
            },
        )
    }
}

public enum ObsidianNote {
    public static let sectionHeading = "## Destaques"
    public static let unknownChapterTitle = "Sem capítulo"
    static let sectionStartPrefix = "<!-- silveran:highlights"
    static let sectionEnd = "<!-- silveran:end -->"

    public static let defaultTemplate = """
        ---
        type: book
        tags: []
        author:
        created: {{date:YYYY-MM-DD}}
        ---

        """

    static func sectionStart(bookUUID: String) -> String {
        "\(sectionStartPrefix) book=\(bookUUID) -->"
    }

    public static func blockID(for id: UUID) -> String {
        let hex = id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "h-" + hex.prefix(6)
    }

    public static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(format: "yyyy-MM-dd", timeZone: timeZone).string(from: date)
    }

    public static func quoteDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(format: "dd/MM/yyyy", timeZone: timeZone).string(from: date)
    }

    // MARK: Highlights section

    public static func renderHighlightsSection(
        bookUUID: String,
        highlights: [Highlight],
        outline: ObsidianBookOutline? = nil,
        timeZone: TimeZone = .current,
    ) -> String? {
        let colored = highlights.filter { !$0.isBookmark }
        guard !colored.isEmpty else { return nil }

        let keyed = colored.map { ($0, ObsidianBookOutline.cfiSortKey(for: $0)) }
        let ordered = keyed.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
                case (let left?, let right?) where left != right:
                    return left.lexicographicallyPrecedes(right)
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.0.createdAt < rhs.0.createdAt
            }
        }.map(\.0)

        var chapterOrder: [String] = []
        var byChapter: [String: [Highlight]] = [:]
        for highlight in ordered {
            let chapter = chapterTitle(for: highlight, outline: outline)
            if byChapter[chapter] == nil {
                chapterOrder.append(chapter)
            }
            byChapter[chapter, default: []].append(highlight)
        }

        var lines: [String] = [sectionStart(bookUUID: bookUUID), sectionHeading, ""]
        for chapter in chapterOrder {
            lines.append("### \(chapter)")
            lines.append("")
            for highlight in byChapter[chapter] ?? [] {
                lines.append(contentsOf: quoteLines(highlight.text))
                lines.append("> — \(quoteDateString(highlight.createdAt, timeZone: timeZone))")
                lines.append("")
                lines.append("^\(blockID(for: highlight.id))")
                lines.append("")
                if let note = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !note.isEmpty
                {
                    lines.append(note)
                    lines.append("")
                }
            }
        }
        lines.append(sectionEnd)
        return lines.joined(separator: "\n")
    }

    static func chapterTitle(for highlight: Highlight, outline: ObsidianBookOutline?) -> String {
        let raw =
            outline?.chapter(forHref: highlight.locator.href) ?? highlight.locator.title ?? ""
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? unknownChapterTitle : collapsed
    }

    static func quoteLines(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .newlines).map { line in
            let content = line.trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? ">" : "> \(content)"
        }
    }

    public static func containsSection(_ note: String, bookUUID: String) -> Bool {
        note.contains(sectionStart(bookUUID: bookUUID))
    }

    /// Replaces the Silveran-owned section, appends it when absent, or removes it when
    /// `section` is nil. Returns nil when a start marker has no matching end marker,
    /// since rewriting would risk deleting text the user wrote after it.
    public static func upsertSection(in note: String, section: String?) -> String? {
        guard let startRange = note.range(of: sectionStartPrefix) else {
            guard let section else { return note }
            let base = note.trimmingTrailingWhitespace()
            return base.isEmpty ? section + "\n" : base + "\n\n" + section + "\n"
        }
        guard
            let endRange = note.range(of: sectionEnd, range: startRange.upperBound..<note.endIndex)
        else {
            return nil
        }

        let lineStart =
            note[..<startRange.lowerBound].lastIndex(of: "\n").map {
                note.index(after: $0)
            } ?? note.startIndex
        let before = String(note[..<lineStart])
        let after = String(note[endRange.upperBound...])

        if let section {
            return before + section + after
        }
        let trimmedBefore = before.trimmingTrailingWhitespace()
        let trimmedAfter = after.trimmingLeadingNewlines()
        if trimmedAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimmedBefore + "\n"
        }
        return trimmedBefore + "\n\n" + trimmedAfter
    }

    // MARK: Frontmatter

    struct Frontmatter {
        var lines: [String]
        let body: String
    }

    static func splitFrontmatter(_ note: String) -> Frontmatter? {
        let lines = note.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard
            let closing = lines.indices.dropFirst().first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces) == "---"
            })
        else { return nil }
        let yaml = Array(lines[1..<closing])
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return Frontmatter(lines: yaml, body: body)
    }

    static func joinFrontmatter(_ frontmatter: Frontmatter) -> String {
        (["---"] + frontmatter.lines + ["---"]).joined(separator: "\n") + "\n" + frontmatter.body
    }

    static func topLevelKeyIndex(_ key: String, in lines: [String]) -> Int? {
        lines.firstIndex { line in
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
            return line.hasPrefix("\(key):")
        }
    }

    static func listItemIndices(after keyIndex: Int, in lines: [String]) -> [Int] {
        var result: [Int] = []
        var index = keyIndex + 1
        while index < lines.count {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("- ") || stripped == "-" {
                result.append(index)
                index += 1
            } else if stripped.isEmpty {
                index += 1
            } else {
                break
            }
        }
        return result
    }

    static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
            let first = trimmed.first, let last = trimmed.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Adds `value` to the YAML list under `key`, creating the key or the frontmatter if
    /// needed. Leaves the note unchanged when the value is already listed.
    public static func addListValue(_ value: String, key: String, to note: String) -> String {
        guard var frontmatter = splitFrontmatter(note) else {
            return "---\n\(key):\n  - \(value)\n---\n" + note
        }
        var lines = frontmatter.lines

        guard let keyIndex = topLevelKeyIndex(key, in: lines) else {
            lines.append(contentsOf: ["\(key):", "  - \(value)"])
            frontmatter.lines = lines
            return joinFrontmatter(frontmatter)
        }

        let inline = lines[keyIndex].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty {
            let items = listItemIndices(after: keyIndex, in: lines)
            let existing = items.map { index in
                unquote(
                    String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                )
            }
            if existing.contains(value) { return note }
            let indent =
                items.last.map { String(lines[$0].prefix { $0 == " " || $0 == "\t" }) } ?? "  "
            let insertAt = (items.last ?? keyIndex) + 1
            lines.insert("\(indent)- \(value)", at: insertAt)
        } else {
            var existing: [String]
            if inline.hasPrefix("["), inline.hasSuffix("]") {
                existing = inline.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { unquote(String($0)) }
                    .filter { !$0.isEmpty }
            } else {
                existing = [unquote(inline)]
            }
            if existing.contains(value) { return note }
            existing.append(value)
            lines.replaceSubrange(
                keyIndex...keyIndex,
                with: ["\(key):"] + existing.map { "  - \($0)" },
            )
        }

        frontmatter.lines = lines
        return joinFrontmatter(frontmatter)
    }

    /// Sets `key` to the given YAML value lines only when the key is missing or empty.
    static func setValueIfEmpty(key: String, valueLines: [String], in note: String) -> String {
        guard !valueLines.isEmpty, var frontmatter = splitFrontmatter(note) else { return note }
        var lines = frontmatter.lines
        let rendered: [String] =
            valueLines.count == 1
            ? ["\(key): \(valueLines[0])"]
            : ["\(key):"] + valueLines.map { "  - \($0)" }

        if let keyIndex = topLevelKeyIndex(key, in: lines) {
            let inline = lines[keyIndex].dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
            let hasItems = !listItemIndices(after: keyIndex, in: lines).isEmpty
            guard inline.isEmpty || inline == "[]" || inline == "\"\"", !hasItems else {
                return note
            }
            lines.replaceSubrange(keyIndex...keyIndex, with: rendered)
        } else {
            lines.append(contentsOf: rendered)
        }
        frontmatter.lines = lines
        return joinFrontmatter(frontmatter)
    }

    // MARK: New notes

    public static func newNote(
        template: String,
        book: ObsidianBookInfo,
        now: Date,
        timeZone: TimeZone = .current,
    ) -> String {
        var note = fillTemplate(template, title: book.title, now: now, timeZone: timeZone)
        let authorValues = book.authors.map { "\"[[\(sanitizedLinkTarget($0))]]\"" }
        note = setValueIfEmpty(key: "author", valueLines: authorValues, in: note)
        return note
    }

    public static func fillTemplate(
        _ template: String,
        title: String,
        now: Date,
        timeZone: TimeZone = .current,
    ) -> String {
        var result = ""
        var remaining = Substring(template)
        while let open = remaining.range(of: "{{") {
            result += remaining[..<open.lowerBound]
            guard
                let close = remaining.range(of: "}}", range: open.upperBound..<remaining.endIndex)
            else {
                remaining = remaining[open.lowerBound...]
                break
            }
            let token = remaining[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            result +=
                replacement(for: token, title: title, now: now, timeZone: timeZone)
                ?? String(remaining[open.lowerBound..<close.upperBound])
            remaining = remaining[close.upperBound...]
        }
        result += remaining
        return result
    }

    static func replacement(for token: String, title: String, now: Date, timeZone: TimeZone)
        -> String?
    {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0].lowercased()
        let momentFormat = parts.count > 1 ? parts[1] : nil
        switch name {
            case "title":
                return title
            case "date":
                return formatter(
                    format: dateFormat(fromMoment: momentFormat ?? "YYYY-MM-DD"),
                    timeZone: timeZone,
                ).string(from: now)
            case "time":
                return formatter(
                    format: dateFormat(fromMoment: momentFormat ?? "HH:mm"),
                    timeZone: timeZone,
                ).string(from: now)
            default:
                return nil
        }
    }

    static func dateFormat(fromMoment moment: String) -> String {
        moment
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "YY", with: "yy")
            .replacingOccurrences(of: "DD", with: "dd")
            .replacingOccurrences(of: "D", with: "d")
    }

    static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: File names and matching

    public static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "*\"\\/<>:|?#^[]")
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    static func sanitizedLinkTarget(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "#^[]|")
        return name.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    public static func matchKey(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"),
        )
        let mapped = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return mapped.split(separator: " ").joined(separator: " ")
    }

    public static func matchKeys(for book: ObsidianBookInfo) -> [String] {
        var candidates = [book.title]
        if let subtitle = book.subtitle?.trimmingCharacters(in: .whitespaces), !subtitle.isEmpty {
            candidates.append("\(book.title) \(subtitle)")
        }
        for separator in [":", " - ", " — ", " – "] {
            if let range = book.title.range(of: separator) {
                candidates.append(String(book.title[..<range.lowerBound]))
            }
        }
        var seen = Set<String>()
        return candidates.map(matchKey).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension String {
    fileprivate func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    fileprivate func trimmingLeadingNewlines() -> String {
        String(drop { $0 == "\n" || $0 == "\r" })
    }
}
