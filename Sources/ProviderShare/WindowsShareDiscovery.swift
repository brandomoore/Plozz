import CoreModels
import CoreNetworking
#if canImport(Darwin) && canImport(Network)
import Darwin
import Foundation
import Network
import SMBClient

/// WS-Discovery April 2005, the dialect used by Windows Function Discovery.
enum WindowsShareDiscovery {
    static let discovery = "http://schemas.xmlsoap.org/ws/2005/04/discovery"
    static let addressing = "http://schemas.xmlsoap.org/ws/2004/08/addressing"
    static let soap = "http://www.w3.org/2003/05/soap-envelope"

    static func probe(id: UUID) -> Data {
        Data("""
        <s:Envelope xmlns:s="\(soap)" xmlns:a="\(addressing)" xmlns:d="\(discovery)" xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof">
        <s:Header><a:Action>\(discovery)/Probe</a:Action><a:MessageID>urn:uuid:\(id.uuidString)</a:MessageID><a:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To></s:Header>
        <s:Body><d:Probe><d:Types>wsdp:Device</d:Types></d:Probe></s:Body></s:Envelope>
        """.utf8)
    }

    struct Match {
        let host: String
        let metadata: URL?
        let endpoint: UUID?
    }

    static func match(_ data: Data, id: UUID, host: String) -> Match? {
        guard let xml = xml(data),
              xml.value([envelope, header, (addressing, "RelatesTo")])?.lowercased()
                == "urn:uuid:\(id.uuidString.lowercased())",
              xml.value([envelope, header, (addressing, "Action")]) == discovery + "/ProbeMatches"
        else { return nil }
        let path = [envelope, body, (discovery, "ProbeMatches"), (discovery, "ProbeMatch")]
        guard let ref = xml.value(path + [(addressing, "EndpointReference"), (addressing, "Address")])
        else { return nil }
        let uuid = ref.lowercased().hasPrefix("urn:uuid:") ? UUID(uuidString: String(ref.dropFirst(9))) : nil
        // Never follow a suggested remote host, nonstandard service, or arbitrary path.
        let metadata = xml.value(path + [(discovery, "XAddrs")])?
            .split(whereSeparator: \.isWhitespace).compactMap { URLComponents(string: String($0)) }
            .first { url in
                guard let uuid else { return false }
                return url.scheme == "http" && url.host == host && url.port == 5357
                    && url.path.lowercased() == "/\(uuid.uuidString.lowercased())"
                    && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            }?.url
        return Match(host: host, metadata: metadata, endpoint: uuid)
    }

    static func discover() -> AsyncStream<DiscoveredNetworkService> {
        AsyncStream { output in
            guard !OfflineMode.shared.isEnabled,
                  Bundle.main.object(forInfoDictionaryKey: "PlozzWindowsDiscoveryEnabled") as? Bool == true
            else { output.finish(); return }
            let worker = Task.detached(priority: .utility) {
                defer { output.finish() }
                await withTaskGroup(of: Void.self) { confirmations in
                    let id = UUID()
                    let interfaces = LocalSubnetScanner.localIPv4Interfaces()
                    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                    guard fd >= 0 else { return }
                    defer { close(fd) }
                    var target = sockaddr_in()
                    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    target.sin_family = sa_family_t(AF_INET)
                    target.sin_port = UInt16(3702).bigEndian
                    target.sin_addr.s_addr = inet_addr("239.255.255.250")
                    let packet = probe(id: id)
                    var seen = Set<UInt32>()
                    var buffer = [UInt8](repeating: 0, count: 16_385)
                    let clock = ContinuousClock()
                    let start = clock.now
                    var sends = 0
                    while clock.now < start + .seconds(3), !Task.isCancelled,
                          !OfflineMode.shared.isEnabled, seen.count < 24 {
                        if sends == 0 || (sends == 1 && clock.now >= start + .milliseconds(500)) {
                            var sent = false
                            for iface in interfaces {
                                var local = in_addr(s_addr: iface.address.bigEndian)
                                guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local, socklen_t(MemoryLayout.size(ofValue: local))) == 0 else { continue }
                                let result = withUnsafePointer(to: &target) { ptr in
                                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { dest in
                                        packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, dest, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                                    }
                                }
                                sent = sent || result == packet.count
                            }
                            guard sent else {
                                PlozzLog.networking.debug("Windows share discovery multicast unavailable")
                                return
                            }
                            sends += 1
                        }
                        var peer = sockaddr_in()
                        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let count = withUnsafeMutablePointer(to: &peer) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { source in
                                recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, source, &length)
                            }
                        }
                        if count < 0 {
                            guard errno == EAGAIN || errno == EINTR else { return }
                            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                            continue
                        }
                        let ip = UInt32(bigEndian: peer.sin_addr.s_addr)
                        guard count < buffer.count, !seen.contains(ip),
                              interfaces.contains(where: {
                                  $0.netmask != 0 && ($0.address & $0.netmask) == (ip & $0.netmask)
                                      && ip != $0.address && ip != ($0.address | ~$0.netmask)
                              }),
                              let candidate = match(Data(buffer.prefix(count)), id: id,
                                                    host: String(cString: inet_ntoa(peer.sin_addr)))
                        else { continue }
                        seen.insert(ip)
                        confirmations.addTask {
                            guard !Task.isCancelled, await confirmsSMB(host: candidate.host),
                                  !Task.isCancelled, !OfflineMode.shared.isEnabled else { return }
                            let name = await computerName(candidate) ?? candidate.host
                            guard !Task.isCancelled, !OfflineMode.shared.isEnabled else { return }
                            output.yield(.init(transport: .smb, name: name, host: candidate.host, port: nil))
                        }
                    }
                }
            }
            output.onTermination = { _ in worker.cancel() }
        }
    }

    private static func confirmsSMB(host: String) async -> Bool {
        // Read only the fixed SMB2 response header. An SMB error (e.g. minimum dialect
        // 3.1.1) also identifies the service; the real connection negotiates normally.
        let bytes = Negotiate.Request(messageId: 0, securityMode: [.signingEnabled],
                                      dialects: [.smb202, .smb210, .smb300, .smb302]).encoded()
        var size = UInt32(bytes.count).bigEndian
        let request = withUnsafeBytes(of: &size) { Data($0) } + bytes
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 445, using: .tcp)
        let queue = DispatchQueue(label: "com.plozz.wsd.confirm")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // All completion paths run on the connection's serial queue.
                let completion = DiscoveryCompletion(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            guard error == nil else { connection.cancel(); return }
                            connection.receive(minimumIncompleteLength: 68, maximumLength: 68) { data, _, _, _ in
                                completion.finish(isSMBReply(data))
                                connection.cancel()
                            }
                        })
                    case .failed, .cancelled: completion.finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 1.25) { connection.cancel() }
            }
        } onCancel: { connection.cancel() }
    }

    static func isSMBReply(_ data: Data?) -> Bool {
        guard let data, data.count == 68 else { return false }
        let bytes = [UInt8](data)
        return bytes[0] == 0 && (bytes[1] != 0 || bytes[2] != 0 || bytes[3] >= 64)
            && bytes[4..<10].elementsEqual([0xfe, 0x53, 0x4d, 0x42, 64, 0])
            && bytes[16] == 0 && bytes[17] == 0 && bytes[20] & 1 == 1
    }

    private final class DiscoveryCompletion: @unchecked Sendable {
        private var value: CheckedContinuation<Bool, Never>?
        init(_ value: CheckedContinuation<Bool, Never>) { self.value = value }
        func finish(_ result: Bool) { value?.resume(returning: result); value = nil }
    }

    private static func computerName(_ candidate: Match) async -> String? {
        guard let url = candidate.metadata, let uuid = candidate.endpoint else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 1.25
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = OfflineNetworkSession.make(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <s:Envelope xmlns:s="\(soap)" xmlns:a="\(addressing)"><s:Header>
        <a:Action>http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</a:Action>
        <a:To>urn:uuid:\(uuid.uuidString.lowercased())</a:To><a:MessageID>urn:uuid:\(UUID().uuidString)</a:MessageID>
        <a:ReplyTo><a:Address>\(addressing)/role/anonymous</a:Address></a:ReplyTo></s:Header><s:Body/></s:Envelope>
        """.utf8)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32_768 else { return nil }
                data.append(byte)
            }
            let mex = "http://schemas.xmlsoap.org/ws/2004/09/mex"
            let dp = "http://schemas.xmlsoap.org/ws/2006/02/devprof"
            let path = [envelope, body, (mex, "Metadata"), (mex, "MetadataSection"),
                        (dp, "Relationship"), (dp, "Host"), ("http://schemas.microsoft.com/windows/pub/2005/07", "Computer")]
            return xml(data)?.value(path)?.components(separatedBy: "/").first.flatMap {
                !$0.isEmpty && $0.count <= 63 && $0.rangeOfCharacter(from: .controlCharacters) == nil ? $0 : nil
            }
        } catch { return nil } // Metadata is optional; the verified IP is the fallback.
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private static let envelope = (soap, "Envelope"), header = (soap, "Header"), body = (soap, "Body")

    private static func xml(_ data: Data) -> XMLValues? {
        guard data.count <= 32_768, let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.utf8.contains(0) else { return nil }
        let parser = XMLParser(data: data)
        let values = XMLValues()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = values
        return parser.parse() ? values : nil
    }

    private final class XMLValues: NSObject, XMLParserDelegate {
        private var path: [String] = []
        private var text = ""
        private var values: [[String]: String] = [:]
        func value(_ path: [(String, String)]) -> String? { values[path.map { "\($0.0)#\($0.1)" }] }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard path.count < 16 else { parser.abortParsing(); return }
            path.append("\(namespaceURI ?? "")#\(elementName)")
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if !text.isEmpty { values[path] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            _ = path.popLast()
            text = ""
        }
    }
}
#endif
