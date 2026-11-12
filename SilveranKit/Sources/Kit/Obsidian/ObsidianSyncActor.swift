import Foundation

public struct ObsidianSyncSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var vaultPath: String?
    public var vaultBookmark: Data?
    public var notesFolder: String
    public var templatePath: String

    public init(
        enabled: Bool = false,
        vaultPath: String? = nil,
        vaultBookmark: Data? = nil,
        notesFolder: String = "Sources",
        templatePath: String = "Templates/Book.md",
    ) {
        self.enabled = enabled
        self.vaultPath = vaultPath
        self.vaultBookmark = vaultBookmark
        self.notesFolder = notesFolder
        self.templatePath = templatePath
    }
}

public struct ObsidianSyncStatus: Sendable, Equatable {
    public let date: Date
    public let message: String
    public let isError: Bool

    public init(date: Date, message: String, isError: Bool) {
        self.date = date
        self.message = message
        self.isError = isError
    }
}

struct ObsidianBookLink: Codable, Sendable, Equatable {
    var notePath: String
    var startedAt: Date?
}

struct ObsidianSyncState: Codable, Sendable {
    var settings = ObsidianSyncSettings()
    var books: [String: ObsidianBookLink] = [:]
}

/// Mirrors each book's highlights into a note in the user's Obsidian vault. The Mac
/// settings screen turns it on; on other platforms no vault is set, so it does nothing.
public actor ObsidianSyncActor {
    public static let shared = ObsidianSyncActor()

    private let stateURL: URL?
    private var state: ObsidianSyncState?
    private var lastStatus: ObsidianSyncStatus?
    private var observers: [UUID: @Sendable (ObsidianSyncStatus?) -> Void] = [:]
    private let vaultOverride: URL?
    private var outlines: [BookID: ObsidianBookOutline] = [:]

    init(stateURL: URL? = nil, vaultOverride: URL? = nil) {
        self.stateURL = stateURL
        self.vaultOverride = vaultOverride
    }

    // MARK: Settings

    public func settings() -> ObsidianSyncSettings {
        loadedState().settings
    }

    public func status() -> ObsidianSyncStatus? {
        lastStatus
    }

    public func updateSettings(_ settings: ObsidianSyncSettings) {
        var current = loadedState()
        let wasReady = current.settings.enabled && current.settings.vaultPath != nil
        current.settings = settings
        state = current
        persist()
        let isReady = settings.enabled && settings.vaultPath != nil
        if isReady && !wasReady {
            Task { await self.syncAllHighlights() }
        }
    }

    @discardableResult
    public func addObserver(_ callback: @escaping @Sendable (ObsidianSyncStatus?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    // MARK: Events

    public func bookStarted(_ book: ObsidianBookInfo, now: Date = Date()) async {
        guard isActive else { return }
        let key = book.bookID.description
        let link = loadedState().books[key]
        guard link?.startedAt == nil else { return }

        let highlights = await BookmarkActor.shared.getHighlights(bookID: book.bookID)
        let outline = await outline(for: book.bookID)
        perform(
            book: book,
            startedOn: now,
            highlights: highlights,
            outline: outline,
            createIfMissing: true,
        )
    }

    public func highlightsChanged(bookID: BookID, highlights: [Highlight]) async {
        guard isActive else { return }
        guard let book = await bookInfo(for: bookID) else {
            debugLog("[ObsidianSync] no library metadata for \(bookID), skipping")
            return
        }
        let hasColored = highlights.contains { !$0.isBookmark }
        let outline = hasColored ? await outline(for: bookID) : nil
        perform(
            book: book,
            startedOn: nil,
            highlights: highlights,
            outline: outline,
            createIfMissing: hasColored,
        )
    }

    @discardableResult
    public func syncAllHighlights() async -> Int {
        guard isActive else { return 0 }
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
        var notes = 0
        for metadata in snapshot.books {
            let highlights = await BookmarkActor.shared.getHighlights(bookID: metadata.id)
            guard highlights.contains(where: { !$0.isBookmark }) else { continue }
            let outline = await outline(for: metadata.id)
            let ok = perform(
                book: ObsidianBookInfo(metadata: metadata),
                startedOn: nil,
                highlights: highlights,
                outline: outline,
                createIfMissing: true,
                quiet: true,
            )
            if ok { notes += 1 }
        }
        report("Synced highlights of \(notes) book\(notes == 1 ? "" : "s").", isError: false)
        return notes
    }

    // MARK: Internals

    private var isActive: Bool {
        let settings = loadedState().settings
        return settings.enabled && (settings.vaultPath != nil || vaultOverride != nil)
    }

    @discardableResult
    private func perform(
        book: ObsidianBookInfo,
        startedOn: Date?,
        highlights: [Highlight]?,
        outline: ObsidianBookOutline?,
        createIfMissing: Bool,
        quiet: Bool = false,
    ) -> Bool {
        var current = loadedState()
        let key = book.bookID.description
        let link = current.books[key]

        let outcome: Result<ObsidianVault.Result?, Error> =
            withVault { vault in
                Result {
                    try vault.sync(
                        book: book,
                        rememberedPath: link?.notePath,
                        startedOn: startedOn,
                        highlights: highlights,
                        outline: outline,
                        createIfMissing: createIfMissing,
                    )
                }
            } ?? .failure(ObsidianSyncError.vaultUnavailable)

        switch outcome {
            case .success(let result):
                guard let result else { return true }
                var updated = link ?? ObsidianBookLink(notePath: result.notePath, startedAt: nil)
                updated.notePath = result.notePath
                if let startedOn, updated.startedAt == nil {
                    updated.startedAt = startedOn
                }
                if updated != link {
                    current.books[key] = updated
                    state = current
                    persist()
                }
                if result.changed && !quiet {
                    report(
                        "\(result.created ? "Created" : "Updated") \(result.notePath)",
                        isError: false,
                    )
                }
                return true
            case .failure(let error):
                debugLog("[ObsidianSync] \(book.title): \(error)")
                report("\(book.title): \(error.localizedDescription)", isError: true)
                return false
        }
    }

    private func withVault<T>(_ body: (ObsidianVault) -> T) -> T? {
        let settings = loadedState().settings
        if let vaultOverride {
            return body(vault(at: vaultOverride, settings: settings))
        }
        guard let url = resolveVaultURL(settings) else { return nil }
        #if canImport(Darwin)
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        #endif
        return body(vault(at: url, settings: settings))
    }

    private func vault(at url: URL, settings: ObsidianSyncSettings) -> ObsidianVault {
        ObsidianVault(
            rootURL: url,
            notesFolder: settings.notesFolder,
            templatePath: settings.templatePath,
        )
    }

    private func resolveVaultURL(_ settings: ObsidianSyncSettings) -> URL? {
        #if os(macOS)
        if let bookmark = settings.vaultBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            ) {
                return url
            }
        }
        #endif
        return settings.vaultPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func outline(for bookID: BookID) async -> ObsidianBookOutline? {
        if let cached = outlines[bookID] { return cached }
        for category in [LocalMediaCategory.ebook, .synced] {
            guard
                let media = await BookServiceActor.shared.resolveLocalMedia(
                    for: bookID,
                    category: category,
                ),
                let outline = ObsidianBookOutline.load(epubURL: media.url)
            else { continue }
            outlines[bookID] = outline
            return outline
        }
        debugLog("[ObsidianSync] no EPUB table of contents for \(bookID)")
        return nil
    }

    private func bookInfo(for bookID: BookID) async -> ObsidianBookInfo? {
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
        return snapshot.books.first { $0.id == bookID }.map(ObsidianBookInfo.init(metadata:))
    }

    private func report(_ message: String, isError: Bool) {
        let status = ObsidianSyncStatus(date: Date(), message: message, isError: isError)
        lastStatus = status
        for callback in observers.values {
            callback(status)
        }
    }

    private var resolvedStateURL: URL {
        stateURL
            ?? SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("ObsidianSync.json")
    }

    private func loadedState() -> ObsidianSyncState {
        if let state { return state }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded =
            (try? Data(contentsOf: resolvedStateURL))
            .flatMap { try? decoder.decode(ObsidianSyncState.self, from: $0) }
            ?? ObsidianSyncState()
        state = loaded
        return loaded
    }

    private func persist() {
        guard let state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let url = resolvedStateURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            debugLog("[ObsidianSync] failed to save state: \(error)")
        }
    }
}

enum ObsidianSyncError: Error, LocalizedError {
    case vaultUnavailable

    var errorDescription: String? {
        "Cannot open the Obsidian vault folder. Choose it again in Settings."
    }
}
