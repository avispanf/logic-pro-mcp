import CoreMIDI
import Foundation

protocol VirtualPortManaging: Actor {
    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair
    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair
}

enum MIDIPortMode: String, Sendable {
    case sendOnly = "send_only"
    case bidirectional
}

enum MIDIEndpointDirection: String, Sendable {
    case source
    case destination
}

/// Manages multiple virtual MIDI port pairs for the MCP server.
/// Each channel (MCU, CoreMIDI, KeyCommands, Scripter) gets its own named port.
actor MIDIPortManager: VirtualPortManaging {
    struct Runtime: Sendable {
        let createClient: @Sendable (_ name: String, _ client: inout MIDIClientRef) -> OSStatus
        let createSource: @Sendable (_ client: MIDIClientRef, _ name: String, _ source: inout MIDIEndpointRef) -> OSStatus
        let createDestination: @Sendable (
            _ client: MIDIClientRef,
            _ name: String,
            _ destination: inout MIDIEndpointRef,
            _ onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
        ) -> OSStatus
        let setUniqueID: @Sendable (_ endpoint: MIDIEndpointRef, _ uniqueID: MIDIUniqueID) -> OSStatus
        let disposeEndpoint: @Sendable (_ endpoint: MIDIEndpointRef) -> OSStatus
        let disposeClient: @Sendable (_ client: MIDIClientRef) -> OSStatus

        static let production = Runtime(
            createClient: { name, client in
                MIDIClientCreateWithBlock(name as CFString, &client) { notification in
                    Log.debug(
                        "MIDIPortManager notification: \(notification.pointee.messageID.rawValue)",
                        subsystem: "midi"
                    )
                }
            },
            createSource: { client, name, source in
                MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
            },
            createDestination: { client, name, destination, onReceive in
                MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination, onReceive)
            },
            setUniqueID: { endpoint, uniqueID in
                MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
            },
            disposeEndpoint: { endpoint in
                MIDIEndpointDispose(endpoint)
            },
            disposeClient: { client in
                MIDIClientDispose(client)
            }
        )
    }

    private var client: MIDIClientRef = 0
    private var ports: [String: MIDIPortPair] = [:]
    private var isRunning = false
    private let runtime: Runtime
    private let identityNamespace: String

    static let identityNamespaceEnvironmentKey = "LOGIC_PRO_MCP_MIDI_INSTANCE_ID"

    init(
        runtime: Runtime = .production,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runtime = runtime
        self.identityNamespace = Self.normalizedNamespace(from: environment)
    }

    private func publishedName(for baseName: String) -> String {
        Self.publishedName(for: baseName, namespace: identityNamespace)
    }

    static func normalizedNamespace(from environment: [String: String]) -> String {
        let configured = environment[identityNamespaceEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    }

    static func publishedName(for baseName: String, namespace: String) -> String {
        guard namespace != "default" else { return baseName }
        return "\(baseName) [\(namespace)]"
    }

    /// CoreMIDI object references are process-local and disappear on restart.
    /// Recreating only the same name leaves Logic attached to a dead endpoint;
    /// duplicated names from concurrent clients can also resolve to the wrong
    /// live object. The published namespace removes that ambiguity, while this
    /// stable negative ID preserves endpoint identity across process restarts.
    /// Source and destination must have separate IDs.
    static func stableUniqueID(
        namespace: String,
        name: String,
        direction: MIDIEndpointDirection
    ) -> MIDIUniqueID {
        let identity = "com.logicpromcp.virtual-midi.v1|\(namespace)|\(name)|\(direction.rawValue)"
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        // Keep virtual endpoint IDs in the negative half of Int32. Zero is
        // never produced, and the namespace lets concurrent MCP clients opt
        // into distinct persistent identities.
        return MIDIUniqueID(bitPattern: hash | 0x8000_0000)
    }

    private func assignStableIdentity(
        endpoint: MIDIEndpointRef,
        name: String,
        direction: MIDIEndpointDirection
    ) throws {
        let uniqueID = Self.stableUniqueID(
            namespace: identityNamespace,
            name: name,
            direction: direction
        )
        let status = runtime.setUniqueID(endpoint, uniqueID)
        guard status == noErr else {
            throw MIDIPortError.uniqueIDAssignmentFailed(
                name: name,
                direction: direction,
                uniqueID: uniqueID,
                status: status
            )
        }
    }

    struct MIDIPortPair: Sendable {
        let name: String
        let source: MIDIEndpointRef       // MCP → Logic Pro
        let destination: MIDIEndpointRef?  // Logic Pro → MCP (nil for send-only)
        let mode: MIDIPortMode

        init(
            name: String,
            source: MIDIEndpointRef,
            destination: MIDIEndpointRef?,
            mode: MIDIPortMode? = nil
        ) {
            self.name = name
            self.source = source
            self.destination = destination
            self.mode = mode ?? (destination == nil ? .sendOnly : .bidirectional)
        }
    }

    /// Start the MIDI client.
    func start() throws {
        guard !isRunning else { return }
        let status = runtime.createClient("LogicProMCP", &client)
        guard status == noErr else {
            throw MIDIPortError.clientCreationFailed(status)
        }
        isRunning = true
        Log.info("MIDIPortManager started (client: \(client))", subsystem: "midi")
    }

    /// Create a bidirectional port pair (source + destination).
    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortPair {
        guard isRunning else { throw MIDIPortError.notRunning }

        if let existing = try cachedPort(named: name, requestedMode: .bidirectional) {
            return existing
        }

        let endpointName = publishedName(for: name)
        var source: MIDIEndpointRef = 0
        var status = runtime.createSource(client, endpointName, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }
        do {
            try assignStableIdentity(endpoint: source, name: name, direction: .source)
        } catch {
            _ = runtime.disposeEndpoint(source)
            throw error
        }

        var dest: MIDIEndpointRef = 0
        status = runtime.createDestination(client, endpointName, &dest, onReceive)
        guard status == noErr else {
            _ = runtime.disposeEndpoint(source)
            throw MIDIPortError.destinationCreationFailed(name, status)
        }
        do {
            try assignStableIdentity(endpoint: dest, name: name, direction: .destination)
        } catch {
            _ = runtime.disposeEndpoint(dest)
            _ = runtime.disposeEndpoint(source)
            throw error
        }

        let pair = MIDIPortPair(name: endpointName, source: source, destination: dest, mode: .bidirectional)
        ports[name] = pair
        Log.info("Created bidirectional port: \(endpointName) (src: \(source), dst: \(dest))", subsystem: "midi")
        return pair
    }

    /// Create a send-only port (source only, no destination).
    func createSendOnlyPort(name: String) throws -> MIDIPortPair {
        guard isRunning else { throw MIDIPortError.notRunning }

        if let existing = try cachedPort(named: name, requestedMode: .sendOnly) {
            return existing
        }

        let endpointName = publishedName(for: name)
        var source: MIDIEndpointRef = 0
        let status = runtime.createSource(client, endpointName, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }
        do {
            try assignStableIdentity(endpoint: source, name: name, direction: .source)
        } catch {
            _ = runtime.disposeEndpoint(source)
            throw error
        }

        let pair = MIDIPortPair(name: endpointName, source: source, destination: nil, mode: .sendOnly)
        ports[name] = pair
        Log.info("Created send-only port: \(endpointName) (src: \(source))", subsystem: "midi")
        return pair
    }

    private func cachedPort(named name: String, requestedMode: MIDIPortMode) throws -> MIDIPortPair? {
        guard let existing = ports[name] else { return nil }
        guard existing.mode == requestedMode else {
            throw MIDIPortError.modeConflict(name: name, existing: existing.mode, requested: requestedMode)
        }
        Log.info("Reusing existing port: \(name)", subsystem: "midi")
        return existing
    }

    /// Get an existing port by name.
    func getPort(name: String) -> MIDIPortPair? {
        ports[name]
    }

    /// Number of active ports.
    var portCount: Int { ports.count }

    /// Stop and dispose all ports.
    func stop() {
        for (name, pair) in ports {
            _ = runtime.disposeEndpoint(pair.source)
            if let dest = pair.destination {
                _ = runtime.disposeEndpoint(dest)
            }
            Log.info("Disposed port: \(name)", subsystem: "midi")
        }
        ports.removeAll()
        if client != 0 {
            _ = runtime.disposeClient(client)
            client = 0
        }
        isRunning = false
        Log.info("MIDIPortManager stopped", subsystem: "midi")
    }
}

enum MIDIPortError: Error {
    case clientCreationFailed(OSStatus)
    case notRunning
    case sourceCreationFailed(String, OSStatus)
    case destinationCreationFailed(String, OSStatus)
    case uniqueIDAssignmentFailed(
        name: String,
        direction: MIDIEndpointDirection,
        uniqueID: MIDIUniqueID,
        status: OSStatus
    )
    case modeConflict(name: String, existing: MIDIPortMode, requested: MIDIPortMode)
}
