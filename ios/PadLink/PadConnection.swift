import Foundation
import Network

/// Sends controller state to the PC over UDP and tracks whether the PC answers.
/// All mutable state lives on `queue`.
final class PadConnection {
    enum Status: Equatable {
        case idle
        case connecting
        case connected(String)
        case noResponse
    }

    /// Called on the main thread whenever the status changes.
    var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "padlink.net")
    private let encoder = JSONEncoder()
    private var conn: NWConnection?
    private var timer: DispatchSourceTimer?
    private var latest = ControllerState()
    private var seq: UInt32 = 0
    private var session: UInt32 = 0
    private var tick = 0
    private var lastReply = Date.distantPast
    private var serverName = "PC"
    private var status: Status = .idle

    private static let helloPacket = Data(#"{"t":"hello"}"#.utf8)

    func connect(host: String, port: UInt16) {
        queue.async { self.connectOnQueue(host: host, port: port) }
    }

    func disconnect() {
        queue.async { self.teardown(); self.setStatus(.idle) }
    }

    /// Push a new state. Sent immediately; also re-sent periodically as a keepalive.
    func send(_ state: ControllerState) {
        queue.async {
            self.latest = state
            self.sendState()
        }
    }

    // MARK: - Queue-confined

    private func connectOnQueue(host: String, port: UInt16) {
        teardown()
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            setStatus(.idle)
            return
        }

        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        conn = c
        lastReply = .distantPast
        tick = 0
        seq = 0
        session = UInt32.random(in: 1...UInt32.max)
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self, c === self.conn else { return }
            if case .ready = state {
                c.send(content: Self.helloPacket, completion: .idempotent)
            }
        }
        c.start(queue: queue)
        receive(on: c)
        setStatus(.connecting)

        // 50 ms tick: keepalive state every tick, hello + status check once a second.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        timer = t
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        conn?.cancel()
        conn = nil
    }

    private func onTick() {
        guard let c = conn else { return }
        sendState()
        tick += 1
        if tick % 20 == 0 {
            c.send(content: Self.helloPacket, completion: .idempotent)
            let age = Date().timeIntervalSince(lastReply)
            if age < 3 {
                setStatus(.connected(serverName))
            } else if case .connecting = status, tick < 100 {
                // Give it ~5 s before declaring no response.
            } else {
                setStatus(.noResponse)
            }
        }
    }

    private func sendState() {
        guard let c = conn else { return }
        seq &+= 1
        guard let data = try? encoder.encode(StatePacket(session: session, seq: seq, state: latest)) else { return }
        c.send(content: data, completion: .idempotent)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, c === self.conn else { return }
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["t"] as? String == "ok" {
                self.lastReply = Date()
                if let name = obj["name"] as? String { self.serverName = name }
                self.setStatus(.connected(self.serverName))
            }
            if error == nil {
                self.receive(on: c)
            }
        }
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        DispatchQueue.main.async { self.onStatus?(s) }
    }
}
