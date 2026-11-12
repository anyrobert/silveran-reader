import Foundation

/// Chapter names for each file of a book, taken from the EPUB's table of contents. A file
/// with no table-of-contents entry belongs to the chapter of the nearest file before it.
public struct ObsidianBookOutline: Sendable {
    let sections: [SectionInfo]
    let chapterBySection: [String?]

    public init(sectionIDs: [String], toc: [(label: String, sectionIndex: Int)]) {
        sections = sectionIDs.enumerated().map { index, id in
            SectionInfo(index: index, id: id, label: nil, level: nil, mediaOverlay: [])
        }
        var labelsBySection: [Int: [String]] = [:]
        for entry in toc {
            let label = entry.label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !label.isEmpty else { continue }
            labelsBySection[entry.sectionIndex, default: []].append(label)
        }
        var chapters: [String?] = []
        var current: String?
        for index in sectionIDs.indices {
            if let labels = labelsBySection[index] {
                chapters.append(labels.first)
                current = labels.last
            } else {
                chapters.append(current)
            }
        }
        chapterBySection = chapters
    }

    public static func load(epubURL: URL) -> ObsidianBookOutline? {
        guard let parsed = try? SMILParser.parseEPUB(at: epubURL) else { return nil }
        return ObsidianBookOutline(
            sectionIDs: parsed.sections.map(\.id),
            toc: parsed.tocEntries.map { ($0.label, $0.sectionIndex) },
        )
    }

    public func chapter(forHref href: String) -> String? {
        let path = href.components(separatedBy: "#").first ?? href
        guard let index = findSectionIndex(for: path, in: sections) else { return nil }
        return chapterBySection[index]
    }

    /// Integer steps of an EPUB CFI (parent path plus range start), which sort in reading
    /// order. Returns nil when the value is not a CFI.
    public static func cfiSortKey(_ cfi: String) -> [Int]? {
        guard let open = cfi.range(of: "epubcfi("), let close = cfi.lastIndex(of: ")"),
            open.upperBound <= close
        else { return nil }

        var steps: [Int] = []
        var digits = ""
        var inAssertion = false
        var rangeParts = 0
        func flush() {
            if let value = Int(digits) { steps.append(value) }
            digits = ""
        }
        for character in cfi[open.upperBound..<close] {
            if inAssertion {
                if character == "]" { inAssertion = false }
                continue
            }
            if character == "[" {
                flush()
                inAssertion = true
            } else if character.isASCII && character.isNumber {
                digits.append(character)
            } else {
                flush()
                if character == "," {
                    rangeParts += 1
                    if rangeParts == 2 { break }
                } else if character == "~" || character == "@" {
                    break
                }
            }
        }
        flush()
        return steps.isEmpty ? nil : steps
    }

    static func cfiSortKey(for highlight: Highlight) -> [Int]? {
        let locations = highlight.locator.locations
        for candidate in (locations?.fragments ?? []) + [locations?.partialCfi].compactMap({ $0 }) {
            if let key = cfiSortKey(candidate) { return key }
        }
        return nil
    }
}
