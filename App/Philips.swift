// Built-in driver for Philips TVs that speak JointSpace API v6
// (HTTPS on port 1926, HTTP digest auth after PIN pairing).
//
// The TV address is never hard-coded: the saved address is tried first, then the local
// subnets are scanned. PHILIPS_TV_HOST overrides the address (same as philips.py).
//
// philips.py keeps its credentials in ~/.config/philips-tv/config.json. The app imports a TV
// paired there and keeps that file pointed at the Philips TV currently in use.

import CryptoKit
import Foundation

// MARK: - Driver

@MainActor
final class PhilipsDriver: TVDriver {
    nonisolated static let kind = "philips"

    let id = PhilipsDriver.kind
    let name = "Philips"
    let info = DriverInfo(
        works: [
            "Philips TVs with Titan OS: the 2024 and later LCD Ambilight ranges, e.g. PUS7009, "
                + "PUS8009, PUS8079, PUS8109, PUS8309 and The One PUS8919. Tested on 65PUS8919.",
            "Philips Android TV and Google TV sets (about 2016 onwards) that answer on port 1926. "
                + "Same API and pairing, but not tested.",
        ],
        doesNotWork: [
            "Philips TVs from before 2016 (older JointSpace on port 1925, no PIN pairing).",
            "On Titan OS: app list and HDMI input switching (the TV answers HTTP 403).",
        ],
        notes: [
            "The TV must be on and on the same network for pairing; it shows a PIN on screen.",
            "Power on from standby works only while the TV keeps its network up in standby.",
        ]
    )

    private var pending: TVPairing.Pending?
    private var pendingTV: FoundTV?

    func status() async -> DriverStatus { .ready }

    func discover() async -> [FoundTV] {
        await TVDiscovery.findAll().map(Self.found)
    }

    func probe(host: String) async -> FoundTV? {
        guard let info = await TVDiscovery.probe(host) else { return nil }
        return Self.found(TVDiscovery.Hit(host: host, info: info))
    }

    func beginPairing(_ tv: FoundTV) async throws -> String? {
        pending = try await TVPairing.request(host: tv.host, deviceid: tv.deviceID == tv.host ? nil : tv.deviceID)
        pendingTV = tv
        return "Enter the PIN shown on \(tv.name)."
    }

    func finishPairing(pin: String) async throws -> StoredTV {
        guard let pending, let tv = pendingTV else { throw TVError.pairing("Start pairing first.") }
        let config = try await TVPairing.grant(pending, pin: pin)
        self.pending = nil
        return Self.stored(config, name: tv.name)
    }

    func cancelPairing() async {
        pending = nil
        pendingTV = nil
    }

    func connect(_ tv: StoredTV) -> any TVConnection {
        PhilipsConnection(tv)
    }

    // MARK: Conversions

    private static func found(_ hit: TVDiscovery.Hit) -> FoundTV {
        FoundTV(driver: kind, deviceID: hit.deviceid ?? hit.host, name: hit.name, host: hit.host,
                model: hit.info["model"] as? String)
    }

    nonisolated static func stored(_ c: Config, name: String) -> StoredTV {
        var data = ["device_id": c.device_id, "auth_key": c.auth_key]
        data["deviceid"] = c.deviceid
        return StoredTV(id: "\(kind):\(c.deviceid ?? c.host)", driver: kind, name: name, host: c.host, data: data)
    }

    nonisolated static func config(_ tv: StoredTV) -> Config {
        Config(host: tv.host, deviceid: tv.data["deviceid"],
               device_id: tv.data["device_id"] ?? "", auth_key: tv.data["auth_key"] ?? "")
    }

    // MARK: philips.py config

    nonisolated static let cliConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/philips-tv/config.json")

    /// The TV paired with philips.py, if any.
    nonisolated static func cliTV() -> StoredTV? {
        guard let data = try? Data(contentsOf: cliConfigPath),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return nil }
        return stored(cfg, name: cfg.name ?? "Philips TV")
    }

    nonisolated static func writeCLIConfig(_ tv: StoredTV) {
        var cfg = config(tv)
        cfg.name = tv.name
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        try? FileManager.default.createDirectory(
            at: cliConfigPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cliConfigPath, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cliConfigPath.path)
    }

    /// Forgetting a TV in the app also removes it from philips.py, or it would come back.
    nonisolated static func forgetCLIConfig(_ tv: StoredTV) {
        if cliTV()?.id == tv.id {
            try? FileManager.default.removeItem(at: cliConfigPath)
        }
    }
}

// MARK: - Connection

@MainActor
final class PhilipsConnection: TVConnection {
    private(set) var tv: StoredTV
    private let client: TVClient

    let actions = Set(RemoteAction.allCases).subtracting(RemoteAction.appLevel).subtracting([.ambilight, .keyboard])
    let supportsAbsoluteVolume = true

    private static let styles = ["OFF", "FOLLOW_VIDEO", "FOLLOW_AUDIO", "FOLLOW_COLOR"]

    init(_ tv: StoredTV) {
        self.tv = tv
        var cfg = PhilipsDriver.config(tv)
        if let env = ProcessInfo.processInfo.environment["PHILIPS_TV_HOST"], !env.isEmpty {
            cfg.host = env
        }
        client = TVClient(config: cfg)
    }

    func perform(_ action: RemoteAction, state: TVState) async throws {
        switch action {
        case .power:
            try await client.post("powerstate", ["powerstate": state.power == "On" ? "Standby" : "On"])
        default:
            guard let key = Self.keys[action] else { return }
            try await client.post("input/key", ["key": key])
        }
    }

    /// Separate Play and Pause keys: Titan OS ignores "PlayPause".
    private static let keys: [RemoteAction: String] = [
        .up: "CursorUp", .down: "CursorDown", .left: "CursorLeft", .right: "CursorRight",
        .ok: "Confirm", .back: "Back", .home: "Home",
        .options: "Options", .info: "Info", .source: "Source",
        .play: "Play", .pause: "Pause", .rewind: "Rewind", .forward: "FastForward",
        .volumeUp: "VolumeUp", .volumeDown: "VolumeDown", .mute: "Mute",
    ]

    func setVolume(_ value: Int) async throws {
        try await client.post("audio/volume", ["muted": false, "current": value])
    }

    func pick(_ picker: String, option: String) async throws {
        guard picker == "ambilight" else { return }
        if option == "OFF" {
            try await client.post("ambilight/power", ["power": "Off"])
        } else {
            try await client.post("ambilight/power", ["power": "On"])
            try await client.post("ambilight/currentconfiguration", ["styleName": option, "isExpert": false])
        }
    }

    /// JointSpace has no text input.
    func sendText(_ text: String, previous: String, submit: Bool) async throws {
        throw TVError.failed("This TV cannot take typed text.")
    }

    func readText() async -> String? { nil }

    func readState() async throws -> TVState {
        let p = try await client.get("powerstate")
        let v = try await client.get("audio/volume")
        // Not every TV has Ambilight.
        let a = try? await client.get("ambilight/currentconfiguration")

        var state = TVState()
        state.power = p["powerstate"] as? String ?? "—"
        state.volume = v["current"] as? Int ?? 0
        state.volumeMax = v["max"] as? Int ?? 60
        state.muted = v["muted"] as? Bool ?? false
        if let style = a?["styleName"] as? String {
            var options = Self.styles.map {
                TVPicker.Option(id: $0, title: $0.replacingOccurrences(of: "FOLLOW_", with: "").capitalized)
            }
            if !Self.styles.contains(style) {
                options.append(.init(id: style, title: style.capitalized))
            }
            state.picker = TVPicker(id: "ambilight", label: "Ambilight", symbol: "lightbulb.led",
                                    options: options, current: style)
        }
        return state
    }

    func relocate() async -> StoredTV? {
        guard await client.ensureReachable() else { return nil }
        tv.host = client.config.host
        tv.data["deviceid"] = client.config.deviceid
        return tv
    }

    func close() {}
}

// MARK: - Config

struct Config: Codable {
    var host: String
    var deviceid: String?          // `deviceid_encrypted` from /6/system; pins one specific TV
    let device_id: String          // digest auth user
    let auth_key: String           // digest auth password
    var name: String? = nil
}

// MARK: - TV client

final class TVClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let port = 1926
    static let api = 6

    private(set) var config: Config
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(config: Config) {
        self.config = config
        super.init()
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://\(config.host):\(Self.port)/\(Self.api)/\(path)")!
    }

    @discardableResult
    func get(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: url(path))
        req.timeoutInterval = 6
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw TVError.unauthorized }
        guard (200..<300).contains(code) else { throw TVError.http(code) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// POST with a JSON body. Only 401 is treated as an error: the TV answers 200 even for
    /// unknown keys, so the status code says little about whether a command did anything.
    func post(_ path: String, _ body: [String: Any]) async throws {
        let (code, _) = try await postJSON(path, body)
        if code == 401 { throw TVError.unauthorized }
    }

    /// POST that also returns the status code and the decoded reply (used by pairing).
    func postJSON(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (code, json)
    }

    /// Checks the current address; if it stays silent, scans the network for this TV.
    /// Returns true if the client knows where the TV is afterwards.
    func ensureReachable() async -> Bool {
        if await TVDiscovery.probe(config.host) != nil { return true }
        // An address from the environment is a deliberate choice: never overwrite it with a scan.
        if let env = ProcessInfo.processInfo.environment["PHILIPS_TV_HOST"], env == config.host {
            return false
        }
        guard let found = await TVDiscovery.find(deviceid: config.deviceid) else { return false }
        config.host = found.host
        config.deviceid = found.deviceid ?? config.deviceid
        return true
    }

    // The TV uses a self-signed certificate; it is accepted on purpose (LAN only).
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // Digest auth: user = device_id, password = auth_key.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(user: config.device_id, password: config.auth_key, persistence: .forSession)
        )
    }
}

// MARK: - Pairing

/// JointSpace v6 PIN pairing: `pair/request` makes the TV show a PIN, `pair/grant` confirms it.
enum TVPairing {
    /// Shared JointSpace v6 key. Publicly known: it ships inside Philips' own remote app.
    private static let secretKey = SymmetricKey(data: Data(base64Encoded:
        "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==")!)

    struct Pending {
        let host: String
        let deviceid: String?
        let device: [String: String]
        let authKey: String
        let timestamp: Int
        let timeout: Int
    }

    /// Step 1: ask the TV to pair. On success it shows a PIN on screen.
    static func request(host: String, deviceid: String?) async throws -> Pending {
        let id = String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let device: [String: String] = [
            "id": id,
            "app_id": "app.id",
            "app_name": "TV Remote for Mac",
            "type": "native",
            "device_name": Host.current().localizedName ?? "Mac",
            // The value Philips' own app sends; TVs are known to accept it.
            "device_os": "Android",
        ]
        // No credentials yet: the client is only used for its TLS handling.
        let client = TVClient(config: Config(host: host, deviceid: deviceid, device_id: id, auth_key: ""))
        let (code, reply) = try await client.postJSON(
            "pair/request", ["scope": ["read", "write", "control"], "device": device])
        guard code == 200, reply["error_id"] as? String == "SUCCESS",
              let authKey = reply["auth_key"] as? String,
              let timestamp = (reply["timestamp"] as? NSNumber)?.intValue
        else {
            let reason = reply["error_text"] as? String ?? reply["error_id"] as? String ?? "HTTP \(code)"
            throw TVError.pairing("The TV refused to pair (\(reason)). Make sure it is switched on.")
        }
        return Pending(host: host, deviceid: deviceid, device: device, authKey: authKey,
                       timestamp: timestamp, timeout: (reply["timeout"] as? Int) ?? 60)
    }

    /// Step 2: confirm the PIN and return the credentials to save.
    ///
    /// Platforms compute `auth_signature` differently:
    /// Titan OS signs with base64(raw HMAC-SHA1 digest), Android TV with base64(hex digest).
    /// Both are tried within the same pairing window; a failed grant does not cancel it
    /// (verified on Titan OS).
    static func grant(_ p: Pending, pin: String) async throws -> Config {
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data("\(p.timestamp)\(pin)".utf8), using: secretKey)
        let raw = Data(mac).base64EncodedString()
        let hex = Data(mac.map { String(format: "%02x", $0) }.joined().utf8).base64EncodedString()

        let config = Config(host: p.host, deviceid: p.deviceid, device_id: p.device["id"]!, auth_key: p.authKey)
        let client = TVClient(config: config)
        var lastError = "unknown error"
        for signature in [raw, hex] {
            let body: [String: Any] = [
                "auth": [
                    "auth_AppId": "1",
                    "pin": pin,
                    "auth_timestamp": p.timestamp,
                    "auth_signature": signature,
                ],
                "device": p.device,
            ]
            let (code, reply) = try await client.postJSON("pair/grant", body)
            if code == 200, reply["error_id"] as? String == "SUCCESS" {
                return config
            }
            lastError = reply["error_id"] as? String ?? "HTTP \(code)"
        }
        if lastError == "INVALID_PIN" {
            throw TVError.pairing("Wrong PIN, or the pairing window has expired. Try again.")
        }
        throw TVError.pairing("Pairing failed (\(lastError)).")
    }
}

// MARK: - Network scan

enum TVDiscovery {
    struct Hit: Identifiable {
        let host: String
        let info: [String: Any]
        var id: String { host }
        var name: String { info["name"] as? String ?? "Philips TV" }
        var deviceid: String? { info["deviceid_encrypted"] as? String }
    }

    /// Separate session without digest auth: /6/system needs no authentication.
    private final class TrustAll: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: cfg, delegate: TrustAll(), delegateQueue: nil)
    }()

    /// Scans port 1926 on many addresses at once: a single `poll()` over all non-blocking
    /// sockets. A whole /24 takes ~1 s and does not tie up the Swift Concurrency thread pool
    /// (a blocking per-host `connect` could take 8 s).
    static func openPorts(_ hosts: [String], timeout: TimeInterval = 1.0) -> [String] {
        var open: [String] = []
        // The default per-process descriptor limit is 256, so go in chunks of 128.
        for chunk in stride(from: 0, to: hosts.count, by: 128).map({
            Array(hosts[$0..<min($0 + 128, hosts.count)])
        }) {
            var fds: [Int32] = []
            var owner: [Int32: String] = [:]

            for host in chunk {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(TVClient.port).bigEndian
                guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { continue }

                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc != 0 && errno != EINPROGRESS {
                    close(fd)
                    continue
                }
                fds.append(fd)
                owner[fd] = host
                if rc == 0 { open.append(host) }
            }
            defer { fds.forEach { close($0) } }

            var pending = Set(fds)
            let deadline = Date().addingTimeInterval(timeout)
            while !pending.isEmpty, Date() < deadline {
                var poll_fds = pending.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
                let ms = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                guard poll(&poll_fds, nfds_t(poll_fds.count), ms) > 0 else { break }
                for entry in poll_fds where entry.revents != 0 {
                    pending.remove(entry.fd)
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0,
                       let host = owner[entry.fd], !open.contains(host) {
                        open.append(host)
                    }
                }
            }
        }
        return open
    }

    /// Does a JointSpace TV answer at this address? Returns the /6/system body or nil.
    static func probe(_ host: String) async -> [String: Any]? {
        guard let url = URL(string: "https://\(host):\(TVClient.port)/\(TVClient.api)/system")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await probeSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["name"] != nil, json["api_version"] != nil
        else { return nil }
        return json
    }

    /// All JointSpace TVs on the local subnets, sorted by address.
    static func findAll() async -> [Hit] {
        let targets = localTargets()
        guard !targets.isEmpty else { return [] }

        // Phase 1 (fast): who listens on 1926 at all.
        let candidates = await Task.detached(priority: .userInitiated) {
            openPorts(targets)
        }.value
        guard !candidates.isEmpty else { return [] }

        // Phase 2: only now pay for TLS; there are usually just 1-2 candidates.
        var hits: [Hit] = []
        await withTaskGroup(of: Hit?.self) { group in
            for host in candidates {
                group.addTask {
                    guard let info = await probe(host) else { return nil }
                    return Hit(host: host, info: info)
                }
            }
            for await hit in group {
                if let hit { hits.append(hit) }
            }
        }
        return hits.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }

    /// The paired TV: the exact unit when `deviceid` matches, otherwise the first one found
    /// (a wrong guess is harmless: its credentials will not match and requests get a 401).
    static func find(deviceid: String? = nil) async -> Hit? {
        let hits = await findAll()
        if let want = deviceid, let exact = hits.first(where: { $0.deviceid == want }) {
            return exact
        }
        return hits.first
    }

    /// Addresses to scan, derived from the local IPv4 interfaces.
    private static func localTargets() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for (ip, mask) in localIPv4Networks() {
            for host in hosts(ip: ip, mask: mask) where host != ip && !seen.contains(host) {
                seen.insert(host)
                out.append(host)
            }
        }
        return out
    }

    private static func localIPv4Networks() -> [(String, String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmask = cur.pointee.ifa_netmask
            else { continue }

            func text(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buf)
            }
            if let ip = text(addr), let mask = text(netmask), !ip.hasPrefix("169.254.") {
                result.append((ip, mask))
            }
        }
        return result
    }

    private static func hosts(ip: String, mask: String) -> [String] {
        func packed(_ s: String) -> UInt32? {
            let p = s.split(separator: ".").compactMap { UInt8($0) }
            guard p.count == 4 else { return nil }
            return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
        }
        guard let a = packed(ip), var m = packed(mask) else { return [] }
        // Networks wider than /22 are narrowed to the /24 around us; scanning a /16 makes no sense.
        if m.nonzeroBitCount < 22 { m = 0xFFFF_FF00 }
        let base = a & m
        let count = UInt32(1) << (32 - UInt32(m.nonzeroBitCount))
        guard count <= 1024 else { return [] }

        var out: [String] = []
        out.reserveCapacity(Int(count))
        for i in 1..<max(count, 2) - 1 {
            let v = base + i
            out.append("\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)")
        }
        return out
    }
}
