import XCTest
import SwiftTreeSitter
import TreeSitterJai

final class TreeSitterJaiTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_jai())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading Jai grammar")
    }
}
