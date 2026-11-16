// Measurement helpers for comparing terminal apps from the outside, so the
// same method applies to Plum and to apps we cannot instrument.
//
//   plumbench launch <app> [--activate] [--env K=V]... [-- args...]
//   plumbench sample <pid>
//   plumbench activate <pid>
//   plumbench key <pid> <keycode> [cmd|ctrl|shift|alt]...
//   plumbench children <pid>
//   plumbench window <pid>
//   plumbench place <pid> <x> <y>
//   plumbench frames <pid> <seconds>
//   plumbench latency <pid> <samples> <out.csv> [pause ms]
//
// Build: swiftc -O bench/plumbench.swift -o bench/plumbench

import AppKit
import ApplicationServices
import CoreMedia
import Darwin
import ScreenCaptureKit

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func milliseconds(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1e6 }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: Processes and windows

struct WindowInfo {
    var id: UInt32
    var bounds: CGRect
    var onScreen: Bool
}

func mainWindow(of pid: pid_t, onScreenOnly: Bool) -> WindowInfo? {
    let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
    let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    for window in all {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.width > 200,
              let id = window[kCGWindowNumber as String] as? UInt32 else { continue }
        return WindowInfo(id: id, bounds: bounds, onScreen: (window[kCGWindowIsOnscreen as String] as? Bool) == true)
    }
    return nil
}

func childCount(_ pid: pid_t) -> Int {
    var buffer = [pid_t](repeating: 0, count: 512)
    return max(0, Int(proc_listchildpids(pid, &buffer, Int32(MemoryLayout<pid_t>.size * buffer.count))))
}

/// Asked through Accessibility: NSWorkspace only updates its answer while a
/// run loop is spinning, which a command-line tool does not have.
func frontmostPID() -> pid_t {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
          let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return 0 }
    var pid: pid_t = 0
    AXUIElementGetPid(element as! AXUIElement, &pid)
    return pid
}

func activate(_ pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    let deadline = now() + 5_000_000_000
    var steady = 0
    // Focus can bounce back to the previous app for a moment after a
    // switch, so only report success once it has held.
    while now() < deadline {
        if frontmostPID() == pid {
            steady += 1
            if steady >= 4 { return true }
        } else {
            steady = 0
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
        usleep(80_000)
    }
    return false
}

struct Usage {
    var footprintMB: Double
    var peakMB: Double
    var cpuMS: Double
}

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else { return nil }
    // CPU times are reported in Mach time units, which are not nanoseconds
    // on Apple Silicon.
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpuTicks = Double(info.ri_user_time + info.ri_system_time)
    return Usage(
        footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
        peakMB: Double(info.ri_lifetime_max_phys_footprint) / 1_048_576,
        cpuMS: cpuTicks * Double(timebase.numer) / Double(timebase.denom) / 1e6)
}

// MARK: Keys

func postKeyEvent(_ pid: pid_t, code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { return }
    event.flags = flags
    // To the target process only: a stray keystroke must never land in
    // whatever else the person at the machine is doing.
    event.postToPid(pid)
}

func postKey(_ pid: pid_t, code: CGKeyCode, flags: CGEventFlags = []) {
    postKeyEvent(pid, code: code, down: true, flags: flags)
    usleep(3000)
    postKeyEvent(pid, code: code, down: false, flags: flags)
}

// MARK: Frame timing

func machToNanoseconds(_ value: UInt64) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return value * UInt64(timebase.numer) / UInt64(timebase.denom)
}

/// Receives the frames the window server composites for one window, each
/// with the time it went to the display, and watches a band of rows in them.
///
/// Frames arrive for every composite of the display whether or not this
/// window changed, so "the picture changed" is decided by comparing pixels.
final class FrameWatcher: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var band: Range<Int>? // rows to compare; nil = every row
    private var current: [UInt8] = [] // the band's pixels in the latest frame
    private var lastChange: UInt64 = 0
    private var waiting: (start: UInt64, baseline: [UInt8])?
    private var result: (display: Double, arrival: Double)?
    private let arrived = DispatchSemaphore(value: 0)
    private(set) var frameCount = 0
    private(set) var rowLength = 0
    private(set) var height = 0
    var stream: SCStream?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let arrival = now()
        let display = (info[.displayTime] as? UInt64).map(machToNanoseconds) ?? arrival

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer) * 4 // rows can carry padding with junk in it
        let rows = CVPixelBufferGetHeight(buffer)

        lock.lock()
        defer { lock.unlock() }
        let range = (band ?? 0..<rows).clamped(to: 0..<rows)
        var pixels = [UInt8](repeating: 0, count: range.count * width)
        pixels.withUnsafeMutableBytes { destination in
            for (index, row) in range.enumerated() {
                destination.baseAddress!.advanced(by: index * width).copyMemory(from: base + row * stride, byteCount: width)
            }
        }
        frameCount += 1
        rowLength = width
        height = rows
        if pixels != current {
            current = pixels
            lastChange = arrival
        }
        if let pending = waiting, display >= pending.start, pixels != pending.baseline {
            result = (milliseconds(pending.start, display), milliseconds(pending.start, arrival))
            waiting = nil
            arrived.signal()
        }
    }

    func watch(rows: Range<Int>?) {
        lock.lock()
        band = rows
        current = []
        lock.unlock()
    }

    func snapshot() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// True when the watched rows have not changed for at least this long.
    func quietFor(_ nanoseconds: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !current.isEmpty && now() - lastChange > nanoseconds
    }

    /// Runs `trigger`, then waits for the first frame displayed after `start`
    /// whose watched rows differ from what was showing. Nil after a second.
    func change(after start: UInt64, trigger: () -> Void) -> (display: Double, arrival: Double)? {
        lock.lock()
        result = nil
        waiting = (start, current)
        lock.unlock()
        trigger()
        let timedOut = arrived.wait(timeout: .now() + 1) == .timedOut
        lock.lock()
        defer { lock.unlock() }
        waiting = nil
        return timedOut ? nil : result
    }
}

func watch(window id: UInt32) async throws -> FrameWatcher {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == id }) else { fail("window not shareable") }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width)
    configuration.height = Int(window.frame.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240) // never the limiting factor
    configuration.queueDepth = 8
    configuration.showsCursor = false
    let watcher = FrameWatcher()
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: watcher)
    try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: DispatchQueue(label: "plumbench.frames"))
    try await stream.startCapture()
    watcher.stream = stream
    return watcher
}

// MARK: Commands

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: plumbench <launch|sample|activate|key|children|window|latency> …") }

switch arguments[1] {
case "launch":
    // Starts a new instance and reports when its window is on screen and
    // when it has started its first child process (the shell).
    guard arguments.count >= 3 else { fail("usage: plumbench launch <app> [--activate] [--env K=V]... [-- args...]") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = arguments.contains("--activate")
    var environment: [String: String] = [:]
    var index = 3
    while index < arguments.count {
        if arguments[index] == "--env", index + 1 < arguments.count {
            let pair = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
            environment[pair[0]] = pair.count > 1 ? pair[1] : ""
            index += 2
        } else if arguments[index] == "--" {
            configuration.arguments = Array(arguments[(index + 1)...])
            break
        } else {
            index += 1
        }
    }
    configuration.environment = environment

    let start = now()
    var pid: pid_t = 0
    let launched = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: arguments[2]), configuration: configuration) { app, _ in
        pid = app?.processIdentifier ?? 0
        launched.signal()
    }
    launched.wait()
    guard pid > 0 else { fail("launch failed") }
    let registeredMS = milliseconds(start, now())

    var windowMS = -1.0
    var childMS = -1.0
    while (windowMS < 0 || childMS < 0), now() - start < 20_000_000_000 {
        if childMS < 0, childCount(pid) > 0 { childMS = milliseconds(start, now()) }
        if windowMS < 0, mainWindow(of: pid, onScreenOnly: true) != nil { windowMS = milliseconds(start, now()) }
        usleep(500)
    }
    print(String(format: "pid=%d registered_ms=%.1f window_ms=%.1f child_ms=%.1f", pid, registeredMS, windowMS, childMS))

case "sample":
    guard arguments.count >= 3, let pid = Int32(arguments[2]), let usage = usage(of: pid) else { fail("no such process") }
    print(String(format: "footprint_mb=%.1f peak_mb=%.1f cpu_ms=%.1f", usage.footprintMB, usage.peakMB, usage.cpuMS))

case "activate":
    guard arguments.count >= 3, let pid = Int32(arguments[2]) else { fail("usage: plumbench activate <pid>") }
    print(activate(pid) ? "frontmost" : "not-frontmost")

case "key":
    guard arguments.count >= 4, let pid = Int32(arguments[2]), let code = UInt16(arguments[3]) else {
        fail("usage: plumbench key <pid> <keycode> [cmd|ctrl|shift|alt]...")
    }
    var flags: CGEventFlags = []
    for name in arguments.dropFirst(4) {
        switch name {
        case "cmd": flags.insert(.maskCommand)
        case "ctrl": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        case "alt": flags.insert(.maskAlternate)
        default: fail("unknown modifier \(name)")
        }
    }
    guard activate(pid) else { fail("not-frontmost") }
    postKey(pid, code: code, flags: flags)
    print("ok")

case "children":
    guard arguments.count >= 3, let pid = Int32(arguments[2]) else { fail("usage: plumbench children <pid>") }
    print(childCount(pid))

case "window":
    // An app can own off-screen helper windows too; prefer the one on screen.
    guard arguments.count >= 3, let pid = Int32(arguments[2]),
          let window = mainWindow(of: pid, onScreenOnly: true) ?? mainWindow(of: pid, onScreenOnly: false) else {
        fail("no window")
    }
    // Which display the window is on, and that display's scale and refresh rate.
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    CGGetDisplaysWithPoint(CGPoint(x: window.bounds.midX, y: window.bounds.midY), 1, &display, &count)
    let mode = count > 0 ? CGDisplayCopyDisplayMode(display) : nil
    let scale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 0
    print(String(
        format: "id=%d x=%.0f y=%.0f w=%.0f h=%.0f onscreen=%@ display=%d scale=%.0f refresh=%.0f",
        window.id, window.bounds.minX, window.bounds.minY, window.bounds.width, window.bounds.height,
        window.onScreen ? "yes" : "no", display, scale, mode?.refreshRate ?? 0))

case "place":
    // Moves the app's window, so both apps can be measured on one display.
    guard arguments.count >= 5, let pid = Int32(arguments[2]), let x = Double(arguments[3]), let y = Double(arguments[4]) else {
        fail("usage: plumbench place <pid> <x> <y>")
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], let window = windows.first else { fail("no accessible window") }
    var point = CGPoint(x: x, y: y)
    guard let position = AXValueCreate(.cgPoint, &point),
          AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else { fail("could not move the window") }
    print("ok")

case "frames":
    // Diagnostic: how often frames arrive for a window, and whether its
    // pixels change while it is left alone.
    guard arguments.count >= 4, let pid = Int32(arguments[2]), let seconds = Double(arguments[3]),
          let window = mainWindow(of: pid, onScreenOnly: true) else { fail("usage: plumbench frames <pid> <seconds>") }
    let finished = DispatchSemaphore(value: 0)
    Task {
        do {
            let watcher = try await watch(window: window.id)
            usleep(300_000)
            let first = watcher.frameCount
            usleep(UInt32(seconds * 1e6))
            print(String(
                format: "%.0f frames/s, %dx%d, pixels unchanged for the last 200 ms: %@",
                Double(watcher.frameCount - first) / seconds, watcher.rowLength / 4, watcher.height,
                watcher.quietFor(200_000_000) ? "yes" : "no"))
            try? await watcher.stream?.stopCapture()
        } catch {
            print("capture failed: \(error.localizedDescription)")
        }
        finished.signal()
    }
    finished.wait()

case "latency":
    // Types a digit into the app and reports when the frame showing it was
    // displayed. Run `cat > /dev/null` in the terminal first, so the tty
    // echoes each key and nothing else draws.
    guard arguments.count >= 5, let pid = Int32(arguments[2]), let samples = Int(arguments[3]) else {
        fail("usage: plumbench latency <pid> <samples> <out.csv> [pause ms]")
    }
    // A fixed pause measures the first key after the terminal has sat idle;
    // without one the pauses are short and random, as in steady typing.
    let fixedPause = arguments.count >= 6 ? UInt32(arguments[5]) : nil
    guard activate(pid), let window = mainWindow(of: pid, onScreenOnly: true) else { fail("window is not frontmost and on screen") }
    let digit: CGKeyCode = 0x12 // "1": never held back for composition by an input method
    let killLine: CGKeyCode = 0x20 // "u", with control

    let finished = DispatchSemaphore(value: 0)
    var report = ""
    Task {
        do {
            let watcher = try await watch(window: window.id)
            usleep(500_000)

            // Find the rows where typed text shows up: type once and see what changed.
            let before = watcher.snapshot()
            postKey(pid, code: digit)
            usleep(500_000)
            let after = watcher.snapshot()
            let rowLength = watcher.rowLength
            guard rowLength > 0, before.count == after.count, !before.isEmpty else { fail("no frames from the window") }
            var changed: [Int] = []
            for row in 0..<(after.count / rowLength) where after[(row * rowLength)..<((row + 1) * rowLength)] != before[(row * rowLength)..<((row + 1) * rowLength)] {
                changed.append(row)
            }
            guard let top = changed.first, let bottom = changed.last else { fail("typing changed nothing on screen") }
            watcher.watch(rows: max(0, top - 2)..<min(watcher.height, bottom + 3))
            usleep(300_000)

            var lines = ["sample,latency_ms,arrival_ms"]
            var typed = 1
            var collected = 0
            var attempts = 0
            var notFront = 0
            var notQuiet = 0
            var timedOut = 0
            while collected < samples, attempts < samples * 3 {
                attempts += 1
                if typed >= 40 {
                    postKey(pid, code: killLine, flags: .maskControl)
                    typed = 0
                    usleep(300_000)
                }
                // A random pause, so key presses fall anywhere in the refresh cycle.
                usleep((fixedPause.map { $0 * 1000 } ?? 0) + UInt32.random(in: 120_000...380_000))
                // Something else is still drawing; its frame would be mistaken for ours.
                guard frontmostPID() == pid else {
                    notFront += 1
                    _ = activate(pid)
                    continue
                }
                guard watcher.quietFor(80_000_000) else {
                    notQuiet += 1
                    usleep(200_000)
                    continue
                }
                let start = now()
                let frame = watcher.change(after: start) { postKeyEvent(pid, code: digit, down: true) }
                postKeyEvent(pid, code: digit, down: false)
                typed += 1
                guard let frame else {
                    timedOut += 1
                    continue
                }
                guard frontmostPID() == pid else {
                    notFront += 1
                    continue
                }
                collected += 1
                lines.append(String(format: "%d,%.3f,%.3f", collected, frame.display, frame.arrival))
            }
            try? await watcher.stream?.stopCapture()
            try? lines.joined(separator: "\n").appending("\n").write(toFile: arguments[4], atomically: true, encoding: .utf8)
            report = "collected=\(collected) attempts=\(attempts) not_frontmost=\(notFront) not_quiet=\(notQuiet) timed_out=\(timedOut)"
        } catch {
            report = "capture failed: \(error.localizedDescription)"
        }
        finished.signal()
    }
    finished.wait()
    print(report)

default:
    fail("unknown command \(arguments[1])")
}
