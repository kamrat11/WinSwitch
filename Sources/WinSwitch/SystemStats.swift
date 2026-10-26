import AppKit
import Darwin
import IOKit
import SystemConfiguration

/// One process, as the Task Manager shows it. CPU is a share of the whole machine (0...1), like Windows.
struct ProcessSample {
    enum State { case running, sleeping, suspended, zombie, idle }

    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let state: State
    let translated: Bool        // an Intel binary running under Rosetta
    let nice: Int32
    let startTime: Date
    var threads: Int?
    var cpu: Double = 0
    var cpuTime: Double = 0     // seconds of CPU used since the process started
    var memory: UInt64?         // physical footprint (what Activity Monitor calls Memory); RSS for other users' processes
    var diskRate: Double = 0    // bytes per second, read + write
    var diskRead: UInt64 = 0
    var diskWritten: UInt64 = 0
    /// Only processes we may inspect have CPU, memory and disk figures from libproc; the rest come from ps.
    var detailed = false
}

struct MemoryStats {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int = 1       // 1 normal, 2 warning, 4 critical

    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct DiskStats {
    let id: UInt64
    let index: Int
    let name: String
    let bsdName: String
    let capacity: UInt64
    let solidState: Bool
    var readRate: Double = 0
    var writeRate: Double = 0
    var activeTime: Double = 0  // 0...1
    var responseMs: Double = 0
}

struct NetworkStats {
    let bsdName: String
    let displayName: String
    let kind: String            // Wi-Fi, Ethernet...
    var sendRate: Double = 0    // bits per second
    var receiveRate: Double = 0
    var linkSpeed: UInt64 = 0
    var ipv4: [String] = []
    var ipv6: [String] = []
}

struct GPUStats {
    let name: String
    let cores: Int
    var utilization: Double = 0 // 0...1
    var memoryInUse: UInt64 = 0
}

struct SystemSnapshot {
    var date = Date()
    /// False for the very first sample, which has no previous one to work out CPU and transfer rates from.
    var hasRates = false
    var processes: [ProcessSample] = []
    var cpuTotal: Double = 0
    var cpuPerCore: [Double] = []
    var memory = MemoryStats()
    var disks: [DiskStats] = []
    var networks: [NetworkStats] = []
    var gpus: [GPUStats] = []
    var threadCount = 0
    var loadAverage: [Double] = []
    var uptime: TimeInterval = 0
}

/// Static facts about the machine.
enum MachineInfo {
    static let cpuName = sysctlString("machdep.cpu.brand_string") ?? "CPU"
    static let logicalCPUs = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
    static let physicalCPUs = sysctlInt("hw.physicalcpu") ?? logicalCPUs
    static let performanceCores = sysctlInt("hw.perflevel0.physicalcpu")
    static let efficiencyCores = sysctlInt("hw.perflevel1.physicalcpu")
    static let l2Cache = sysctlInt("hw.perflevel0.l2cachesize") ?? sysctlInt("hw.l2cachesize")
    static let memorySize = UInt64(sysctlInt("hw.memsize") ?? 0)
    static let pageSize = UInt64(sysctlInt("hw.pagesize") ?? 16384)
    static let bootTime: Date = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static var userNames: [uid_t: String] = [:]
    private static let lock = NSLock()

    static func userName(_ uid: uid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        if let name = userNames[uid] { return name }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }
}

/// Takes the samples behind the Task Manager. Rates are worked out against the previous sample, so call
/// `sample()` at a steady pace, always from the same serial queue.
final class SystemSampler: @unchecked Sendable {
    private var lastDate: Date?
    private var lastCPUTime: [pid_t: (start: Date, seconds: Double)] = [:]
    private var lastDisk: [pid_t: UInt64] = [:]
    private var lastCoreTicks: [(busy: UInt64, total: UInt64)] = []
    private var lastDiskCounters: [UInt64: (read: UInt64, written: UInt64, time: UInt64, ops: UInt64)] = [:]
    private var lastNetCounters: [String: (sent: UInt64, received: UInt64)] = [:]
    private var paths: [pid_t: (start: Date, path: String)] = [:]
    private var argNames: [pid_t: (start: Date, name: String)] = [:]
    private var interfaceNames: [String: (name: String, kind: String)] = [:]
    private var interfaceNamesDate = Date.distantPast
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample() -> SystemSnapshot {
        let now = Date()
        let interval = lastDate.map { now.timeIntervalSince($0) } ?? 0
        lastDate = now

        var snapshot = SystemSnapshot(date: now, hasRates: interval > 0)
        snapshot.processes = processes(interval: interval)
        snapshot.threadCount = snapshot.processes.reduce(0) { $0 + ($1.threads ?? 0) }
        snapshot.cpuPerCore = coreUsage()
        snapshot.cpuTotal = snapshot.cpuPerCore.isEmpty ? 0 : snapshot.cpuPerCore.reduce(0, +) / Double(snapshot.cpuPerCore.count)
        snapshot.memory = memory()
        snapshot.disks = disks(interval: interval)
        snapshot.networks = networks(interval: interval)
        snapshot.gpus = gpus()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { snapshot.loadAverage = load }
        snapshot.uptime = now.timeIntervalSince(MachineInfo.bootTime)
        return snapshot
    }

    // MARK: Processes

    private func processes(interval: TimeInterval) -> [ProcessSample] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = list.count * stride
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        let count = size / stride

        let cores = Double(MachineInfo.logicalCPUs)
        var result: [ProcessSample] = []
        result.reserveCapacity(count)
        var undetailed: [Int] = []
        var seen = Set<pid_t>()
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for i in 0..<count {
            var kp = list[i]
            let pid = kp.kp_proc.p_pid
            guard pid >= 0, !seen.contains(pid) else { continue }
            seen.insert(pid)
            let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let tv = kp.kp_proc.p_un.__p_starttime
            let start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)

            var path = ""
            if let cached = paths[pid], cached.start == start {
                path = cached.path
            } else if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                path = String(cString: pathBuffer)
                paths[pid] = (start, path)
            }
            let state: ProcessSample.State
            switch Int32(kp.kp_proc.p_stat) {
            case SRUN: state = .running
            case SSTOP: state = .suspended
            case SZOMB: state = .zombie
            case SIDL: state = .idle
            default: state = .sleeping
            }
            var name = pid == 0 ? "kernel_task" : (path.isEmpty ? comm : (path as NSString).lastPathComponent)
            // Binaries named after their version (Claude Code's "2.1.308") go by the name they were started as.
            if name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) {
                if let cached = argNames[pid], cached.start == start { name = cached.name }
                else if let arg0 = Self.firstArgument(pid) {
                    name = (arg0 as NSString).lastPathComponent
                    argNames[pid] = (start, name)
                }
            }
            var p = ProcessSample(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid, name: name,
                                  path: path, state: state, translated: kp.kp_proc.p_flag & 0x0002_0000 != 0,
                                  nice: Int32(kp.kp_proc.p_nice), startTime: start)

            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            if ok {
                p.detailed = true
                p.cpuTime = Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9
                p.memory = usage.ri_phys_footprint
                p.diskRead = usage.ri_diskio_bytesread
                p.diskWritten = usage.ri_diskio_byteswritten
                let disk = p.diskRead + p.diskWritten
                if interval > 0, let last = lastDisk[pid], disk >= last { p.diskRate = Double(disk - last) / interval }
                lastDisk[pid] = disk
                var task = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    p.threads = Int(task.pti_threadnum)
                }
            } else {
                undetailed.append(result.count)
            }
            result.append(p)
        }

        // Processes of other users (root daemons): ps is setuid root and can read their CPU time and memory.
        if !undetailed.isEmpty {
            let ps = Self.psFigures()
            for index in undetailed {
                guard let figures = ps[result[index].pid] else { continue }
                result[index].cpuTime = figures.cpuTime
                result[index].memory = figures.rss
            }
        }

        for i in result.indices {
            let pid = result[i].pid
            if interval > 0, let last = lastCPUTime[pid], last.start == result[i].startTime {
                result[i].cpu = max(0, min(1, (result[i].cpuTime - last.seconds) / interval / cores))
            }
            lastCPUTime[pid] = (result[i].startTime, result[i].cpuTime)
        }
        // Forget processes that ended.
        if lastCPUTime.count > seen.count + 64 {
            lastCPUTime = lastCPUTime.filter { seen.contains($0.key) }
            lastDisk = lastDisk.filter { seen.contains($0.key) }
            paths = paths.filter { seen.contains($0.key) }
            argNames = argNames.filter { seen.contains($0.key) }
        }
        return result
    }

    /// argv[0] of one of our own processes (KERN_PROCARGS2: argc, the executable path, then the arguments).
    private static func firstArgument(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }   // executable path
        while i < size && buffer[i] == 0 { i += 1 }   // padding
        let start = i
        while i < size && buffer[i] != 0 { i += 1 }
        guard i > start else { return nil }
        return String(decoding: buffer[start..<i], as: UTF8.self)
    }

    /// pid -> (CPU seconds, resident bytes) for every process, from `ps`.
    private static func psFigures() -> [pid_t: (cpuTime: Double, rss: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,time=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var result: [pid_t: (Double, UInt64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]), let rss = UInt64(parts[2]) else { continue }
            result[pid] = (parseCPUTime(String(parts[1])), rss * 1024)
        }
        return result
    }

    /// "[days-]hours:minutes:seconds.cc" or "minutes:seconds.cc" -> seconds.
    private static func parseCPUTime(_ text: String) -> Double {
        var rest = Substring(text), days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var seconds = 0.0
        for part in rest.split(separator: ":") { seconds = seconds * 60 + (Double(part) ?? 0) }
        return days * 86400 + seconds
    }

    // MARK: CPU

    private func coreUsage() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            func value(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let busy = value(CPU_STATE_USER) + value(CPU_STATE_SYSTEM) + value(CPU_STATE_NICE)
            ticks.append((busy, busy + value(CPU_STATE_IDLE)))
        }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else { return ticks.map { _ in 0 } }
        return zip(ticks, lastCoreTicks).map { now, last in
            let total = now.total &- last.total
            return total == 0 ? 0 : min(1, Double(now.busy &- last.busy) / Double(total))
        }
    }

    // MARK: Memory

    private func memory() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = MachineInfo.memorySize
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let page = MachineInfo.pageSize
            let internalPages = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            stats.wired = UInt64(vm.wire_count) * page
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * page
            stats.free = UInt64(vm.free_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }
        stats.pressure = MachineInfo.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return stats
    }

    // MARK: Disks

    private var diskInfo: [UInt64: (name: String, bsd: String, capacity: UInt64, ssd: Bool)] = [:]

    private func disks(interval: TimeInterval) -> [DiskStats] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(id: UInt64, info: (name: String, bsd: String, capacity: UInt64, ssd: Bool), counters: (read: UInt64, written: UInt64, time: UInt64, ops: UInt64))] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            if diskInfo[id] == nil {
                let recursive = IOOptionBits(kIORegistryIterateRecursively)
                let parents = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                let characteristics = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Device Characteristics" as CFString,
                                                                      kCFAllocatorDefault, parents) as? [String: Any]
                let size = (IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Size" as CFString, kCFAllocatorDefault, recursive) as? NSNumber)?.uint64Value ?? 0
                let bsd = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault, recursive) as? String ?? ""
                let name = (characteristics?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Disk"
                let ssd = (characteristics?["Medium Type"] as? String) == "Solid State"
                diskInfo[id] = (name, bsd, size, ssd)
            }
            guard let info = diskInfo[id], info.capacity > 0 else { continue }
            func number(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            found.append((id, info, (number("Bytes (Read)"), number("Bytes (Write)"),
                                     number("Total Time (Read)") + number("Total Time (Write)"),
                                     number("Operations (Read)") + number("Operations (Write)"))))
        }
        found.sort { $0.info.bsd.localizedStandardCompare($1.info.bsd) == .orderedAscending }

        var result: [DiskStats] = []
        for (index, disk) in found.enumerated() {
            var stats = DiskStats(id: disk.id, index: index, name: disk.info.name, bsdName: disk.info.bsd,
                                  capacity: disk.info.capacity, solidState: disk.info.ssd)
            if interval > 0, let last = lastDiskCounters[disk.id] {
                stats.readRate = Double(disk.counters.read &- last.read) / interval
                stats.writeRate = Double(disk.counters.written &- last.written) / interval
                let busyNs = Double(disk.counters.time &- last.time)
                stats.activeTime = min(1, busyNs / (interval * 1e9))
                let ops = disk.counters.ops &- last.ops
                stats.responseMs = ops > 0 ? busyNs / Double(ops) / 1e6 : 0
            }
            lastDiskCounters[disk.id] = disk.counters
            result.append(stats)
        }
        return result
    }

    // MARK: Network

    private func networks(interval: TimeInterval) -> [NetworkStats] {
        if Date().timeIntervalSince(interfaceNamesDate) > 30 {
            interfaceNamesDate = Date()
            interfaceNames = [:]
            for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface).map({ $0 as String }) else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(interface).map { $0 as String } ?? ""
                let kind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? "Wi-Fi" : "Ethernet"
                let name = SCNetworkInterfaceGetLocalizedDisplayName(interface).map { $0 as String } ?? bsd
                interfaceNames[bsd] = (name, kind)
            }
        }

        // Addresses, from getifaddrs.
        var v4: [String: [String]] = [:], v6: [String: [String]] = [:]
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0, let first = addresses {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = cursor {
                defer { cursor = ifa.pointee.ifa_next }
                guard let addr = ifa.pointee.ifa_addr else { continue }
                let name = String(cString: ifa.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let family = Int32(addr.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6,
                      getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(cString: host)
                if family == AF_INET { v4[name, default: []].append(text) }
                else if !text.hasPrefix("fe80") { v6[name, default: []].append(text) }
            }
            freeifaddrs(first)
        }

        // Byte counters (64-bit) from the routing sysctl.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }
        var result: [NetworkStats] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) } // address messages are shorter than if_msghdr
                guard Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let bsd = String(cString: nameBuffer)
                guard let known = interfaceNames[bsd], message.ifm_flags & IFF_UP != 0,
                      !(v4[bsd] ?? []).isEmpty || !(v6[bsd] ?? []).isEmpty else { continue }
                let sent = message.ifm_data.ifi_obytes, received = message.ifm_data.ifi_ibytes
                var stats = NetworkStats(bsdName: bsd, displayName: known.name, kind: known.kind)
                stats.linkSpeed = message.ifm_data.ifi_baudrate
                stats.ipv4 = v4[bsd] ?? []
                stats.ipv6 = v6[bsd] ?? []
                if interval > 0, let last = lastNetCounters[bsd] {
                    stats.sendRate = Double(sent &- last.sent) * 8 / interval
                    stats.receiveRate = Double(received &- last.received) * 8 / interval
                }
                lastNetCounters[bsd] = (sent, received)
                result.append(stats)
            }
        }
        return result.sorted { ($0.kind == "Wi-Fi" ? 1 : 0, $0.bsdName) < ($1.kind == "Wi-Fi" ? 1 : 0, $1.bsdName) }
    }

    // MARK: GPU

    private func gpus() -> [GPUStats] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [GPUStats] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            let name = dict["model"] as? String ?? (dict["model"] as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "GPU"
            var gpu = GPUStats(name: name.trimmingCharacters(in: .controlCharacters), cores: (dict["gpu-core-count"] as? NSNumber)?.intValue ?? 0)
            gpu.utilization = Double((perf["Device Utilization %"] as? NSNumber)?.intValue ?? 0) / 100
            gpu.memoryInUse = (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            result.append(gpu)
        }
        return result
    }
}

// MARK: Formatting

enum Format {
    static func percent(_ fraction: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", fraction * 100)
    }

    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v < 1024 { return "\(value) B" }
        if v < 1024 * 1024 { return String(format: "%.1f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / 1024 / 1024) }
        if v < 1024 * 1024 * 1024 * 1024 { return String(format: "%.1f GB", v / 1024 / 1024 / 1024) }
        return String(format: "%.1f TB", v / 1024 / 1024 / 1024 / 1024)
    }

    /// Disk speeds, Windows style: "0 MB/s", "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSecond / 1024) }
        if bytesPerSecond < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024) }
        return String(format: "%.1f GB/s", bytesPerSecond / 1024 / 1024 / 1024)
    }

    /// Network speeds in bits, like Windows: "120 Kbps", "4.5 Mbps".
    static func bits(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond < 1000 { return String(format: "%.0f bps", bitsPerSecond) }
        if bitsPerSecond < 1_000_000 { return String(format: "%.0f Kbps", bitsPerSecond / 1000) }
        if bitsPerSecond < 1_000_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        return String(format: "%.1f Gbps", bitsPerSecond / 1_000_000_000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d:%02d", s / 86400, s / 3600 % 24, s / 60 % 60, s % 60)
    }

    static func cpuTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
