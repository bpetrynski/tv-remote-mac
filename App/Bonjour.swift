// Bonjour discovery for script drivers, done by the app through the system's mDNSResponder.
// Drivers then only get addresses and make outgoing connections: no driver process listens
// on a port, so the macOS firewall never asks about Python, and Local Network access is
// granted once, to the app.

import Foundation
import Network

enum Bonjour {
    /// IPv4 addresses of services of the given types (e.g. "_companion-link._tcp") seen
    /// within `seconds`.
    static func hosts(types: [String], seconds: Double = 2.0) async -> [String] {
        guard !types.isEmpty else { return [] }
        let endpoints = await browse(types: types, seconds: seconds)
        var hosts = Set<String>()
        await withTaskGroup(of: String?.self) { group in
            for endpoint in endpoints {
                group.addTask { await resolve(endpoint) }
            }
            for await host in group {
                if let host { hosts.insert(host) }
            }
        }
        return hosts.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Thread-safe box for results collected from Network framework callbacks.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func update(_ change: (inout T) -> Void) {
            lock.lock()
            change(&value)
            lock.unlock()
        }
        var current: T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func browse(types: [String], seconds: Double) async -> [NWEndpoint] {
        let found = Box<[NWEndpoint]>([])
        let queue = DispatchQueue(label: "bonjour.browse")
        let browsers = types.map { NWBrowser(for: .bonjour(type: $0, domain: "local."), using: .tcp) }
        for browser in browsers {
            browser.browseResultsChangedHandler = { results, _ in
                found.update { list in
                    for r in results where !list.contains(r.endpoint) { list.append(r.endpoint) }
                }
            }
            browser.start(queue: queue)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browsers.forEach { $0.cancel() }
        return found.current
    }

    /// The IPv4 address behind a service: a short TCP connection reveals where it went.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: params)
        let done = Box(false)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            @Sendable func finish(_ host: String?) {
                var first = false
                done.update { if !$0 { $0 = true; first = true } }
                guard first else { return }
                connection.cancel()
                cont.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let addr) = host {
                        finish(addr.debugDescription.components(separatedBy: "%").first)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "bonjour.resolve"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }
}
