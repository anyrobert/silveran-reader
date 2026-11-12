import Foundation

public enum ObsidianVaultError: Error, LocalizedError, Equatable {
    case unbalancedSection(notePath: String)

    public var errorDescription: String? {
        switch self {
            case .unbalancedSection(let notePath):
                "\(notePath) has a Silveran highlights start marker without an end marker. Fix the note in Obsidian; Silveran will not edit it until then."
        }
    }
}

/// Reads and writes book notes inside one Obsidian vault folder. Paths it returns are
/// relative to the vault root so they survive the vault being re-picked.
public struct ObsidianVault: Sendable {
    public let rootURL: URL
    public let notesFolder: String
    public let templatePath: String

    public init(rootURL: URL, notesFolder: String, templatePath: String) {
        self.rootURL = rootURL
        self.notesFolder = notesFolder
        self.templatePath = templatePath
    }

    var notesFolderURL: URL {
        let trimmed = notesFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty
            ? rootURL : rootURL.appendingPathComponent(trimmed, isDirectory: true)
    }

    func url(forRelativePath path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return full }
        return String(full.dropFirst(root.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url(forRelativePath: relativePath), encoding: .utf8)
    }

    func write(_ text: String, to relativePath: String) throws {
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    func template() -> String {
        let trimmed = templatePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ObsidianNote.defaultTemplate }
        let path = trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"
        return read(path) ?? ObsidianNote.defaultTemplate
    }

    func markdownFilesInNotesFolder() -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: notesFolderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    /// Finds the note for a book: the remembered path if it still exists, then a note that
    /// carries this book's section marker (renamed or moved in Obsidian), then a note whose
    /// file name matches the title. Returns nil when nothing matches.
    public func findNote(for book: ObsidianBookInfo, rememberedPath: String?) -> String? {
        if let rememberedPath,
            FileManager.default.fileExists(atPath: url(forRelativePath: rememberedPath).path)
        {
            return rememberedPath
        }

        let files = markdownFilesInNotesFolder()
        let marker = ObsidianNote.sectionStart(bookUUID: book.bookID.uuid)
        if let marked = files.first(where: {
            (try? String(contentsOf: $0, encoding: .utf8))?.contains(marker) == true
        }) {
            return relativePath(of: marked)
        }

        let keys = ObsidianNote.matchKeys(for: book)
        let byKey = Dictionary(
            files.map {
                (ObsidianNote.matchKey($0.deletingPathExtension().lastPathComponent), $0)
            },
            uniquingKeysWith: { first, _ in first },
        )
        for key in keys {
            if let match = byKey[key] {
                return relativePath(of: match)
            }
        }
        return nil
    }

    func newNotePath(for book: ObsidianBookInfo) -> String {
        let base = ObsidianNote.fileName(for: book.title)
        let folder = relativePath(of: notesFolderURL)
        func path(_ name: String) -> String {
            folder.isEmpty ? "\(name).md" : "\(folder)/\(name).md"
        }
        var candidate = path(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: url(forRelativePath: candidate).path) {
            candidate = path("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    public struct Result: Sendable, Equatable {
        public let notePath: String
        public let created: Bool
        public let changed: Bool
    }

    /// Finds or creates the book note, then applies the start date and the highlights
    /// section. `highlights == nil` leaves any existing section untouched.
    public func sync(
        book: ObsidianBookInfo,
        rememberedPath: String?,
        startedOn: Date?,
        highlights: [Highlight]?,
        outline: ObsidianBookOutline? = nil,
        createIfMissing: Bool,
        now: Date = Date(),
        timeZone: TimeZone = .current,
    ) throws -> Result? {
        var created = false
        let notePath: String
        let original: String

        if let found = findNote(for: book, rememberedPath: rememberedPath),
            let text = read(found)
        {
            notePath = found
            original = text
        } else {
            guard createIfMissing else { return nil }
            notePath = newNotePath(for: book)
            original = ObsidianNote.newNote(
                template: template(),
                book: book,
                now: now,
                timeZone: timeZone,
            )
            created = true
        }

        var note = original
        if let startedOn {
            note = ObsidianNote.addListValue(
                ObsidianNote.dayString(startedOn, timeZone: timeZone),
                key: "readings",
                to: note,
            )
        }
        if let highlights {
            let section = ObsidianNote.renderHighlightsSection(
                bookUUID: book.bookID.uuid,
                highlights: highlights,
                outline: outline,
                timeZone: timeZone,
            )
            guard let updated = ObsidianNote.upsertSection(in: note, section: section) else {
                throw ObsidianVaultError.unbalancedSection(notePath: notePath)
            }
            note = updated
        }

        let changed = created || note != original
        if changed {
            try write(note, to: notePath)
        }
        return Result(notePath: notePath, created: created, changed: changed)
    }
}
