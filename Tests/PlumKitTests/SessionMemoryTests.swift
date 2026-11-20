import XCTest
@testable import PlumKit

/// Not a correctness test: how much memory terminals hold once a lot of
/// output has gone through them, as with agents running for hours. Feeds the
/// engine directly (no pty, no drawing). Runs only when PLUM_BENCH_DATA points
/// at a folder made by bench/gen-data.py.
final class SessionMemoryTests: XCTestCase {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testMemoryAfterOutput() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLUM_BENCH_DATA"] else {
            throw XCTSkip("set PLUM_BENCH_DATA to measure")
        }
        let count = Int(ProcessInfo.processInfo.environment["PLUM_BENCH_SESSIONS"] ?? "") ?? 10
        let name = ProcessInfo.processInfo.environment["PLUM_BENCH_SETS"] ?? "sync_tui"
        let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name + ".txt"))
        let start = Self.footprintMB()
        var sessions: [TerminalSession] = []
        for _ in 0..<count { sessions.append(TerminalSession(cols: 122, rows: 46)) }
        let empty = Self.footprintMB()
        for session in sessions {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = min(64 * 1024, raw.count - offset)
                    session.feed(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + n)]))
                    offset += n
                }
            }
        }
        let full = Self.footprintMB()
        print(String(format: "MEM %@ %d sessions: new %.1f MB each, after %.0f MB of output each %.1f MB each (total %.0f → %.0f MB)",
                     name, count, (empty - start) / Double(count), Double(data.count) / 1e6, (full - empty) / Double(count), start, full))
        withExtendedLifetime(sessions) {}
    }
}
