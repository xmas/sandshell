import Testing
@testable import Sandshell

/// `SymbolCatalog` (UI/SymbolCatalog.swift): the symbols the "See more…" picker
/// offers, and its search.
struct SymbolCatalogTests {
    @Test func availableKeepsTheCatalogOrder() {
        let available = SymbolCatalog.available
        #expect(available.isEmpty == false)
        #expect(available == SymbolCatalog.all.filter { available.contains($0) })
        #expect(available.contains("folder"))
    }

    @Test(arguments: ["", "   "])
    func aBlankQueryOffersEverySymbol(query: String) {
        #expect(SymbolCatalog.available(matching: query) == SymbolCatalog.available)
    }

    @Test(arguments: ["FOLDER", " folder ", "Folder"])
    func searchIgnoresCaseAndSurroundingSpaces(query: String) {
        let matches = SymbolCatalog.available(matching: query)
        #expect(matches == SymbolCatalog.available(matching: "folder"))
        #expect(matches.contains("folder.fill"))
        #expect(matches.allSatisfy { $0.contains("folder") })
    }

    @Test func noMatchOffersNothing() {
        #expect(SymbolCatalog.available(matching: "zebra-unicorn").isEmpty)
    }
}
