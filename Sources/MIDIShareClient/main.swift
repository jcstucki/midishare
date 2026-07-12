import Cocoa
import CoreMIDI

// MARK: - Protocol (inline)
// TCP framing: 4-byte length prefix (big-endian) + payload
// Payload: [0..3] magic "MSHR", [4..7] sequence, [8] count, [9..] 3-byte messages

let kMIDIShareMagic: [UInt8] = [0x4D, 0x53, 0x48, 0x52]
let kMIDISharePort: UInt16 = 17249
let kBonjourServiceType = "_midishare._tcp"
let kBonjourServiceDomain = "local."
let kPacketHeaderSize = 9

struct MIDIShareMessage {
    var status: UInt8; var data1: UInt8; var data2: UInt8
}

func decodeMIDIPayload(_ data: Data) -> [MIDIShareMessage]? {
    guard data.count >= kPacketHeaderSize else { return nil }
    let bytes = [UInt8](data)
    guard bytes[0...3].elementsEqual(kMIDIShareMagic) else { return nil }
    let count = Int(bytes[8])
    guard data.count >= kPacketHeaderSize + count * 3 else { return nil }
    var messages = [MIDIShareMessage]()
    for i in 0..<count {
        let o = kPacketHeaderSize + i * 3
        messages.append(MIDIShareMessage(status: bytes[o], data1: bytes[o + 1], data2: bytes[o + 2]))
    }
    return messages
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

// MARK: - Virtual MIDI Source

class VirtualMIDISource {
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private(set) var active = false

    func start(name: String) -> Bool {
        var status = MIDIClientCreateWithBlock(name as CFString, &client) { _ in }
        guard status == noErr else { return false }
        status = MIDISourceCreate(client, name as CFString, &source)
        guard status == noErr else { MIDIClientDispose(client); return false }
        active = true
        return true
    }

    func send(status statusByte: UInt8, data1: UInt8, data2: UInt8) {
        guard active else { return }
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        let msgLen = (statusByte & 0xF0 == 0xC0 || statusByte & 0xF0 == 0xD0) ? 2 : 3
        var bytes = msgLen == 2 ? [statusByte, data1] : [statusByte, data1, data2]
        packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size,
                                    packet, 0, bytes.count, &bytes)
        MIDIReceived(source, &packetList)
    }

    func stop() {
        if source != 0 { MIDIEndpointDispose(source); source = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        active = false
    }
}

// MARK: - TCP Client

class TCPClient {
    private var socket: Int32 = -1
    private let recvQueue = DispatchQueue(label: "midishare.tcp.recv", qos: .userInteractive)
    private var running = false
    var onMessages: (([MIDIShareMessage]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onConnect: (() -> Void)?

    func connect(host: String, port: UInt16) -> Bool {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { return false }

        // Disable Nagle, suppress SIGPIPE
        var noDelay: Int32 = 1
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        // Try numeric IP first, then DNS resolve
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            guard let hostEntry = gethostbyname(host),
                  hostEntry.pointee.h_length > 0,
                  let addrList = hostEntry.pointee.h_addr_list,
                  let firstAddr = addrList[0] else {
                close(socket); socket = -1; return false
            }
            memcpy(&addr.sin_addr, firstAddr, Int(hostEntry.pointee.h_length))
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(socket, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(socket); socket = -1; return false
        }

        running = true
        onConnect?()
        recvQueue.async { [weak self] in self?.receiveLoop() }
        return true
    }

    private func receiveLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while running {
            let bytesRead = recv(socket, &chunk, chunk.count, 0)
            if bytesRead <= 0 {
                if running {
                    let reason = bytesRead == 0 ? "Server closed connection" : String(cString: strerror(errno))
                    DispatchQueue.main.async { [weak self] in self?.onDisconnect?(reason) }
                }
                break
            }

            buffer.append(contentsOf: chunk[0..<bytesRead])

            // Parse length-prefixed frames
            while buffer.count >= 4 {
                let lenBytes = [UInt8](buffer[0..<4])
                let payloadLen = Int(UInt32(lenBytes[0]) << 24 | UInt32(lenBytes[1]) << 16 |
                                     UInt32(lenBytes[2]) << 8 | UInt32(lenBytes[3]))
                guard payloadLen > 0, payloadLen < 65536 else {
                    buffer.removeAll()
                    break
                }
                guard buffer.count >= 4 + payloadLen else { break }

                let payload = buffer.subdata(in: 4..<(4 + payloadLen))
                buffer.removeSubrange(0..<(4 + payloadLen))

                if let messages = decodeMIDIPayload(payload) {
                    onMessages?(messages)
                }
            }
        }
    }

    func stop() {
        running = false
        if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR); close(socket); socket = -1 }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NetServiceBrowserDelegate, NetServiceDelegate {

    var window: NSWindow!
    var portNameField: NSTextField!
    var serverIPField: NSTextField!
    var startButton: NSButton!
    var connectButton: NSButton!
    var statusLabel: NSTextField!
    var serverLabel: NSTextField!
    var logView: NSTextView!

    let virtualMIDI = VirtualMIDISource()
    var tcpClient: TCPClient?
    let browser = NetServiceBrowser()
    var resolving = [NetService]()
    var messageCount: UInt64 = 0
    var logLines = 0
    let maxLogLines = 200
    var active = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        browser.delegate = self
    }

    func buildUI() {
        let w: CGFloat = 520, h: CGFloat = 460
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MIDIShare Client"
        window.minSize = NSSize(width: 420, height: 360)
        window.center()

        let content = window.contentView!

        // Port name row
        let nameLabel = makeLabel("Virtual Port Name:", size: 12, bold: true)
        nameLabel.frame = NSRect(x: 16, y: h - 36, width: 140, height: 20)
        nameLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(nameLabel)

        portNameField = NSTextField(frame: NSRect(x: 162, y: h - 38, width: w - 184, height: 24))
        portNameField.stringValue = "MIDIShare"
        portNameField.font = NSFont.systemFont(ofSize: 12)
        portNameField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(portNameField)

        // Server IP row
        let ipLabel = makeLabel("Server IP:", size: 12, bold: true)
        ipLabel.frame = NSRect(x: 16, y: h - 68, width: 140, height: 20)
        ipLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(ipLabel)

        serverIPField = NSTextField(frame: NSRect(x: 162, y: h - 70, width: w - 290, height: 24))
        serverIPField.placeholderString = "e.g. 192.168.1.100 (or auto-discover)"
        serverIPField.font = NSFont.systemFont(ofSize: 12)
        serverIPField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(serverIPField)

        connectButton = NSButton(frame: NSRect(x: w - 112, y: h - 72, width: 96, height: 28))
        connectButton.title = "Connect"
        connectButton.bezelStyle = .rounded
        connectButton.setButtonType(.momentaryPushIn)
        connectButton.target = self
        connectButton.action = #selector(manualConnect)
        connectButton.isEnabled = false
        connectButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(connectButton)

        // Start button
        startButton = NSButton(frame: NSRect(x: 16, y: h - 106, width: 96, height: 28))
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.setButtonType(.momentaryPushIn)
        startButton.target = self
        startButton.action = #selector(toggleActive)
        startButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(startButton)

        // Status row
        statusLabel = makeLabel("Stopped", size: 12, bold: false)
        statusLabel.frame = NSRect(x: 120, y: h - 102, width: w - 136, height: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(statusLabel)

        // Server discovery row
        serverLabel = makeLabel("No servers discovered via Bonjour", size: 11, bold: false)
        serverLabel.frame = NSRect(x: 16, y: h - 128, width: w - 32, height: 16)
        serverLabel.textColor = .secondaryLabelColor
        serverLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(serverLabel)

        // Separator
        let sep = NSBox(frame: NSRect(x: 16, y: h - 140, width: w - 32, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        content.addSubview(sep)

        // Log label + clear
        let logLabel = makeLabel("Log", size: 13, bold: true)
        logLabel.frame = NSRect(x: 16, y: h - 162, width: 100, height: 20)
        logLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(logLabel)

        let clearButton = NSButton(frame: NSRect(x: w - 74, y: h - 164, width: 58, height: 24))
        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.target = self
        clearButton.action = #selector(clearLog)
        clearButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(clearButton)

        // Log view
        let logScroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: w - 32, height: h - 184))
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

    // MARK: - Start / Stop

    @objc func toggleActive() {
        if active { stopAll() } else { startAll() }
    }

    func startAll() {
        let portName = portNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !portName.isEmpty else {
            appendLog("Enter a port name.")
            return
        }

        guard virtualMIDI.start(name: portName) else {
            appendLog("Failed to create virtual MIDI port.")
            return
        }

        active = true
        messageCount = 0
        startButton.title = "Stop"
        portNameField.isEnabled = false
        connectButton.isEnabled = true

        appendLog("Virtual MIDI port \"\(portName)\" created.")
        appendLog("In Ableton: Preferences > MIDI > enable \"\(portName)\" as Track/Remote input.")

        // Check if user entered an IP manually
        let manualIP = serverIPField.stringValue.trimmingCharacters(in: .whitespaces)
        if !manualIP.isEmpty {
            appendLog("Connecting to \(manualIP):\(kMIDISharePort)...")
            statusLabel.stringValue = "Connecting to \(manualIP)..."
            statusLabel.textColor = .systemOrange
            connectToServer(host: manualIP, port: kMIDISharePort)
        } else {
            statusLabel.stringValue = "Searching for server..."
            statusLabel.textColor = .systemOrange
            appendLog("Searching for MIDIShare server via Bonjour...")
            appendLog("Or enter the server IP above and click Connect.")
            browser.searchForServices(ofType: kBonjourServiceType, inDomain: kBonjourServiceDomain)
        }
    }

    @objc func manualConnect() {
        guard active else {
            appendLog("Click Start first.")
            return
        }
        let ip = serverIPField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else {
            appendLog("Enter the server's IP address.")
            return
        }
        appendLog("Connecting to \(ip):\(kMIDISharePort)...")
        statusLabel.stringValue = "Connecting to \(ip)..."
        statusLabel.textColor = .systemOrange
        connectToServer(host: ip, port: kMIDISharePort)
    }

    func connectToServer(host: String, port: UInt16) {
        tcpClient?.stop()
        tcpClient = TCPClient()

        tcpClient?.onConnect = { [weak self] in
            DispatchQueue.main.async {
                let portName = self?.portNameField.stringValue ?? "MIDIShare"
                self?.statusLabel.stringValue = "Connected to \(host)  |  Port: \"\(portName)\""
                self?.statusLabel.textColor = .systemGreen
                self?.appendLog("Connected to server at \(host):\(port)")
            }
        }

        tcpClient?.onMessages = { [weak self] messages in
            guard let self = self else { return }
            for msg in messages {
                self.virtualMIDI.send(status: msg.status, data1: msg.data1, data2: msg.data2)
                let ch = (msg.status & 0x0F) + 1
                let text = "\(midiTypeName(msg.status)) ch=\(ch) d1=\(msg.data1) d2=\(msg.data2)"
                DispatchQueue.main.async {
                    self.messageCount += 1
                    self.appendLog("RX #\(self.messageCount): \(text)")
                }
            }
        }

        tcpClient?.onDisconnect = { [weak self] reason in
            guard let self = self, self.active else { return }
            self.appendLog("Disconnected: \(reason)")
            self.statusLabel.stringValue = "Disconnected. Enter IP and click Connect, or wait for Bonjour."
            self.statusLabel.textColor = .systemOrange
            self.tcpClient = nil
        }

        let client = tcpClient!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if !client.connect(host: host, port: port) {
                DispatchQueue.main.async {
                    self?.appendLog("Failed to connect to \(host):\(port). Check IP and firewall.")
                    self?.statusLabel.stringValue = "Connection failed."
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    func stopAll() {
        browser.stop()
        tcpClient?.stop()
        tcpClient = nil
        virtualMIDI.stop()
        resolving.removeAll()

        active = false
        startButton.title = "Start"
        portNameField.isEnabled = true
        connectButton.isEnabled = false
        statusLabel.stringValue = "Stopped"
        statusLabel.textColor = .secondaryLabelColor
        serverLabel.stringValue = "No servers discovered via Bonjour"
        serverLabel.textColor = .secondaryLabelColor
        appendLog("Stopped. \(messageCount) messages received.")
    }

    // MARK: - Bonjour Browser

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        appendLog("Bonjour: found server \"\(service.name)\"")
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        appendLog("Bonjour: server disappeared \"\(service.name)\"")
        resolving.removeAll { $0 == service }
        if resolving.isEmpty {
            serverLabel.stringValue = "No servers discovered via Bonjour"
            serverLabel.textColor = .secondaryLabelColor
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }

        for addrData in addresses {
            var storage = sockaddr_storage()
            (addrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
            if Int32(storage.ss_family) == AF_INET {
                var addr = withUnsafePointer(to: &storage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                let host = String(cString: ipStr)
                let port = UInt16(sender.port)

                let text = "Server: \"\(sender.name)\" at \(host):\(port)"
                serverLabel.stringValue = text
                serverLabel.textColor = .labelColor
                appendLog("Bonjour resolved: \(text)")

                // Auto-fill the IP field
                if serverIPField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    serverIPField.stringValue = host
                }

                // Auto-connect if active and not already connected
                if active && tcpClient == nil {
                    connectToServer(host: host, port: port)
                }
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        appendLog("Bonjour: failed to resolve \"\(sender.name)\"")
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
