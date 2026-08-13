import CoreMIDI
import Foundation

protocol CoreMIDIEngineProtocol: Actor {
    func start() throws
    func stop()
    var isActive: Bool { get }
    func sendNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) throws
    func sendNoteOff(channel: UInt8, note: UInt8, velocity: UInt8) throws
    func sendCC(channel: UInt8, controller: UInt8, value: UInt8) throws
    func sendProgramChange(channel: UInt8, program: UInt8) throws
    func sendPitchBend(channel: UInt8, value: UInt16) throws
    func sendAftertouch(channel: UInt8, pressure: UInt8) throws
    func sendSysEx(_ bytes: [UInt8]) throws
}

/// Actor wrapping CoreMIDI. Creates a virtual source (for sending MIDI to Logic Pro)
/// and a virtual destination (for receiving MIDI from Logic Pro).
actor MIDIEngine: CoreMIDIEngineProtocol {
    struct Runtime: Sendable {
        let createClient: @Sendable (_ name: String, _ onNotification: @escaping @Sendable (Int32) -> Void) -> (OSStatus, MIDIClientRef)
        let createSource: @Sendable (_ client: MIDIClientRef, _ name: String) -> (OSStatus, MIDIEndpointRef)
        let createDestination: @Sendable (
            _ client: MIDIClientRef,
            _ name: String,
            _ onBytes: @escaping @Sendable ([UInt8]) -> Void
        ) -> (OSStatus, MIDIEndpointRef)
        let disposeEndpoint: @Sendable (_ endpoint: MIDIEndpointRef) -> Void
        let disposeClient: @Sendable (_ client: MIDIClientRef) -> Void
        let sendMessage: @Sendable (_ source: MIDIEndpointRef, _ bytes: [UInt8]) -> OSStatus

        static let production = Runtime(
            createClient: { name, onNotification in
                var client: MIDIClientRef = 0
                let status = MIDIClientCreateWithBlock(name as CFString, &client) { notification in
                    onNotification(notification.pointee.messageID.rawValue)
                }
                return (status, client)
            },
            createSource: { client, name in
                var source: MIDIEndpointRef = 0
                let status = MIDISourceCreate(client, name as CFString, &source)
                return (status, source)
            },
            createDestination: { client, name, onBytes in
                var destination: MIDIEndpointRef = 0
                let status = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { packetList, _ in
                    let packets = packetList.pointee
                    var list = packets
                    withUnsafePointer(to: &list.packet) { firstPacket in
                        var packet = firstPacket
                        for _ in 0..<list.numPackets {
                            let current = packet.pointee
                            let length = Int(current.length)
                            let bytes = withUnsafeBytes(of: current.data) { raw in
                                Array(raw.prefix(length).bindMemory(to: UInt8.self))
                            }
                            onBytes(bytes)
                            packet = UnsafePointer(MIDIPacketNext(packet))
                        }
                    }
                }
                return (status, destination)
            },
            disposeEndpoint: { endpoint in
                if endpoint != 0 {
                    MIDIEndpointDispose(endpoint)
                }
            },
            disposeClient: { client in
                if client != 0 {
                    MIDIClientDispose(client)
                }
            },
            sendMessage: { source, bytes in
                let bufferSize = max(
                    MemoryLayout<MIDIPacketList>.size,
                    MemoryLayout<MIDIPacketList>.size + bytes.count
                )
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                return buffer.withUnsafeMutableBytes { rawBuf in
                    let packetList = rawBuf.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
                    var pkt = MIDIPacketListInit(packetList)
                    return bytes.withUnsafeBufferPointer { dataBuf in
                        guard let base = dataBuf.baseAddress else {
                            return noErr
                        }
                        pkt = MIDIPacketListAdd(packetList, bufferSize, pkt, 0, bytes.count, base)
                        return MIDIReceived(source, packetList)
                    }
                }
            }
        )
    }

    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    private var isRunning = false
    private let runtime: Runtime
    private let identityNamespace: String
    private let processIdentifier: Int32

    /// Stream of inbound MIDI packets from Logic Pro via the virtual destination.
    let inboundMessages: AsyncStream<MIDIFeedback.Event>
    private let inboundContinuation: AsyncStream<MIDIFeedback.Event>.Continuation

    init(
        runtime: Runtime = .production,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.runtime = runtime
        self.identityNamespace = MIDIPortManager.normalizedNamespace(from: environment)
        self.processIdentifier = processIdentifier
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
        self.inboundMessages = stream
        self.inboundContinuation = continuation
    }

    /// The legacy CoreMIDI channel is intentionally separate from the stable
    /// MCU/KeyCmd/Scripter surfaces. MCP hosts may keep more than one stdio
    /// session alive for the same configured server; publishing the legacy
    /// ports under their old fixed names then creates indistinguishable live
    /// endpoints. These ports have never had stable unique IDs, so attaching a
    /// process-session discriminator removes the ambiguity without changing the
    /// persistent MCU identity that Logic's control-surface setup depends on.
    private func publishedName(for baseName: String) -> String {
        "\(baseName) [\(identityNamespace):\(processIdentifier)]"
    }

    deinit {
        inboundContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Create the CoreMIDI client, virtual source, and virtual destination.
    func start() throws {
        guard !isRunning else { return }

        let sourceName = publishedName(for: ServerConfig.virtualMIDISourceName)
        let destinationName = publishedName(for: ServerConfig.virtualMIDISinkName)
        let (clientStatus, createdClient) = runtime.createClient(
            sourceName,
            MIDIEngine.logMIDINotification
        )
        guard clientStatus == noErr else {
            throw MIDIEngineError.clientCreationFailed(clientStatus)
        }

        let (sourceStatus, createdSource) = runtime.createSource(createdClient, sourceName)
        guard sourceStatus == noErr else {
            runtime.disposeClient(createdClient)
            throw MIDIEngineError.sourceCreationFailed(sourceStatus)
        }

        let continuation = self.inboundContinuation
        let (destinationStatus, createdDestination) = runtime.createDestination(
            createdClient,
            destinationName
        ) { bytes in
            for event in MIDIFeedback.parseBytes(bytes) {
                continuation.yield(event)
            }
        }
        guard destinationStatus == noErr else {
            runtime.disposeEndpoint(createdSource)
            runtime.disposeClient(createdClient)
            throw MIDIEngineError.destinationCreationFailed(destinationStatus)
        }

        client = createdClient
        virtualSource = createdSource
        virtualDestination = createdDestination
        isRunning = true
        Log.info("MIDIEngine started — source: \(sourceName), sink: \(destinationName)", subsystem: "midi")
    }

    /// Tear down all CoreMIDI resources.
    func stop() {
        guard isRunning else { return }
        runtime.disposeEndpoint(virtualSource)
        runtime.disposeEndpoint(virtualDestination)
        runtime.disposeClient(client)
        virtualSource = 0
        virtualDestination = 0
        client = 0
        isRunning = false
        // v3.4.5 (H1 / P1-6): do NOT finish the inbound stream here. The
        // stream + continuation are created once in init() and cannot be
        // re-created (`inboundMessages` is a `let` the consumer holds). If
        // stop() finished the continuation, a later start() would re-capture
        // an already-finished continuation and silently drop all inbound MIDI
        // — making the engine restart-unsafe. The continuation is terminal
        // only at deinit; stop() is a restartable pause that just tears down
        // the CoreMIDI endpoints.
        Log.info("MIDIEngine stopped", subsystem: "midi")
    }

    var isActive: Bool { isRunning && client != 0 }

    // MARK: - Send: Notes

    func sendNoteOn(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 100) throws {
        let status: UInt8 = 0x90 | (channel & 0x0F)
        try sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    func sendNoteOff(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 0) throws {
        let status: UInt8 = 0x80 | (channel & 0x0F)
        try sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    // MARK: - Send: Control Change

    func sendCC(channel: UInt8 = 0, controller: UInt8, value: UInt8) throws {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        try sendShortMessage([status, controller & 0x7F, value & 0x7F])
    }

    // MARK: - Send: Program Change

    func sendProgramChange(channel: UInt8 = 0, program: UInt8) throws {
        let status: UInt8 = 0xC0 | (channel & 0x0F)
        try sendShortMessage([status, program & 0x7F])
    }

    // MARK: - Send: Pitch Bend

    /// Send pitch bend. `value` is 14-bit (0-16383), center = 8192.
    func sendPitchBend(channel: UInt8 = 0, value: UInt16 = 8192) throws {
        let clamped = min(value, 16383)
        let lsb = UInt8(clamped & 0x7F)
        let msb = UInt8((clamped >> 7) & 0x7F)
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        try sendShortMessage([status, lsb, msb])
    }

    // MARK: - Send: Aftertouch

    /// Channel pressure (mono aftertouch).
    func sendAftertouch(channel: UInt8 = 0, pressure: UInt8) throws {
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        try sendShortMessage([status, pressure & 0x7F])
    }

    // MARK: - Send: SysEx

    /// Send a complete SysEx message (must start with 0xF0 and end with 0xF7, middle bytes < 0x80).
    func sendSysEx(_ bytes: [UInt8]) throws {
        guard MCUProtocol.isValidSysEx(bytes) else {
            Log.error("Invalid SysEx: must start with F0, end with F7, middle bytes < 0x80", subsystem: "midi")
            throw MIDIEngineError.invalidSysEx
        }
        try sendRawBytes(bytes)
    }

    // MARK: - Send: Raw

    /// Send arbitrary MIDI bytes through the virtual source.
    /// Uses dynamic buffer for large messages (SysEx 256+ bytes).
    func sendRawBytes(_ bytes: [UInt8]) throws {
        guard isRunning else {
            Log.warn("MIDIEngine not running — dropping message", subsystem: "midi")
            throw MIDIEngineError.notRunning
        }
        let status = runtime.sendMessage(virtualSource, bytes)
        if status != noErr {
            Log.error("MIDIReceived failed with status \(status)", subsystem: "midi")
            throw MIDIEngineError.sendFailed(status)
        }
    }

    // MARK: - Private

    private func sendShortMessage(_ bytes: [UInt8]) throws {
        try sendRawBytes(bytes)
        Log.debug("MIDI out: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))", subsystem: "midi")
    }

    private static func logMIDINotification(_ rawValue: Int32) {
        let id = MIDINotificationMessageID(rawValue: rawValue)
        switch id {
        case .some(.msgSetupChanged):
            Log.debug("MIDI setup changed", subsystem: "midi")
        case .some(.msgObjectAdded):
            Log.debug("MIDI object added", subsystem: "midi")
        case .some(.msgObjectRemoved):
            Log.debug("MIDI object removed", subsystem: "midi")
        default:
            Log.debug("MIDI notification: \(rawValue)", subsystem: "midi")
        }
    }
}

// MARK: - Errors

enum MIDIEngineError: Error, Sendable {
    case clientCreationFailed(OSStatus)
    case sourceCreationFailed(OSStatus)
    case destinationCreationFailed(OSStatus)
    case notRunning
    case sendFailed(OSStatus)
    case invalidSysEx
}
