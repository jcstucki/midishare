import Cocoa
import CoreMIDI

// MARK: - Protocol (inline to avoid module deps for .app bundle)
// TCP framing: each message is a 4-byte length prefix (big-endian) followed by the payload.
// Payload layout:
//   [0..3]  magic "MSHR" (4 bytes)
//   [4..7]  sequence number (UInt32, big-endian)
//   [8]     number of messages in this packet (UInt8, 1-42)
//   [9..]   messages, each 3 bytes: status, data1, data2

let kMIDISharePort: UInt16 = 17249
let kBonjourServiceType = "_midishare._tcp"
let kBonjourServiceDomain = "local."

// MARK: - TCP Server

class TCPServer {
    private var listenSocket: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "midishare.tcp.accept", qos: .userInitiated)
    private let clientsLock = NSLock()
    private var clientSockets = [Int32]()
    private var sequence: UInt32 = 0
    private var running = false
    var onClientCountChanged: ((Int) -> Void)?

    func start(port: UInt16) -> Bool {
        listenSocket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenSocket >= 0 else { return false }

        var reuse: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenSocket, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(listenSocket); listenSocket = -1; return false }

        guard listen(listenSocket, 8) == 0 else { close(listenSocket); listenSocket = -1; return false }

        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenSocket, sa, &addrLen)
                }
            }
            guard clientFd >= 0 else { continue }

            // Disable Nagle for low latency, suppress SIGPIPE on broken connections
            var noDelay: Int32 = 1
            setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            clientsLock.lock()
            clientSockets.append(clientFd)
            let count = clientSockets.count
            clientsLock.unlock()

            DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(count) }
        }
    }

    var clientCount: Int {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return clientSockets.count
    }

    func sendRaw(_ bytes: [UInt8]) {
        clientsLock.lock()
        var deadClients = [Int]()
        for (i, fd) in clientSockets.enumerated() {
            var totalSent = 0
            var failed = false
            while totalSent < bytes.count {
                let result = bytes.withUnsafeBufferPointer { buf in
                    Darwin.write(fd, buf.baseAddress! + totalSent, bytes.count - totalSent)
                }
                if result <= 0 { failed = true; break }
                totalSent += result
            }
            if failed {
                close(fd)
                deadClients.append(i)
            }
        }
        for i in deadClients.reversed() {
            clientSockets.remove(at: i)
        }
        let count = clientSockets.count
        clientsLock.unlock()

        if !deadClients.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onClientCountChanged?(count) }
        }
    }

    func stop() {
        running = false
        if listenSocket >= 0 { close(listenSocket); listenSocket = -1 }
        clientsLock.lock()
        for fd in clientSockets { close(fd) }
        clientSockets.removeAll()
        clientsLock.unlock()
    }
}

// MARK: - MIDI Source Info

struct MIDISourceInfo {
    let index: Int
    let name: String
    let endpoint: MIDIEndpointRef
    var enabled: Bool
}

func midiTypeName(_ status: UInt8) -> String {
    switch status & 0xF0 {
    case 0xB0: return "CC"
    case 0x90: return "NoteOn"
    case 0x80: return "NoteOff"
    case 0xE0: return "PitchBend"
    case 0xC0: return "PgmChg"
    case 0xD0: return "ChanPres"
    case 0xA0: return "PolyAT"
    default: return "0x\(String(status, radix: 16))"
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NetServiceDelegate {

    var window: NSWindow!
    var tableView: NSTableView!
    var logView: NSTextView!
    var startButton: NSButton!
    var statusLabel: NSTextField!
    var refreshButton: NSButton!

    var sources = [MIDISourceInfo]()
    var tcpServer = TCPServer()
    var bonjourService: NetService?
    var midiClient: MIDIClientRef = 0
    var inputPort: MIDIPortRef = 0
    var broadcasting = false
    var messageCount: UInt64 = 0
    var logLines = 0
    let maxLogLines = 200

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        refreshSources()
    }

    func buildUI() {
        let w: CGFloat = 520, h: CGFloat = 480
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MIDIShare Server"
        window.minSize = NSSize(width: 400, height: 360)
        window.center()

        let content = window.contentView!
        content.wantsLayer = true

        // Header
        let titleLabel = makeLabel("MIDI Sources", size: 13, bold: true)
        titleLabel.frame = NSRect(x: 16, y: h - 36, width: 200, height: 20)
        titleLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(titleLabel)

        refreshButton = NSButton(frame: NSRect(x: w - 90, y: h - 40, width: 74, height: 24))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.setButtonType(.momentaryPushIn)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(refreshButton)

        // Table scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: h - 200, width: w - 32, height: 156))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .minYMargin]

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        let checkCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkCol.width = 30; checkCol.minWidth = 30; checkCol.maxWidth = 30
        tableView.addTableColumn(checkCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.width = 420; nameCol.minWidth = 100
        nameCol.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameCol)

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        content.addSubview(scrollView)

        // Controls row
        let cy = h - 236
        startButton = NSButton(frame: NSRect(x: 16, y: cy, width: 120, height: 28))
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.setButtonType(.momentaryPushIn)
        startButton.target = self
        startButton.action = #selector(toggleBroadcast)
        startButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(startButton)

        statusLabel = makeLabel("Stopped", size: 12, bold: false)
        statusLabel.frame = NSRect(x: 146, y: cy + 4, width: w - 170, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(statusLabel)

        // Log label
        let logLabel = makeLabel("Log", size: 13, bold: true)
        logLabel.frame = NSRect(x: 16, y: cy - 28, width: 200, height: 20)
        logLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(logLabel)

        let clearButton = NSButton(frame: NSRect(x: w - 74, y: cy - 30, width: 58, height: 24))
        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.target = self
        clearButton.action = #selector(clearLog)
        clearButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(clearButton)

        // Log view
        let logScroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: w - 32, height: cy - 48))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.autoresizingMask = [.width, .height]

        logView = NSTextView(frame: logScroll.contentView.bounds)
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.userFixedPitchFont(ofSize: 11)!
        logView.backgroundColor = NSColor(white: 0.13, alpha: 1.0)
        logView.textColor = NSColor(white: 0.85, alpha: 1.0)
        logView.autoresizingMask = [.width, .height]
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logScroll.documentView = logView
        content.addSubview(logScroll)

        window.makeKeyAndOrderFront(nil)
    }

    func makeLabel(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return l
    }

    // MARK: - MIDI

    func refreshSources() {
        sources.removeAll()
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let ep = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cfName)
            let name = cfName?.takeRetainedValue() as String? ?? "Unknown"
            sources.append(MIDISourceInfo(index: i, name: name, endpoint: ep, enabled: true))
        }
        tableView.reloadData()
        if sources.isEmpty {
            appendLog("No MIDI sources found. Connect a controller and click Refresh.")
        } else {
            appendLog("Found \(sources.count) MIDI source(s).")
        }
    }

    @objc func refreshTapped() {
        guard !broadcasting else {
            appendLog("Stop broadcasting before refreshing.")
            return
        }
        refreshSources()
    }

    @objc func toggleBroadcast() {
        if broadcasting { stopBroadcasting() } else { startBroadcasting() }
    }

    func startBroadcasting() {
        let selected = sources.filter { $0.enabled }
        if selected.isEmpty {
            appendLog("No sources selected.")
            return
        }

        // Create MIDI client
        var status = MIDIClientCreateWithBlock("MIDIShare Server" as CFString, &midiClient) { [weak self] notif in
            if notif.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.appendLog("MIDI setup changed.") }
            }
        }
        guard status == noErr else {
            appendLog("Failed to create MIDI client: \(status)")
            return
        }

        status = MIDIInputPortCreateWithBlock(midiClient, "Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.handleMIDIPackets(packetList)
        }
        guard status == noErr else {
            appendLog("Failed to create MIDI input port: \(status)")
            MIDIClientDispose(midiClient)
            return
        }

        for src in selected {
            let cs = MIDIPortConnectSource(inputPort, src.endpoint, nil)
            if cs != noErr {
                appendLog("Warning: couldn't connect \(src.name)")
            }
        }

        // Start TCP server
        tcpServer = TCPServer()
        tcpServer.onClientCountChanged = { [weak self] count in
            self?.updateClientCount(count)
        }
        guard tcpServer.start(port: kMIDISharePort) else {
            appendLog("Failed to start TCP server on port \(kMIDISharePort).")
            MIDIPortDispose(inputPort); inputPort = 0
            MIDIClientDispose(midiClient); midiClient = 0
            return
        }

        // Bonjour
        let serviceName = Host.current().localizedName ?? "MIDIShare Server"
        bonjourService = NetService(domain: kBonjourServiceDomain, type: kBonjourServiceType,
                                    name: serviceName, port: Int32(kMIDISharePort))
        bonjourService?.delegate = self
        bonjourService?.publish()

        broadcasting = true
        messageCount = 0
        startButton.title = "Stop"
        statusLabel.stringValue = "Listening on port \(kMIDISharePort) (0 clients)"
        statusLabel.textColor = NSColor.systemGreen
        refreshButton.isEnabled = false
        appendLog("Started broadcasting \(selected.count) source(s) via TCP.")
    }

    func stopBroadcasting() {
        bonjourService?.stop()
        bonjourService = nil
        tcpServer.stop()

        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if midiClient != 0 { MIDIClientDispose(midiClient); midiClient = 0 }

        broadcasting = false
        startButton.title = "Start"
        statusLabel.stringValue = "Stopped"
        statusLabel.textColor = .secondaryLabelColor
        refreshButton.isEnabled = true
        appendLog("Stopped. \(messageCount) messages sent.")
    }

    func updateClientCount(_ count: Int) {
        guard broadcasting else { return }
        let plural = count == 1 ? "client" : "clients"
        statusLabel.stringValue = "Listening on port \(kMIDISharePort) (\(count) \(plural))"
        appendLog("\(count) \(plural) connected.")
    }

    func handleMIDIPackets(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        let listRaw = UnsafeRawPointer(packetListPtr)
        let numPackets = listRaw.load(as: UInt32.self)

        let packetFieldOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        let lengthFieldOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length)!
        let dataFieldOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!

        var curPtr = listRaw.advanced(by: packetFieldOffset)

        for _ in 0..<numPackets {
            let length = Int(curPtr.advanced(by: lengthFieldOffset).load(as: UInt16.self))
            let bytesPtr = curPtr.advanced(by: dataFieldOffset).assumingMemoryBound(to: UInt8.self)

            // Copy MIDI bytes out immediately while pointer is still valid
            var midiBytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length { midiBytes[i] = bytesPtr[i] }

            var offset = 0
            while offset < length {
                let b0 = midiBytes[offset]
                if b0 >= 0xF8 { offset += 1; continue }

                let msgLen: Int
                switch b0 & 0xF0 {
                case 0x80, 0x90, 0xA0, 0xB0, 0xE0: msgLen = 3
                case 0xC0, 0xD0: msgLen = 2
                default: offset += 1; continue
                }
                guard offset + msgLen <= length else { break }

                let b1 = midiBytes[offset + 1]
                let b2: UInt8 = msgLen >= 3 ? midiBytes[offset + 2] : 0

                // Build the TCP frame directly from the raw byte values
                messageCount += 1
                let seq = UInt32(messageCount)
                let frame: [UInt8] = [
                    // Length prefix (payload = 12 bytes for 1 message)
                    0x00, 0x00, 0x00, 0x0C,
                    // Magic
                    0x4D, 0x53, 0x48, 0x52,
                    // Sequence (big-endian)
                    UInt8((seq >> 24) & 0xFF), UInt8((seq >> 16) & 0xFF),
                    UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF),
                    // Message count
                    0x01,
                    // MIDI message bytes
                    b0, b1, b2
                ]
                tcpServer.sendRaw(frame)

                let ch = (b0 & 0x0F) + 1
                let text = "\(midiTypeName(b0)) ch=\(ch) d1=\(b1) d2=\(b2)"
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog("TX #\(seq): \(text)")
                }

                offset += msgLen
            }

            // Advance to next packet (4-byte aligned)
            let packetSize = dataFieldOffset + length
            let aligned = (packetSize + 3) & ~3
            curPtr = curPtr.advanced(by: aligned)
        }
    }

    // MARK: - Table View

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = col.identifier.rawValue

        if id == "check" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            check.state = sources[row].enabled ? .on : .off
            check.tag = row
            return check
        } else {
            let cell = NSTextField(labelWithString: sources[row].name)
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
    }

    @objc func checkboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < sources.count else { return }
        sources[row].enabled = sender.state == .on
    }

    // MARK: - Bonjour Delegate

    func netServiceDidPublish(_ sender: NetService) {
        appendLog("Bonjour: advertising as \"\(sender.name)\"")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        appendLog("Bonjour: publish failed.")
    }

    // MARK: - Log

    func appendLog(_ text: String) {
        logLines += 1
        if logLines > maxLogLines {
            let storage = logView.textStorage!
            if let range = storage.string.range(of: "\n") {
                let nsRange = NSRange(storage.string.startIndex..<range.upperBound, in: storage.string)
                storage.deleteCharacters(in: nsRange)
            }
            logLines = maxLogLines
        }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = NSAttributedString(string: "[\(timestamp)] \(text)\n",
                                       attributes: [.font: NSFont.userFixedPitchFont(ofSize: 11)!,
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1.0)])
        logView.textStorage?.append(entry)
        logView.scrollToEndOfDocument(nil)
    }

    @objc func clearLog() {
        logView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        logLines = 0
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
