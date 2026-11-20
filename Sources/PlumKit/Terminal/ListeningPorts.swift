import Darwin

/// TCP ports that programs started in a tab listen on: a dev server the
/// user ran, or one an agent ran for them.
enum ListeningPorts {
    /// Ports listened on by `root` and everything under it. The agents' own
    /// sockets are left out: Claude Code keeps a local port for itself.
    static func under(_ root: pid_t) -> [UInt16] {
        var ports = Set<UInt16>()
        var queue = [root]
        var visited = 0
        while let pid = queue.popLast(), visited < 200 { // ponytail: a cap, not a cycle check; pids form a tree
            visited += 1
            queue += children(of: pid)
            if !isAgent(pid) { ports.formUnion(listening(pid)) }
        }
        return ports.sorted()
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 128)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func isAgent(_ pid: pid_t) -> Bool {
        TerminalSession.programName(pid).flatMap(TabProgram.init(rawValue:)).map { $0 != .terminal } ?? false
    }

    private static func listening(_ pid: pid_t) -> [UInt16] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var ports: [UInt16] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.append(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
        }
        return ports
    }
}
