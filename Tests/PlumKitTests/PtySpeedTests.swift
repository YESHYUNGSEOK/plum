import XCTest
@testable import PlumKit

/// Not a correctness test: measures how fast output goes from a program
/// through the pty into the VT engine, with no drawing. The program is `cat`
/// on the benchmark data, timed inside the terminal as bench/runner.sh does.
/// Runs only when PLUM_BENCH_DATA points at a folder made by bench/gen-data.py.
final class PtySpeedTests: XCTestCase {
    /// CPU time this process has used, all threads.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func testPtyThroughput() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLUM_BENCH_DATA"] else {
            throw XCTSkip("set PLUM_BENCH_DATA to measure")
        }
        let names = ProcessInfo.processInfo.environment["PLUM_BENCH_SETS"]?.split(separator: ",").map(String.init)
            ?? ["ascii", "scrolling", "dense_cells", "unicode", "cursor_motion", "scroll_region", "sync_tui"]
        let runs = Int(ProcessInfo.processInfo.environment["PLUM_BENCH_RUNS"] ?? "") ?? 5
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("plum-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for name in names {
            let data = URL(fileURLWithPath: folder).appendingPathComponent(name + ".txt").path
            let size = Double((try FileManager.default.attributesOfItem(atPath: data)[.size] as? NSNumber)?.intValue ?? 0)
            var speeds: [Double] = []
            var cpu: [Double] = []
            for run in 0..<runs {
                let cpuBefore = Self.cpuSeconds()
                let session = TerminalSession(cols: 122, rows: 46)
                try session.start(shell: "/bin/sh", cwd: work.path, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
                let result = work.appendingPathComponent("result-\(name)-\(run)").path
                session.write("perl -MTime::HiRes=time -e '$s = time; system(\"cat\", $ARGV[0]); open(F, \">\", $ARGV[1]); printf F \"%.6f\", time - $s; close F' \(data) \(result).tmp && mv \(result).tmp \(result); exit\n")
                let deadline = Date().addingTimeInterval(120)
                while !FileManager.default.fileExists(atPath: result), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                let seconds = try XCTUnwrap(Double(String(contentsOfFile: result, encoding: .utf8)))
                // This process only: the reading and parsing, not cat.
                let cpuPerGB = (Self.cpuSeconds() - cpuBefore) / (size / 1e9)
                speeds.append(size / 1e6 / seconds)
                cpu.append(cpuPerGB)
                withExtendedLifetime(session) {}
            }
            let m = { (v: [Double]) in v.sorted()[v.count / 2] }
            let sorted = speeds.sorted()
            print(String(format: "PTY %@ median %.0f MB/s (min %.0f, max %.0f, n=%d), CPU %.1f s/GB",
                         name.padding(toLength: 14, withPad: " ", startingAt: 0), sorted[sorted.count / 2], sorted.first!, sorted.last!, runs, m(cpu)))
        }
    }
}
