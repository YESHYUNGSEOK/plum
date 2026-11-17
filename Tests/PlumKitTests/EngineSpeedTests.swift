import XCTest
@testable import PlumKit

/// Not a correctness test: measures how fast the VT engine alone consumes the
/// benchmark data, with no pty and no drawing. Runs only when
/// PLUM_BENCH_DATA points at a folder made by bench/gen-data.py.
final class EngineSpeedTests: XCTestCase {
    func testEngineThroughput() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLUM_BENCH_DATA"] else {
            throw XCTSkip("set PLUM_BENCH_DATA to measure")
        }
        for name in ["ascii", "scrolling", "dense_cells", "unicode", "cursor_motion", "scroll_region", "sync_tui"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name + ".txt"))
            var best = Double.infinity
            for _ in 0..<3 {
                let session = TerminalSession(cols: 122, rows: 46)
                let start = DispatchTime.now().uptimeNanoseconds
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = min(128 * 1024, raw.count - offset)
                        session.feed(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + count)]))
                        offset += count
                    }
                }
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            print(String(format: "ENGINE %@ %.0f MB/s", name.padding(toLength: 14, withPad: " ", startingAt: 0), Double(data.count) / 1e6 / best))
        }
    }
}
