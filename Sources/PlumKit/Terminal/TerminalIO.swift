import Darwin

/// Reading a terminal's output and writing its input, for the pty (in the
/// terminal host) and for the socket the app reads it from.
enum TerminalIO {
    /// Reads `fd` until it ends, handing what arrives to `deliver` in
    /// batches; `deliver` returns false to stop.
    ///
    /// A pty hands over at most 1 KB per read (whatever the baud rate), so
    /// heavy output is a race of thousands of small reads a second. Asleep in
    /// a blocking read, the thread is woken for each one; that wakeup set the
    /// speed. Here the descriptor is non-blocking: while output keeps coming
    /// the thread reads on without sleeping, and when nothing is there it
    /// reads again for up to 20 µs before it sleeps in poll(2). Reading `cat`
    /// of 100 MB of text on this Mac (M4 Pro): blocking reads 147-197 MB/s,
    /// this 317-345, at about the same CPU per byte. Idle, it costs one 20 µs
    /// look after each burst.
    ///
    /// With `batching`, what arrives in quick succession goes out as one
    /// batch: when a pause comes, the buffer fills, or the batch is 2 ms old.
    /// That suits passing output on (the host: one write, one wakeup of the
    /// app per batch); a reader that parses what it reads should take each
    /// read as it comes, or the pty sits full while a whole batch is parsed
    /// (scrolling output 60 MB/s batched, 81 not).
    static func readOutput(from fd: Int32, batching: Bool, deliver: (UnsafeRawBufferPointer) -> Bool) {
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var filled = 0
        var batchStarted: UInt64 = 0
        enum Got { case data, nothing, end }
        func readSome() -> Got {
            let n = read(fd, buffer.baseAddress! + filled, capacity - filled)
            if n > 0 {
                if filled == 0 { batchStarted = mach_absolute_time() }
                filled += n
                return .data
            }
            if n == 0 { return .end } // the other end closed
            return errno == EAGAIN || errno == EINTR ? .nothing : .end // EIO once the pty's last user is gone
        }
        func flush() -> Bool {
            guard filled > 0 else { return true }
            defer { filled = 0 }
            return deliver(UnsafeRawBufferPointer(rebasing: buffer[..<filled]))
        }
        while true {
            var got = readSome()
            if got == .nothing {
                // Look again for a moment before sleeping. By reading: a read
                // sees new output much sooner than poll(2) with no timeout
                // does (330 MB/s against 140 in the same test).
                let until = mach_absolute_time() &+ ticks.spin
                repeat { got = readSome() } while got == .nothing && mach_absolute_time() < until
            }
            switch got {
            case .data:
                if !batching || filled == capacity || mach_absolute_time() &- batchStarted >= ticks.maxBatchAge {
                    guard flush() else { return }
                }
            case .nothing:
                guard flush() else { return }
                var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                while poll(&waiting, 1, -1) < 0, errno == EINTR {}
            case .end:
                _ = flush()
                return
            }
        }
    }

    /// Writes all of `bytes`, waiting while the other end's buffer is full.
    /// False if the descriptor fails (the program or the app is gone).
    @discardableResult
    static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, -1)
            } else {
                return false
            }
        }
        return true
    }

    private static let ticks: (spin: UInt64, maxBatchAge: UInt64) = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let perMicrosecond = 1000 * UInt64(timebase.denom) / UInt64(timebase.numer)
        return (spin: 20 * perMicrosecond, maxBatchAge: 2000 * perMicrosecond)
    }()
}
