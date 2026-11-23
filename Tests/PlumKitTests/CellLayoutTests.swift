import GhosttyVt
import XCTest
@testable import PlumKit

/// Frames decode cells from the bit layout the library describes; that
/// must agree with asking the library field by field.
final class CellLayoutTests: XCTestCase {
    func testDecodingAgreesWithTheLibrary() throws {
        let layout = try XCTUnwrap(CellLayout.current, "the library describes GhosttyCell")
        let session = TerminalSession(cols: 40, rows: 6)
        // Plain, styled, wide, a cluster, colored blanks, an empty row.
        session.feed("plain \u{1b}[1;31mbold red\u{1b}[0m 한글 👍🏽 e\u{301}\r\n\u{1b}[44m    \u{1b}[48;2;1;2;3m  \u{1b}[0m\r\n\u{1b}[4munder\u{1b}[0m")
        var cells: [GhosttyCell] = []
        session.withTerminal { terminal in
            for y in 0..<6 {
                for x in 0..<40 {
                    var point = GhosttyPoint()
                    point.tag = GHOSTTY_POINT_TAG_ACTIVE
                    point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                    var ref = GhosttyGridRef()
                    guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { continue }
                    var cell: GhosttyCell = 0
                    if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS { cells.append(cell) }
                }
            }
        }
        XCTAssertGreaterThan(cells.count, 100)
        var kinds = Set<UInt32>()
        for cell in cells {
            var wide = GHOSTTY_CELL_WIDE_NARROW, tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            var styled = false, codepoint: UInt32 = 0
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
            XCTAssertEqual(UInt32(layout.wide(cell)), wide.rawValue)
            XCTAssertEqual(UInt32(layout.contentTag(cell)), tag.rawValue)
            XCTAssertEqual(layout.styleID(cell) != 0, styled)
            if tag == GHOSTTY_CELL_CONTENT_CODEPOINT || tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
                XCTAssertEqual(UInt32(layout.codepoint(cell)), codepoint)
            }
            kinds.insert(tag.rawValue * 10 + wide.rawValue)
        }
        XCTAssertGreaterThanOrEqual(kinds.count, 5, "the screen covered the kinds of cell")
    }
}
