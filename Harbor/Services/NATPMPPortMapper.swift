import Darwin
import Foundation

nonisolated enum IncomingPortStatus: Equatable, Sendable {
    case waiting
    case mapped(Int)
    case failed
}

/// NAT-PMP (RFC 6886) as ProtonVPN uses it for port forwarding: the gateway
/// assigns a public port and forwards it to the same port number on this Mac.
nonisolated enum NATPMP {
    enum TransportProtocol: UInt8 {
        case udp = 1
        case tcp = 2
    }

    static let gatewayPort: UInt16 = 5351
    static let leaseSeconds: UInt32 = 60

    /// Proton forwards a public port to the requested internal port, and
    /// peers dial the port aria2 announces, so both must match. Internal port
    /// 0 makes Proton return the connection's port with internal == external,
    /// the same one the Proton app shows. Its documented `natpmpc -a 1 0`
    /// instead maps a random public port to local port 1.
    static func mappingRequest(_ transport: TransportProtocol) -> Data {
        var bytes: [UInt8] = [0, transport.rawValue, 0, 0, 0, 0, 0, 0]
        withUnsafeBytes(of: leaseSeconds.bigEndian) { bytes.append(contentsOf: $0) }
        return Data(bytes)
    }

    static func mappedPort(from response: Data, for transport: TransportProtocol) -> Int? {
        let bytes = [UInt8](response)
        guard bytes.count == 16,
              bytes[0] == 0,
              bytes[1] == 128 + transport.rawValue,
              bytes[2] == 0, bytes[3] == 0 else {
            return nil
        }
        let port = Int(bytes[10]) << 8 | Int(bytes[11])
        return port == 0 ? nil : port
    }

    // ponytail: assumes the gateway is .1 of the tunnel address, which holds for
    // ProtonVPN. Read the real gateway once another VPN needs it.
    static func gateway(forAddress address: String) -> String? {
        var octets = address.split(separator: ".")
        guard octets.count == 4 else {
            return nil
        }
        octets[3] = "1"
        return octets.joined(separator: ".")
    }

    /// Sends one mapping request and waits up to three seconds for the answer.
    static func requestMapping(_ transport: TransportProtocol, gateway: String) -> Int? {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            return nil
        }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = gatewayPort.bigEndian
        guard inet_pton(AF_INET, gateway, &address.sin_addr) == 1 else {
            return nil
        }

        let request = mappingRequest(transport)
        let sent = request.withUnsafeBytes { requestBytes in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        socketDescriptor,
                        requestBytes.baseAddress,
                        requestBytes.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sent == request.count else {
            return nil
        }

        var response = [UInt8](repeating: 0, count: 16)
        guard recv(socketDescriptor, &response, response.count, 0) == response.count else {
            return nil
        }
        return mappedPort(from: Data(response), for: transport)
    }
}

/// Keeps a NAT-PMP mapping alive by renewing its 60-second lease every 45 seconds.
final class NATPMPPortMapper {
    var statusDidChange: ((IncomingPortStatus) -> Void)?
    private var gateway: String?
    private var renewalTask: Task<Void, Never>?
    private var status = IncomingPortStatus.waiting

    func start(gateway: String) {
        guard gateway != self.gateway else {
            return
        }
        stop()
        self.gateway = gateway
        renewalTask = Task { [weak self] in
            while Task.isCancelled == false {
                let port = await Task.detached {
                    // ponytail: Proton assigns one port for both protocols, so
                    // the TCP port stands for both.
                    let udpPort = NATPMP.requestMapping(.udp, gateway: gateway)
                    let tcpPort = NATPMP.requestMapping(.tcp, gateway: gateway)
                    return udpPort == nil ? nil : tcpPort
                }.value
                guard Task.isCancelled == false, let self else {
                    return
                }
                publish(port.map(IncomingPortStatus.mapped) ?? .failed)
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        renewalTask?.cancel()
        renewalTask = nil
        gateway = nil
        publish(.waiting)
    }

    private func publish(_ newStatus: IncomingPortStatus) {
        guard newStatus != status else {
            return
        }
        status = newStatus
        statusDidChange?(newStatus)
    }
}
