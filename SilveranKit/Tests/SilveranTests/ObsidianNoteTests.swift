import Foundation
import Testing

@testable import SilveranKit

private let utc = TimeZone(identifier: "UTC")!
private let bookID = BookID(sourceID: "storyteller", uuid: "book-1")

private func day(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: value)!
}

private func highlight(
    _ text: String,
    chapter: String?,
    cfi: String?,
    href: String = "ch.xhtml",
    color: HighlightColor? = .yellow,
    note: String? = nil,
    created: String = "2026-11-11 10:00",
    id: UUID = UUID(),
) -> Highlight {
    Highlight(
        id: id,
        bookID: bookID,
        locator: BookLocator(
            href: href,
            type: "application/xhtml+xml",
            title: chapter,
            locations: BookLocator.Locations(
                fragments: cfi.map { [$0] },
                progression: nil,
                position: nil,
                totalProgression: nil,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        ),
        text: text,
        color: color,
        note: note,
        createdAt: day(created),
    )
}

private let book = ObsidianBookInfo(
    bookID: bookID,
    title: "As Seis Lições: Reflexões",
    subtitle: nil,
    authors: ["Ludwig von Mises"],
)

@Test func highlightsSectionGroupsByChapterInBookOrderAndSkipsBookmarks() throws {
    let firstID = UUID(uuidString: "3F9A2C00-0000-0000-0000-000000000000")!
    let highlights = [
        highlight(
            "Second chapter quote",
            chapter: "2. O socialismo",
            cfi: "epubcfi(/6/8!/4/2,/1:0,/1:20)",
            created: "2026-11-01 09:00",
        ),
        highlight(
            "No mercado, cada centavo gasto é um voto.\nSegunda linha",
            chapter: "1. O capitalismo",
            cfi: "epubcfi(/6/4!/4/9,/1:0,/1:40)",
            note: "Minha nota.",
            id: firstID,
        ),
        highlight("Bookmark", chapter: "1. O capitalismo", cfi: nil, color: nil),
        highlight(
            "Later in chapter one",
            chapter: "1. O capitalismo",
            cfi: "epubcfi(/6/4!/4/10[para],/1:3,/1:9)",
            created: "2026-11-02 09:00",
        ),
    ]

    let section = try #require(
        ObsidianNote.renderHighlightsSection(
            bookUUID: "book-1",
            highlights: highlights,
            timeZone: utc,
        )
    )

    #expect(section.hasPrefix("<!-- silveran:highlights book=book-1 -->\n## Destaques\n"))
    #expect(section.hasSuffix("<!-- silveran:end -->"))
    #expect(!section.contains("Bookmark"))
    #expect(
        section.contains(
            """
            > No mercado, cada centavo gasto é um voto.
            > Segunda linha
            > — 11/11/2026

            ^h-3f9a2c

            Minha nota.
            """
        )
    )
    let chapterOne = try #require(section.range(of: "### 1. O capitalismo"))
    let later = try #require(section.range(of: "Later in chapter one"))
    let chapterTwo = try #require(section.range(of: "### 2. O socialismo"))
    #expect(chapterOne.lowerBound < later.lowerBound)
    #expect(later.lowerBound < chapterTwo.lowerBound)
}

@Test func onlyBookmarksRenderNoSection() {
    let highlights = [highlight("Bookmark", chapter: "One", cfi: nil, color: nil)]
    #expect(ObsidianNote.renderHighlightsSection(bookUUID: "b", highlights: highlights) == nil)
}

@Test func upsertAppendsReplacesAndRemovesSectionWithoutTouchingUserText() throws {
    let userNote = "---\ntype: book\n---\n## Leituras\n\nMy own thoughts.\n\n"
    let first = "<!-- silveran:highlights book=b -->\n## Destaques\n\nA\n<!-- silveran:end -->"
    let second = "<!-- silveran:highlights book=b -->\n## Destaques\n\nB\n<!-- silveran:end -->"

    let appended = try #require(ObsidianNote.upsertSection(in: userNote, section: first))
    #expect(appended == "---\ntype: book\n---\n## Leituras\n\nMy own thoughts.\n\n" + first + "\n")

    let withTail = appended + "\nWritten after the section.\n"
    let replaced = try #require(ObsidianNote.upsertSection(in: withTail, section: second))
    #expect(replaced.contains("\nB\n"))
    #expect(!replaced.contains("\nA\n"))
    #expect(replaced.hasSuffix("<!-- silveran:end -->\n\nWritten after the section.\n"))
    #expect(replaced.hasPrefix("---\ntype: book\n---\n## Leituras\n\nMy own thoughts.\n\n"))

    let removed = try #require(ObsidianNote.upsertSection(in: appended, section: nil))
    #expect(removed == "---\ntype: book\n---\n## Leituras\n\nMy own thoughts.\n")
}

@Test func upsertRefusesSectionWithoutEndMarker() {
    let broken = "text\n<!-- silveran:highlights book=b -->\n## Destaques\nuser text after"
    #expect(ObsidianNote.upsertSection(in: broken, section: "new") == nil)
}

@Test func readingsDateIsAddedToEachYamlShape() {
    let missing = "---\ntype: book\nauthor: x\n---\nBody\n"
    #expect(
        ObsidianNote.addListValue("2026-11-11", key: "readings", to: missing)
            == "---\ntype: book\nauthor: x\nreadings:\n  - 2026-11-11\n---\nBody\n"
    )

    let block = "---\nreadings:\n  - 2024-12-25\ncreated: 2026-11-06\n---\n"
    #expect(
        ObsidianNote.addListValue("2026-11-11", key: "readings", to: block)
            == "---\nreadings:\n  - 2024-12-25\n  - 2026-11-11\ncreated: 2026-11-06\n---\n"
    )
    #expect(ObsidianNote.addListValue("2024-12-25", key: "readings", to: block) == block)

    let flow = "---\nreadings: []\n---\n"
    #expect(
        ObsidianNote.addListValue("2026-11-11", key: "readings", to: flow)
            == "---\nreadings:\n  - 2026-11-11\n---\n"
    )

    let noFrontmatter = "Just text\n"
    #expect(
        ObsidianNote.addListValue("2026-11-11", key: "readings", to: noFrontmatter)
            == "---\nreadings:\n  - 2026-11-11\n---\nJust text\n"
    )
}

@Test func newNoteFillsTemplateDateAndEmptyAuthor() {
    let template =
        "---\ntype: book\ntags: []\nauthor:\ncreated: {{date:YYYY-MM-DD}}\n---\n\n# {{title}}\n{{unknown}}\n"
    let note = ObsidianNote.newNote(
        template: template,
        book: book,
        now: day("2026-11-11 22:30"),
        timeZone: utc,
    )
    #expect(
        note
            == "---\ntype: book\ntags: []\nauthor: \"[[Ludwig von Mises]]\"\ncreated: 2026-11-11\n---\n\n# As Seis Lições: Reflexões\n{{unknown}}\n"
    )
}

@Test func newNoteKeepsAuthorAlreadySetByTemplate() {
    let note = ObsidianNote.newNote(
        template: "---\nauthor: Someone\n---\n",
        book: book,
        now: day("2026-11-11 10:00"),
        timeZone: utc,
    )
    #expect(note == "---\nauthor: Someone\n---\n")
}

@Test func fileNamesDropCharactersObsidianRejects() {
    #expect(ObsidianNote.fileName(for: "Crash: uma breve história") == "Crash uma breve história")
    #expect(ObsidianNote.fileName(for: "What? [Part #1] / Notes.") == "What Part 1 Notes")
}

@Test func matchKeysIgnoreCaseAccentsAndSubtitle() {
    let keys = ObsidianNote.matchKeys(for: book)
    #expect(keys.contains(ObsidianNote.matchKey("As Seis Licoes")))
    #expect(keys.contains(ObsidianNote.matchKey("as seis lições reflexões")))
}

@Test func vaultSyncMatchesExistingNoteAndKeepsItsText() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("obsidian-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = ObsidianVault(
        rootURL: root,
        notesFolder: "Sources",
        templatePath: "Templates/Book.md",
    )
    let existing = "---\ntype: book\nreadings:\n  - 2024-12-25\n---\n\nMy notes.\n"
    try vault.write(existing, to: "Sources/As Seis Licoes.md")

    let result = try #require(
        try vault.sync(
            book: book,
            rememberedPath: nil,
            startedOn: day("2026-11-11 10:00"),
            highlights: [highlight("Quote", chapter: "Um", cfi: nil)],
            createIfMissing: true,
            timeZone: utc,
        )
    )

    #expect(
        result
            == ObsidianVault.Result(
                notePath: "Sources/As Seis Licoes.md",
                created: false,
                changed: true,
            )
    )
    let text = try #require(vault.read("Sources/As Seis Licoes.md"))
    #expect(
        text.hasPrefix(
            "---\ntype: book\nreadings:\n  - 2024-12-25\n  - 2026-11-11\n---\n\nMy notes.\n\n"
        )
    )
    #expect(text.contains("> Quote"))

    try vault.write(text, to: "Sources/Renamed in Obsidian.md")
    try FileManager.default.removeItem(at: vault.url(forRelativePath: "Sources/As Seis Licoes.md"))
    #expect(
        vault.findNote(for: book, rememberedPath: "Sources/As Seis Licoes.md")
            == "Sources/Renamed in Obsidian.md"
    )
}

@Test func vaultSyncCreatesNoteFromTemplateOnlyWhenAllowed() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("obsidian-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = ObsidianVault(
        rootURL: root,
        notesFolder: "Sources",
        templatePath: "Templates/Book",
    )
    try vault.write(
        "---\ntype: book\nauthor:\ncreated: {{date:YYYY-MM-DD}}\n---\n",
        to: "Templates/Book.md",
    )

    #expect(
        try vault.sync(
            book: book,
            rememberedPath: nil,
            startedOn: nil,
            highlights: [],
            createIfMissing: false,
        ) == nil
    )

    let result = try #require(
        try vault.sync(
            book: book,
            rememberedPath: nil,
            startedOn: day("2026-11-11 10:00"),
            highlights: nil,
            createIfMissing: true,
            now: day("2026-11-11 10:00"),
            timeZone: utc,
        )
    )
    #expect(result.notePath == "Sources/As Seis Lições Reflexões.md")
    #expect(result.created)
    #expect(
        vault.read(result.notePath)
            == "---\ntype: book\nauthor: \"[[Ludwig von Mises]]\"\ncreated: 2026-11-11\nreadings:\n  - 2026-11-11\n---\n"
    )
}

@Test func cfiSortKeyReadsParentAndStartStepsNumerically() {
    #expect(
        ObsidianBookOutline.cfiSortKey(
            "epubcfi(/6/50!/4[Cartas-V1-2]/2/6,/4[ra-3]/1:173,/6[ra-4]/1:74)"
        )
            == [6, 50, 4, 2, 6, 4, 1, 173]
    )
    #expect(ObsidianBookOutline.cfiSortKey("epubcfi(/6/30!/4/146)") == [6, 30, 4, 146])
    #expect(ObsidianBookOutline.cfiSortKey("not a cfi") == nil)
    let early = ObsidianBookOutline.cfiSortKey("epubcfi(/6/30!/4,/12/10[ra-25]/1:80,/14/2/1:0)")!
    let late = ObsidianBookOutline.cfiSortKey("epubcfi(/6/30!/4/146,/2[ra-272]/5:2,/4/1:209)")!
    #expect(early.lexicographicallyPrecedes(late))
}

@Test func outlineGivesFilesWithoutTocEntryTheChapterBeforeThem() {
    let outline = ObsidianBookOutline(
        sectionIDs: [
            "OEBPS/cover.html",
            "OEBPS/text/part0001.html",
            "OEBPS/text/part0002.html",
            "OEBPS/text/part0003.html",
        ],
        toc: [
            ("Primeira   Lição", 1),
            ("Segunda Lição", 3),
            ("Segunda Lição — parte 2", 3),
        ],
    )
    #expect(outline.chapter(forHref: "cover.html") == nil)
    #expect(outline.chapter(forHref: "text/part0001.html#start") == "Primeira Lição")
    #expect(outline.chapter(forHref: "text/part0002.html") == "Primeira Lição")
    #expect(outline.chapter(forHref: "text/part0003.html") == "Segunda Lição")
}

@Test func outlineChapterWinsOverLocatorTitleAndFallsBackWhenUnknown() throws {
    let outline = ObsidianBookOutline(
        sectionIDs: ["OEBPS/a.html", "OEBPS/b.html"],
        toc: [("Capítulo A", 0)],
    )
    let highlights = [
        highlight("In A", chapter: nil, cfi: "epubcfi(/6/2!/4/2)", href: "a.html"),
        highlight(
            "Unknown file",
            chapter: "Locator title",
            cfi: "epubcfi(/6/4!/4/2)",
            href: "zzz.html",
        ),
        highlight("No title anywhere", chapter: nil, cfi: "epubcfi(/6/6!/4/2)", href: "zzz.html"),
    ]
    let section = try #require(
        ObsidianNote.renderHighlightsSection(
            bookUUID: "b",
            highlights: highlights,
            outline: outline,
            timeZone: utc,
        )
    )
    #expect(section.contains("### Capítulo A\n\n> In A"))
    #expect(section.contains("### Locator title\n\n> Unknown file"))
    #expect(section.contains("### Sem capítulo\n\n> No title anywhere"))
}
