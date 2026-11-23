import QuartzCore
import XCTest
@testable import PlumKit

/// Not a correctness test: output speed with drawing, as in the app. A
/// program writes the benchmark data through a pty while the main thread
/// draws whenever the screen changed, at most 120 times a second, into an
/// off-screen Metal layer. With PLUM_BENCH_HOST=1 the pty belongs to a
/// terminal host (in this process) and output comes over its socket, as in
/// the app. Runs only when PLUM_BENCH_DATA points at a folder made by
/// bench/gen-data.py.
final class RenderSpeedTests: XCTestCase {
    @MainActor
    func testThroughputWhileDrawing() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLUM_BENCH_DATA"] else {
            throw XCTSkip("set PLUM_BENCH_DATA to measure")
        }
        let names = ProcessInfo.processInfo.environment["PLUM_BENCH_SETS"]?.split(separator: ",").map(String.init)
            ?? ["ascii", "scrolling", "dense_cells", "unicode", "cursor_motion", "scroll_region", "sync_tui"]
        let runs = Int(ProcessInfo.processInfo.environment["PLUM_BENCH_RUNS"] ?? "") ?? 3
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("plum-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var client: TerminalHostClient?
        var host: TerminalHost?
        if ProcessInfo.processInfo.environment["PLUM_BENCH_HOST"] == "1" {
            let socketPath = NSTemporaryDirectory() + "plum-bench-\(UUID().uuidString.prefix(8)).sock"
            host = TerminalHost(socketPath: socketPath)
            try host!.listen()
            client = try XCTUnwrap(TerminalHostClient(socketPath: socketPath, executable: "/nonexistent"))
        }
        defer { withExtendedLifetime(host) {} }
        let environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        let draws = ProcessInfo.processInfo.environment["PLUM_BENCH_NODRAW"] != "1"

        for name in names {
            let data = URL(fileURLWithPath: folder).appendingPathComponent(name + ".txt").path
            let size = Double((try FileManager.default.attributesOfItem(atPath: data)[.size] as? NSNumber)?.intValue ?? 0)
            var speeds: [Double] = []
            var frameMs: [Double] = []
            var frames: [Int] = []
            var cpu: [Double] = []
            var buildMs: [Double] = []
            var longestMs: [Double] = []
            for run in 0..<runs {
                let cpuBefore = PtySpeedTests.cpuSeconds()
                let renderer = TerminalRenderer(font: FontSpec(name: "Menlo", pointSize: 13, scale: 2))
                renderer.padding = 28
                let m = renderer.metrics
                let layer = CAMetalLayer()
                layer.device = RenderContext.shared.device
                layer.pixelFormat = .bgra8Unorm
                layer.framebufferOnly = true
                layer.drawableSize = CGSize(width: 122 * m.cellWidth + 56, height: 46 * m.cellHeight + 56)

                let result = work.appendingPathComponent("result-\(name)-\(run)").path
                let command = "perl -MTime::HiRes=time -e '$s = time; system(\"cat\", $ARGV[0]); open(F, \">\", $ARGV[1]); printf F \"%.6f\", time - $s; close F' \(data) \(result).tmp && mv \(result).tmp \(result); exit"
                let session: TerminalSession
                if let client {
                    let id = UUID()
                    let carried = try XCTUnwrap(client.open(
                        id: id, workspace: UUID(), shell: "/bin/sh", cwd: work.path, environment: environment,
                        cols: 122, rows: 46, command: command))
                    session = TerminalSession(id: id, cols: carried.cols, rows: carried.rows)
                    session.attach(fd: carried.fd, pid: carried.pid, remote: .init(
                        resize: { cols, rows, width, height in client.resize(id, cols: cols, rows: rows, width: width, height: height) },
                        end: { client.close(id) }))
                } else {
                    session = TerminalSession(cols: 122, rows: 46)
                    try session.start(shell: "/bin/sh", cwd: work.path, environment: environment)
                    session.write(command + "\n")
                }
                session.resize(cols: 122, rows: 46, cellWidthPx: UInt32(m.cellWidth), cellHeightPx: UInt32(m.cellHeight))
                var dirty = false
                session.onDirty = { dirty = true }

                var drawn = 0
                var drawing: Double = 0
                var building: Double = 0
                var longest: Double = 0
                let deadline = Date().addingTimeInterval(120)
                var next = CACurrentMediaTime()
                while !FileManager.default.fileExists(atPath: result), Date() < deadline {
                    next += 1.0 / (Double(ProcessInfo.processInfo.environment["PLUM_BENCH_HZ"] ?? "") ?? 120)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0, next - CACurrentMediaTime())))
                    guard dirty, draws else { continue }
                    dirty = false
                    let start = CACurrentMediaTime()
                    session.withFrame { renderer.update(from: $0, overlay: .init()) }
                    let built = CACurrentMediaTime() - start
                    building += built
                    longest = max(longest, built)
                    renderer.draw(to: layer)
                    drawing += CACurrentMediaTime() - start
                    drawn += 1
                }
                let seconds = try XCTUnwrap(Double(String(contentsOfFile: result, encoding: .utf8)))
                speeds.append(size / 1e6 / seconds)
                // This process: reading, parsing, drawing (and the host's relay with PLUM_BENCH_HOST).
                cpu.append((PtySpeedTests.cpuSeconds() - cpuBefore) / (size / 1e9))
                frameMs.append(drawn > 0 ? drawing / Double(drawn) * 1000 : 0)
                // Includes waiting for the terminal while output is being parsed.
                buildMs.append(drawn > 0 ? building / Double(drawn) * 1000 : 0)
                longestMs.append(longest * 1000)
                frames.append(drawn)
                withExtendedLifetime(session) {}
            }
            let median = { (v: [Double]) in v.sorted()[v.count / 2] }
            print(String(format: "DRAW %@ median %.0f MB/s (min %.0f, max %.0f, n=%d), CPU %.2f s/GB, %.2f ms a frame (building %.3f, longest %.2f), %d frames",
                         name.padding(toLength: 14, withPad: " ", startingAt: 0), median(speeds), speeds.min()!, speeds.max()!,
                         runs, median(cpu), median(frameMs), median(buildMs), median(longestMs), frames.sorted()[frames.count / 2]))
        }
    }

    /// The main thread's cost of one frame that redraws every row, the case
    /// while output streams, on a screen left by each data set. No pty, so
    /// the number is steady enough to compare changes by.
    @MainActor
    func testFrameCost() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLUM_BENCH_DATA"] else {
            throw XCTSkip("set PLUM_BENCH_DATA to measure")
        }
        let names = ProcessInfo.processInfo.environment["PLUM_BENCH_SETS"]?.split(separator: ",").map(String.init)
            ?? ["ascii", "dense_cells", "unicode", "sync_tui"]
        for name in names {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name + ".txt"))
            let renderer = TerminalRenderer(font: FontSpec(name: "Menlo", pointSize: 13, scale: 2))
            renderer.padding = 28
            let m = renderer.metrics
            let layer = CAMetalLayer()
            layer.device = RenderContext.shared.device
            layer.pixelFormat = .bgra8Unorm
            layer.drawableSize = CGSize(width: 122 * m.cellWidth + 56, height: 46 * m.cellHeight + 56)
            let session = TerminalSession(cols: 122, rows: 46)
            data.prefix(2_000_000).withUnsafeBytes { session.feed($0) }
            // Warm up: glyphs rasterized once.
            for _ in 0..<5 {
                renderer.needsFullRebuild = true
                session.withFrame { renderer.update(from: $0, overlay: .init()) }
                renderer.draw(to: layer)
            }
            // This thread's CPU time: waiting for a free drawable doesn't count.
            func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
            let frames = Int(ProcessInfo.processInfo.environment["PLUM_BENCH_FRAMES"] ?? "") ?? 400
            var update: Double = 0
            var total: Double = 0
            for _ in 0..<frames {
                renderer.needsFullRebuild = true
                let start = cpu()
                session.withFrame { renderer.update(from: $0, overlay: .init()) }
                let built = cpu()
                renderer.draw(to: layer)
                update += built - start
                total += cpu() - start
            }
            print(String(format: "FRAME %@ build %.3f ms, build+draw %.3f ms CPU (full redraw, 122x46)",
                         name.padding(toLength: 12, withPad: " ", startingAt: 0), update / Double(frames) * 1000, total / Double(frames) * 1000))
        }
    }
}
