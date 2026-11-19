import Foundation
import Testing
@testable import Toolsy

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ToolsyModPreferences-\(UUID().uuidString)/ModPreferences.json")
}

private func cleanUp(_ preferences: ModPreferences) {
    try? FileManager.default.removeItem(at: preferences.file.deletingLastPathComponent())  // best effort: a temporary folder
}

struct ModPreferencesTests {
    private static let names = ["a": "alpha", "b": "Beta", "c": "Gamma", "d": "alpha", "n": "New"]

    private func arranged(_ preferences: ModPreferences, _ ids: [String]) -> [String] {
        preferences.arranged(ids, id: { $0 }, name: { Self.names[$0] ?? $0 })
    }

    @Test func withoutAFileModsAreListedByNameAsCards() {
        let preferences = ModPreferences(file: temporaryFile())
        #expect(preferences.listStyle == .cards)
        // By name in the user's language, ignoring case; the same name by id.
        #expect(arranged(preferences, ["c", "b", "d", "a"]) == ["a", "d", "b", "c"])
        #expect(!preferences.isHidden("a"))
        #expect(preferences.look(of: "a").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: preferences.file.path(percentEncoded: false)))
    }

    @Test func aMovePlacesTheListedModsAndOnesInstalledLaterFollow() {
        let preferences = ModPreferences(file: temporaryFile())
        preferences.move("c", toPosition: 0, among: ["a", "b", "c"])
        #expect(preferences.order == ["c", "a", "b"])
        #expect(arranged(preferences, ["a", "b", "c", "n"]) == ["c", "a", "b", "n"])

        preferences.move("c", toPosition: 2, among: ["c", "a", "b"])
        #expect(preferences.order == ["a", "b", "c"])
        // Out of range, a position is the first or the last place.
        preferences.move("a", toPosition: 9, among: ["a", "b", "c"])
        #expect(preferences.order == ["b", "c", "a"])
        preferences.move("a", toPosition: -3, among: ["b", "c", "a"])
        #expect(preferences.order == ["a", "b", "c"])
        // A mod that is not listed is not moved; one listed alone stays where it is, whatever the position.
        preferences.move("x", toPosition: 0, among: ["a", "b", "c"])
        #expect(preferences.order == ["a", "b", "c"])
        preferences.move("b", toPosition: -1, among: ["b"])
        preferences.move("b", toPosition: 5, among: ["b"])
        #expect(preferences.order == ["a", "b", "c"])
        cleanUp(preferences)
    }

    @Test func modsThatAreNotListedKeepTheirPlaces() {
        let preferences = ModPreferences(file: temporaryFile())
        // "h" is hidden and "x" not installed; neither is listed while "b" moves.
        preferences.move("h", toPosition: 1, among: ["a", "h", "b", "x"])
        #expect(preferences.order == ["a", "h", "b", "x"])
        preferences.move("b", toPosition: 0, among: ["a", "b"])
        #expect(preferences.order == ["b", "a", "h", "x"])
        // Last among the listed mods is right after the one listed last.
        preferences.move("b", toPosition: 1, among: ["b", "a"])
        #expect(preferences.order == ["a", "b", "h", "x"])
        cleanUp(preferences)
    }

    @Test func choicesAreSavedAndReadBack() throws {
        let file = temporaryFile()
        let preferences = ModPreferences(file: file)
        preferences.listStyle = .compact
        preferences.move("b", toPosition: 0, among: ["a", "b"])
        preferences.setHidden(true, "a")
        preferences.setLook(ModLook(name: "Coffee", icon: "cup.and.saucer.fill", tint: "brown"), of: "b", originalName: "Beta")

        let read = ModPreferences(file: file)
        #expect(read.listStyle == .compact)
        #expect(read.order == ["b", "a"])
        #expect(read.isHidden("a"))
        #expect(read.look(of: "b") == ModLook(name: "Coffee", icon: "cup.and.saucer.fill", tint: "brown"))

        read.setHidden(false, "a")
        #expect(!ModPreferences(file: file).isHidden("a"))
        cleanUp(preferences)
    }

    @Test func aDamagedOrNewerFileGivesTheDefaultsAndIsKeptUntilAChange() throws {
        for contents in ["{", #"{"version": 2, "listStyle": "compact", "order": ["b"]}"#] {
            let file = temporaryFile()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            let preferences = ModPreferences(file: file)
            #expect(preferences.listStyle == .cards)
            #expect(preferences.order.isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == contents)

            preferences.setHidden(true, "a")
            #expect(ModPreferences(file: file).isHidden("a"))
            cleanUp(preferences)
        }
    }

    @Test func anOlderOrHandEditedFileIsReadAsFarAsItMakesSense() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let looks = #"{"a": {}, "b": {"tint": "red"}, "c": {"name": " \n "}, "d": {"name": "Two\nlines ", "icon": ""}}"#
        try Data(#"{"version": 1, "listStyle": "tiles", "order": ["b", "a", "b"], "looks": \#(looks)}"#.utf8).write(to: file)
        let preferences = ModPreferences(file: file)
        #expect(preferences.listStyle == .cards)
        #expect(preferences.order == ["b", "a"])
        #expect(preferences.hidden.isEmpty)
        // Looks are tidied as the panel keeps them: no blank names, one line.
        #expect(preferences.looks == ["b": ModLook(tint: "red"), "d": ModLook(name: "Two lines")])
        cleanUp(preferences)
    }

    @Test func aNameIsTidiedAndOneTheModHasIsNone() {
        let preferences = ModPreferences(file: temporaryFile())
        preferences.setLook(ModLook(name: "  Coffee\nBreak \n"), of: "a", originalName: "Keep Awake")
        #expect(preferences.look(of: "a").name == "Coffee Break")
        preferences.setLook(ModLook(name: String(repeating: "й", count: 100)), of: "a", originalName: "Keep Awake")
        #expect(preferences.look(of: "a").name?.count == ModLook.maxNameLength)

        // The mod's own name, or nothing, is no look of the user's: the entry goes.
        preferences.setLook(ModLook(name: "Keep Awake"), of: "a", originalName: "Keep Awake")
        #expect(preferences.looks["a"] == nil)
        preferences.setLook(ModLook(name: " ", icon: "", tint: ""), of: "a", originalName: "Keep Awake")
        #expect(preferences.looks["a"] == nil)
        cleanUp(preferences)
    }

    @Test func forgettingAModDropsEverythingChosenForIt() {
        let preferences = ModPreferences(file: temporaryFile())
        preferences.move("b", toPosition: 0, among: ["a", "b"])
        preferences.setHidden(true, "b")
        preferences.setLook(ModLook(tint: "red"), of: "b", originalName: "Beta")
        preferences.forget(modID: "b")
        #expect(preferences.order == ["a"])
        #expect(!preferences.isHidden("b"))
        #expect(preferences.looks.isEmpty)
        #expect(ModPreferences(file: preferences.file).order == ["a"])
        cleanUp(preferences)
    }

    @Test func everyOfferedColourIsOneTintKnows() {
        for name in ModLook.palette {
            #expect(Tint.resolve(name) != nil, "\(name)")
        }
        #expect(Set(ModLook.palette).count == ModLook.palette.count)
    }
}
