import AppKit

/// Performance tab: CPU, memory, disks, network adapters and GPU, each with a 60-second graph.
@MainActor
final class PerformancePage: TMPage, NSTableViewDataSource, NSTableViewDelegate {
    override var title: String { "Performance" }
    override var symbol: String { "waveform.path.ecg" }
    override var searchable: Bool { false }
    override var actions: [NSView] { [runButton] }

    private enum Resource: Hashable {
        case cpu, memory, disk(UInt64), network(String), gpu(Int)
    }

    private let capacity = 60
    private var cpuHistory: [Double] = []
    private var coreHistory: [[Double]] = []
    private var memoryHistory: [Double] = []
    private var diskActive: [UInt64: [Double]] = [:]
    private var diskRead: [UInt64: [Double]] = [:]
    private var diskWrite: [UInt64: [Double]] = [:]
    private var netSend: [String: [Double]] = [:]
    private var netReceive: [String: [Double]] = [:]
    private var gpuHistory: [Int: [Double]] = [:]
    private var snapshot = SystemSnapshot()

    private var resources: [Resource] = []
    private var selected: Resource = .cpu
    private let list = NSTableView()
    private let detail = NSView()
    private lazy var runButton = TMUI.button("Run new task", symbol: "plus.app", target: self, action: #selector(runNewTask))

    // Detail views, rebuilt when the selection changes.
    private var graphs: [GraphView] = []
    private var coreGrid: NSGridView?
    private var values: [String: NSTextField] = [:]
    private var captions: [String: NSTextField] = [:]
    private var memoryBar: MemoryBar?
    private let cpuMode = NSSegmentedControl(labels: ["Overall utilization", "Logical processors"], trackingMode: .selectOne, target: nil, action: nil)

    override init() {
        super.init()
        list.addTableColumn(NSTableColumn(identifier: .init("resource")))
        list.headerView = nil
        list.rowHeight = 62
        list.style = .plain
        list.dataSource = self
        list.delegate = self
        list.backgroundColor = .clear
        list.selectionHighlightStyle = .regular
        let listScroll = TMUI.scroll(list)
        listScroll.hasHorizontalScroller = false
        listScroll.drawsBackground = false

        cpuMode.selectedSegment = UserDefaults.standard.integer(forKey: "taskManagerCPUMode")
        cpuMode.target = self
        cpuMode.action = #selector(cpuModeChanged)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listScroll)
        view.addSubview(divider)
        view.addSubview(detail)
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            listScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 230),
            divider.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            detail.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    @objc private func runNewTask() { RunDialog.shared.show() }

    // MARK: History

    private func push(_ value: Double, to array: inout [Double]) {
        array.append(value)
        if array.count > capacity { array.removeFirst(array.count - capacity) }
    }

    /// Called on every sample, also while another page is showing, so the graphs are full when you look.
    func record(_ snapshot: SystemSnapshot) {
        guard snapshot.hasRates, !snapshot.processes.isEmpty else { return }
        self.snapshot = snapshot
        push(snapshot.cpuTotal, to: &cpuHistory)
        if coreHistory.count != snapshot.cpuPerCore.count { coreHistory = snapshot.cpuPerCore.map { _ in [] } }
        for (i, value) in snapshot.cpuPerCore.enumerated() { push(value, to: &coreHistory[i]) }
        push(snapshot.memory.usedFraction, to: &memoryHistory)
        for disk in snapshot.disks {
            push(disk.activeTime, to: &diskActive[disk.id, default: []])
            push(disk.readRate, to: &diskRead[disk.id, default: []])
            push(disk.writeRate, to: &diskWrite[disk.id, default: []])
        }
        for net in snapshot.networks {
            push(net.sendRate, to: &netSend[net.bsdName, default: []])
            push(net.receiveRate, to: &netReceive[net.bsdName, default: []])
        }
        for (i, gpu) in snapshot.gpus.enumerated() { push(gpu.utilization, to: &gpuHistory[i, default: []]) }
    }

    override func update(_ snapshot: SystemSnapshot) {
        guard !snapshot.processes.isEmpty else { return }
        var newResources: [Resource] = [.cpu, .memory]
        newResources += snapshot.disks.map { .disk($0.id) }
        newResources += snapshot.networks.map { .network($0.bsdName) }
        newResources += snapshot.gpus.indices.map { .gpu($0) }
        if newResources != resources {
            resources = newResources
            list.reloadData()
            if !resources.contains(selected) { selected = .cpu }
            list.selectRowIndexes([resources.firstIndex(of: selected) ?? 0], byExtendingSelection: false)
            buildDetail()
        } else {
            for row in 0..<resources.count {
                if let cell = list.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResourceCell { fill(cell, resources[row]) }
            }
        }
        if graphs.isEmpty && coreGrid == nil { buildDetail() }
        updateDetail()
    }

    // MARK: Resource list

    func numberOfRows(in tableView: NSTableView) -> Int { resources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("resourceCell"), owner: nil) as? ResourceCell ?? ResourceCell()
        fill(cell, resources[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0, list.selectedRow < resources.count, resources[list.selectedRow] != selected else { return }
        selected = resources[list.selectedRow]
        buildDetail()
        updateDetail()
    }

    private func fill(_ cell: ResourceCell, _ resource: Resource) {
        let s = snapshot
        switch resource {
        case .cpu:
            cell.set(title: "CPU", subtitle: Format.percent(s.cpuTotal, decimals: 0), color: TMColor.cpu, series: [cpuHistory], auto: false)
        case .memory:
            let m = s.memory
            cell.set(title: "Memory", subtitle: String(format: "%.1f/%.0f GB (%.0f%%)", Double(m.used) / 1_073_741_824,
                                                       Double(m.total) / 1_073_741_824, m.usedFraction * 100),
                     color: TMColor.memory, series: [memoryHistory], auto: false)
        case .disk(let id):
            guard let d = s.disks.first(where: { $0.id == id }) else { return }
            cell.set(title: "Disk \(d.index) (\(d.bsdName))", subtitle: "\(d.solidState ? "SSD" : "Disk")\n\(Format.percent(d.activeTime, decimals: 0))",
                     color: TMColor.disk, series: [diskActive[id] ?? []], auto: false)
        case .network(let bsd):
            guard let n = s.networks.first(where: { $0.bsdName == bsd }) else { return }
            cell.set(title: n.kind == "Wi-Fi" ? "Wi-Fi" : n.displayName,
                     subtitle: "\(n.bsdName)\nS: \(Format.bits(n.sendRate)) R: \(Format.bits(n.receiveRate))",
                     color: TMColor.network, series: [netReceive[bsd] ?? [], netSend[bsd] ?? []], auto: true)
        case .gpu(let i):
            guard i < s.gpus.count else { return }
            cell.set(title: "GPU \(i)", subtitle: "\(s.gpus[i].name)\n\(Format.percent(s.gpus[i].utilization, decimals: 0))",
                     color: TMColor.gpu, series: [gpuHistory[i] ?? []], auto: false)
        }
    }

    // MARK: Detail

    @objc private func cpuModeChanged() {
        UserDefaults.standard.set(cpuMode.selectedSegment, forKey: "taskManagerCPUMode")
        buildDetail()
        updateDetail()
    }

    private func buildDetail() {
        detail.subviews.forEach { $0.removeFromSuperview() }
        graphs = []
        coreGrid = nil
        values = [:]
        captions = [:]
        memoryBar = nil

        let s = snapshot
        var heading = "", device = ""
        var color = TMColor.cpu
        var graphSpecs: [(caption: String, key: String, auto: Bool)] = []
        var big: [(String, String)] = []
        var info: [(String, String)] = []

        switch selected {
        case .cpu:
            heading = "CPU"; device = MachineInfo.cpuName; color = TMColor.cpu
            if cpuMode.selectedSegment == 0 { graphSpecs = [("% Utilization", "g0", false)] }
            big = [("Utilization", "util"), ("Processes", "procs"), ("Threads", "threads"), ("Up time", "uptime"), ("Load average", "load")]
            var lines: [(String, String)] = []
            if let p = MachineInfo.performanceCores { lines.append(("Performance cores:", String(p))) }
            if let e = MachineInfo.efficiencyCores { lines.append(("Efficiency cores:", String(e))) }
            lines.append(("Cores:", String(MachineInfo.physicalCPUs)))
            lines.append(("Logical processors:", String(MachineInfo.logicalCPUs)))
            if let l2 = MachineInfo.l2Cache { lines.append(("L2 cache:", Format.bytes(UInt64(l2)))) }
            #if arch(arm64)
            lines.append(("Architecture:", "Apple silicon (arm64)"))
            #else
            lines.append(("Architecture:", "Intel (x86_64)"))
            #endif
            info = lines
        case .memory:
            heading = "Memory"; device = String(format: "%.0f GB", Double(MachineInfo.memorySize) / 1_073_741_824); color = TMColor.memory
            graphSpecs = [("Memory usage", "g0", false)]
            big = [("In use (Compressed)", "inuse"), ("Available", "avail"), ("Swap used", "swap"), ("Cached", "cached"),
                   ("Wired", "wired"), ("App memory", "app")]
            info = [("Total:", Format.bytes(MachineInfo.memorySize)), ("Memory pressure:", ""), ("Page size:", Format.bytes(MachineInfo.pageSize))]
        case .disk(let id):
            let d = s.disks.first { $0.id == id }
            heading = "Disk \(d?.index ?? 0) (\(d?.bsdName ?? ""))"; device = d?.name ?? ""; color = TMColor.disk
            graphSpecs = [("Active time", "g0", false), ("Disk transfer rate", "g1", true)]
            big = [("Active time", "active"), ("Average response time", "response"), ("Read speed", "read"), ("Write speed", "write")]
            info = [("Capacity:", Format.bytes(d?.capacity ?? 0)), ("Type:", d?.solidState == true ? "SSD" : "HDD"), ("Device:", d?.bsdName ?? "")]
        case .network(let bsd):
            let n = s.networks.first { $0.bsdName == bsd }
            heading = n?.kind == "Wi-Fi" ? "Wi-Fi" : (n?.displayName ?? "Ethernet"); device = n?.displayName ?? bsd; color = TMColor.network
            graphSpecs = [("Throughput", "g0", true)]
            big = [("Send", "send"), ("Receive", "receive")]
            info = [("Adapter name:", n?.displayName ?? ""), ("Interface:", bsd), ("Connection type:", n?.kind ?? ""),
                    ("IPv4 address:", n?.ipv4.joined(separator: ", ") ?? ""), ("IPv6 address:", n?.ipv6.first ?? ""),
                    ("Link speed:", (n?.linkSpeed ?? 0) > 0 ? Format.bits(Double(n!.linkSpeed)) : "")]
        case .gpu(let i):
            let g = i < s.gpus.count ? s.gpus[i] : nil
            heading = "GPU"; device = g?.name ?? ""; color = TMColor.gpu
            graphSpecs = [("Utilization", "g0", false)]
            big = [("Utilization", "util"), ("GPU memory in use", "gpumem")]
            info = [("Name:", g?.name ?? ""), ("GPU cores:", g.map { String($0.cores) } ?? "")]
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(stack)

        let headingLabel = TMUI.label(heading, size: 26, weight: .semibold)
        let deviceLabel = TMUI.label(device, size: 15)
        deviceLabel.alignment = .right
        let headerViews: [NSView] = selected == .cpu ? [headingLabel, NSView(), cpuMode, deviceLabel] : [headingLabel, NSView(), deviceLabel]
        let header = NSStackView(views: headerViews)
        header.spacing = 14
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        var graphViews: [NSView] = []
        for spec in graphSpecs {
            let captionRow = captionRow(left: spec.caption, rightKey: spec.key + "max", right: spec.auto ? "" : (selected == .memory ? device : "100%"))
            stack.addArrangedSubview(captionRow)
            captionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let graph = GraphView()
            graph.color = color
            graph.autoScale = spec.auto
            graph.capacity = capacity
            graph.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(graph)
            graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            graph.setContentHuggingPriority(.defaultLow, for: .vertical)
            graphs.append(graph)
            graphViews.append(graph)
        }
        if selected == .cpu && cpuMode.selectedSegment == 1 {
            let captionRow = captionRow(left: "% Utilization of each logical processor", rightKey: "", right: "100%")
            stack.addArrangedSubview(captionRow)
            captionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let count = max(snapshot.cpuPerCore.count, MachineInfo.logicalCPUs)
            let columns = Int(ceil(sqrt(Double(count) * 1.6)))
            var rows: [[NSView]] = []
            for start in stride(from: 0, to: count, by: columns) {
                var row: [NSView] = []
                for _ in start..<min(start + columns, count) {
                    let g = GraphView()
                    g.color = TMColor.cpu
                    g.showGrid = false
                    g.capacity = capacity
                    graphs.append(g)
                    row.append(g)
                }
                while row.count < columns { row.append(NSView()) }
                rows.append(row)
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 4
            grid.columnSpacing = 4
            grid.translatesAutoresizingMaskIntoConstraints = false
            for c in 0..<grid.numberOfColumns { grid.column(at: c).xPlacement = .fill }
            for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .fill }
            stack.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            grid.setContentHuggingPriority(.defaultLow, for: .vertical)
            // Equal cell sizes.
            if let first = graphs.first {
                for g in graphs.dropFirst() {
                    g.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
                    g.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
                }
            }
            coreGrid = grid
            graphViews.append(grid)
        }
        if graphViews.count > 1 {
            for g in graphViews.dropFirst() { g.heightAnchor.constraint(equalTo: graphViews[0].heightAnchor).isActive = true }
        }
        let footer = captionRow(left: "60 seconds", rightKey: "", right: "0")
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if selected == .memory {
            let caption = TMUI.label("Memory composition", size: 11, secondary: true)
            stack.addArrangedSubview(caption)
            let bar = MemoryBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 36).isActive = true
            stack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            memoryBar = bar
        }

        // Stats: big numbers on the left, details on the right.
        var bigRows: [[NSView]] = []
        var pairs: [NSView] = []
        for (title, key) in big {
            let value = TMUI.label("", size: 19)
            value.font = .monospacedDigitSystemFont(ofSize: 19, weight: .regular)
            values[key] = value
            let block = NSStackView(views: [TMUI.label(title, size: 11, secondary: true), value])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 1
            pairs.append(block)
            if pairs.count == 3 { bigRows.append(pairs); pairs = [] }
        }
        if !pairs.isEmpty { while pairs.count < 3 { pairs.append(NSView()) }; bigRows.append(pairs) }
        let bigGrid = NSGridView(views: bigRows)
        bigGrid.rowSpacing = 10
        bigGrid.columnSpacing = 26

        let infoGrid = NSGridView(views: info.map { pair -> [NSView] in
            let value = TMUI.label(pair.1, size: 12)
            values["info:" + pair.0] = value
            return [TMUI.label(pair.0, size: 12, secondary: true), value]
        })
        infoGrid.rowSpacing = 5
        infoGrid.columnSpacing = 14

        let stats = NSStackView(views: [bigGrid, infoGrid])
        stats.alignment = .top
        stats.spacing = 40
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(stats)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            stack.topAnchor.constraint(equalTo: detail.topAnchor),
            stack.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        if let first = graphViews.first {
            first.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
    }

    private func captionRow(left: String, rightKey: String, right: String) -> NSStackView {
        let l = TMUI.label(left, size: 11, secondary: true)
        let r = TMUI.label(right, size: 11, secondary: true)
        r.alignment = .right
        if !rightKey.isEmpty { captions[rightKey] = r }
        return NSStackView(views: [l, NSView(), r])
    }

    private func set(_ key: String, _ text: String) { values[key]?.stringValue = text }

    private func updateDetail() {
        let s = snapshot
        guard !s.processes.isEmpty else { return }
        switch selected {
        case .cpu:
            if cpuMode.selectedSegment == 0 {
                graphs.first?.series = [cpuHistory]
            } else {
                for (i, g) in graphs.enumerated() where i < coreHistory.count { g.series = [coreHistory[i]] }
            }
            set("util", Format.percent(s.cpuTotal, decimals: 0))
            set("procs", String(s.processes.count))
            set("threads", String(s.threadCount))
            set("uptime", Format.duration(s.uptime))
            set("load", s.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
        case .memory:
            let m = s.memory
            graphs.first?.series = [memoryHistory]
            memoryBar?.memory = m
            set("inuse", String(format: "%.1f GB (%.1f GB)", Double(m.used) / 1_073_741_824, Double(m.compressed) / 1_073_741_824))
            set("avail", Format.bytes(m.available))
            set("swap", Format.bytes(m.swapUsed))
            set("cached", Format.bytes(m.cached))
            set("wired", Format.bytes(m.wired))
            set("app", Format.bytes(m.app))
            let pressure = m.pressure >= 4 ? "Critical" : m.pressure >= 2 ? "Warning" : "Normal"
            values["info:Memory pressure:"]?.stringValue = pressure
            values["info:Memory pressure:"]?.textColor = m.pressure >= 4 ? .systemRed : m.pressure >= 2 ? .systemOrange : .systemGreen
        case .disk(let id):
            guard let d = s.disks.first(where: { $0.id == id }) else { return }
            if graphs.count >= 2 {
                graphs[0].series = [diskActive[id] ?? []]
                graphs[1].series = [diskRead[id] ?? [], diskWrite[id] ?? []]
                captions["g1max"]?.stringValue = Format.rate(GraphView.niceCeiling(max(1024 * 1024, (graphs[1].series.flatMap { $0 }.max() ?? 0))))
            }
            set("active", Format.percent(d.activeTime, decimals: 0))
            set("response", String(format: "%.1f ms", d.responseMs))
            set("read", Format.rate(d.readRate))
            set("write", Format.rate(d.writeRate))
        case .network(let bsd):
            guard let n = s.networks.first(where: { $0.bsdName == bsd }) else { return }
            let series = [netReceive[bsd] ?? [], netSend[bsd] ?? []]
            graphs.first?.series = series
            captions["g0max"]?.stringValue = Format.bits(GraphView.niceCeiling(max(1, series.flatMap { $0 }.max() ?? 0)))
            set("send", Format.bits(n.sendRate))
            set("receive", Format.bits(n.receiveRate))
            values["info:IPv4 address:"]?.stringValue = n.ipv4.joined(separator: ", ")
        case .gpu(let i):
            guard i < s.gpus.count else { return }
            graphs.first?.series = [gpuHistory[i] ?? []]
            set("util", Format.percent(s.gpus[i].utilization, decimals: 0))
            set("gpumem", Format.bytes(s.gpus[i].memoryInUse))
        }
    }
}

/// A row of the resource list: a small graph with the resource name and its current value.
final class ResourceCell: NSTableCellView {
    private let graph = GraphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("resourceCell")
        graph.showGrid = false
        graph.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graph)
        addSubview(text)
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            graph.centerYAnchor.constraint(equalTo: centerYAnchor),
            graph.widthAnchor.constraint(equalToConstant: 62),
            graph.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, subtitle: String, color: NSColor, series: [[Double]], auto: Bool) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        graph.color = color
        graph.autoScale = auto
        graph.series = series
    }
}

/// The "Memory composition" bar: in use, wired, compressed, cached and free.
final class MemoryBar: NSView {
    var memory = MemoryStats() { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        guard memory.total > 0 else { return }
        let parts: [(UInt64, CGFloat)] = [(memory.app, 0.45), (memory.wired, 0.65), (memory.compressed, 0.3), (memory.cached, 0.12)]
        var x = rect.minX
        for (value, alpha) in parts {
            let width = rect.width * CGFloat(Double(value) / Double(memory.total))
            TMColor.memory.withAlphaComponent(alpha).setFill()
            NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
            TMColor.memory.withAlphaComponent(0.8).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x + width, y: rect.minY), to: NSPoint(x: x + width, y: rect.maxY))
            x += width
        }
        TMColor.memory.withAlphaComponent(0.8).setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    override var toolTip: String? {
        get {
            "In use: \(Format.bytes(memory.app)) apps, \(Format.bytes(memory.wired)) wired, \(Format.bytes(memory.compressed)) compressed\n"
                + "Cached: \(Format.bytes(memory.cached))\nFree: \(Format.bytes(memory.free))"
        }
        set {}
    }
}
