// External drivers: a folder with `driver.json` and a program in any language that reads
// JSON requests from stdin and writes JSON replies to stdout, one per line. The protocol is
// described in DRIVERS.md. One process per driver, started on first use and kept running,
// so a key press costs a pipe write, not a process launch.

import Foundation

// MARK: - Manifest

/// An optional feature of a driver (driver.json "options"), switched on in Settings.
struct DriverOption: Decodable, Hashable {
    let id: String
    let title: String
    let help: String?
}

struct DriverManifest: Decodable {
    let id: String
    let name: String
    /// Candidate command lines; the first whose program exists is used. "~" is expanded,
    /// bare program names are looked up in PATH and the usual Homebrew folders, and
    /// "{python}" is the driver's own Python environment (see `requirements`).
    let run: [[String]]
    /// Python packages for "{python}". The app installs them into a private environment
    /// (Settings → Supported TVs → Install), so users never touch pip.
    let requirements: [String]?
    /// Bonjour service types the app browses for this driver; `discover` then gets the
    /// addresses found (`hosts`) instead of searching itself.
    let bonjour: [String]?
    let works: [String]
    let doesNotWork: [String]?
    let notes: [String]?
    let installHint: String?
    /// Switches in Settings → Supported TVs, off until the user turns them on.
    let options: [DriverOption]?

    enum CodingKeys: String, CodingKey {
        case id, name, run, works, notes, requirements, bonjour, options
        case doesNotWork = "does_not_work"
        case installHint = "install_hint"
    }
}

// MARK: - Process

/// A running driver program. Requests carry an `id`; replies are matched back by it.
final class DriverProcess: @unchecked Sendable {
    /// Wraps a decoded JSON value so it can cross the continuation.
    struct Reply: @unchecked Sendable { let value: Any? }

    private let process = Process()
    private let stdin: FileHandle
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var nextID = 0
    private var buffer = Data()

    var isRunning: Bool { process.isRunning }

    init(command: [String], folder: URL, data: URL, log: URL) throws {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = folder
        // Where the driver keeps its own files (certificates, caches).
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["TVREMOTE_DATA"] = data.path
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // stderr goes to a log file, rewritten on every launch.
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: log.path) ?? FileHandle.nullDevice
        stdin = input.fileHandleForWriting

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.failAll(TVError.driver("The driver stopped. See its log for details."))
        }
        try process.run()
    }

    func call(_ op: String, _ params: [String: Any], timeout: TimeInterval) async throws -> Any? {
        let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Reply, Error>) in
            lock.lock()
            nextID += 1
            let id = nextID
            pending[id] = cont
            lock.unlock()

            var message = params
            message["id"] = id
            message["op"] = op
            guard var data = try? JSONSerialization.data(withJSONObject: message) else {
                resolve(id, .failure(TVError.driver("Could not encode a request for the driver.")))
                return
            }
            data.append(0x0A)
            do {
                try stdin.write(contentsOf: data)
            } catch {
                resolve(id, .failure(TVError.driver("The driver is not running.")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(TVError.failed("The TV did not answer in time.")))
            }
        }
        return reply.value
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private func resolve(_ id: Int, _ result: Result<Reply, Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = (msg["id"] as? NSNumber)?.intValue
            else { continue }
            if msg["ok"] as? Bool == true {
                let value = msg["result"]
                resolve(id, .success(Reply(value: value is NSNull ? nil : value)))
            } else {
                let text = msg["error"] as? String ?? "The driver reported an error."
                let error: TVError = switch msg["code"] as? String {
                case "unavailable": .driver(text)
                case "unauthorized": .unauthorized
                case "not_connected": .failed("not_connected")
                default: .failed(text)
                }
                resolve(id, .failure(error))
            }
        }
    }
}

// MARK: - Driver

@MainActor
final class ScriptDriver: TVDriver {
    let manifest: DriverManifest
    let folder: URL
    private var process: DriverProcess?
    /// Bumped on every (re)start, so connections know their session in the driver is gone.
    private(set) var generation = 0
    private var pairingTV: FoundTV?

    var id: String { manifest.id }
    var name: String { manifest.name }
    /// A TV's values of the driver's options (off unless switched on), sent with `connect`
    /// and `pair_begin`.
    func optionValues(_ chosen: [String: Bool]?) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: (manifest.options ?? []).map { ($0.id, chosen?[$0.id] ?? false) })
    }

    var info: DriverInfo {
        DriverInfo(works: manifest.works, doesNotWork: manifest.doesNotWork ?? [], notes: manifest.notes ?? [])
    }

    init(manifest: DriverManifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
    }

    /// Drivers bundled with the app, then the user's own (a user driver with the same id wins).
    static func loadAll() -> [ScriptDriver] {
        var byID: [String: ScriptDriver] = [:]
        var order: [String] = []
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("Drivers"), Drivers.userFolder]
        for root in roots.compactMap({ $0 }) {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("driver.json")),
                      let manifest = try? JSONDecoder().decode(DriverManifest.self, from: data),
                      manifest.id != PhilipsDriver.kind
                else { continue }
                if byID[manifest.id] == nil { order.append(manifest.id) }
                byID[manifest.id] = ScriptDriver(manifest: manifest, folder: dir)
            }
        }
        return order.compactMap { byID[$0] }
    }

    // MARK: Process

    /// The driver's private Python environment, used for "{python}".
    var environment: URL { TVStore.folder.appendingPathComponent("Python/\(id)") }
    var needsInstall: Bool {
        let reqs = manifest.requirements ?? []
        guard !reqs.isEmpty else { return false }
        guard let cmd = command() else { return true }
        // The private environment predates a change of driver.json: install the new packages.
        return cmd[0] == python && installed != reqs
    }

    private var python: String { environment.appendingPathComponent("bin/python").path }
    /// Requirements the private environment was last filled with.
    private var stamp: URL { environment.appendingPathComponent("tvremote-requirements.json") }
    private var installed: [String]? {
        (try? Data(contentsOf: stamp)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    private static func which(_ program: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin"]
        return path.lazy.map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func command() -> [String]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in manifest.run where !candidate.isEmpty {
            var cmd = candidate.map {
                $0 == "{python}" ? python : $0.hasPrefix("~/") ? home + $0.dropFirst() : $0
            }
            if cmd[0].contains("/") {
                if FileManager.default.isExecutableFile(atPath: cmd[0]) { return cmd }
            } else if let found = Self.which(cmd[0]) {
                cmd[0] = found
                return cmd
            }
        }
        return nil
    }

    private func running() throws -> DriverProcess {
        if let process, process.isRunning { return process }
        guard let cmd = command() else {
            throw TVError.driver("\(name) needs software that is not installed"
                + (manifest.installHint.map { ". \($0)" } ?? "."))
        }
        let p = try DriverProcess(command: cmd, folder: folder,
                                  data: TVStore.folder.appendingPathComponent(id), log: log)
        process = p
        generation += 1
        return p
    }

    var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TV Remote/\(id).log")
    }

    /// Creates the private Python environment with the driver's packages: with uv when it is
    /// there (it brings a suitable Python along), otherwise with python3 -m venv and pip.
    func install() async throws {
        let reqs = manifest.requirements ?? []
        guard !reqs.isEmpty else { return }
        process?.stop()
        process = nil
        let env = environment.path
        let steps: [[String]]
        if let uv = Self.which("uv") {
            steps = [[uv, "venv", "--allow-existing", "--python", "3.12", env],
                     [uv, "pip", "install", "--python", "\(env)/bin/python"] + reqs]
        } else if let python = Self.which("python3") {
            steps = [[python, "-m", "venv", env],
                     ["\(env)/bin/python", "-m", "pip", "install", "--upgrade"] + reqs]
        } else {
            throw TVError.driver("Python 3 is needed to install this driver.")
        }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logPath = log.path
        try await Task.detached {
            for step in steps {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: step[0])
                p.arguments = Array(step.dropFirst())
                let out = FileHandle(forWritingAtPath: logPath)
                out?.seekToEndOfFile()
                p.standardOutput = out ?? FileHandle.nullDevice
                p.standardError = out ?? FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    throw TVError.driver("Installing failed. Details: \(logPath)")
                }
            }
        }.value
        try? JSONEncoder().encode(reqs).write(to: stamp)
    }

    func call(_ op: String, _ params: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> Any? {
        try await running().call(op, params, timeout: timeout)
    }

    // MARK: TVDriver

    func status() async -> DriverStatus {
        do {
            let r = try await call("hello", timeout: 10) as? [String: Any]
            if r?["ready"] as? Bool == false {
                return .unavailable(r?["error"] as? String ?? "Not ready.")
            }
            return .ready
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func discover() async -> [FoundTV] {
        var params: [String: Any] = [:]
        if let types = manifest.bonjour, !types.isEmpty {
            let hosts = await Bonjour.hosts(types: types)
            guard !hosts.isEmpty else { return [] }
            params["hosts"] = hosts
        }
        let list = (try? await call("discover", params, timeout: 15)) as? [[String: Any]] ?? []
        return list.compactMap(found)
    }

    func probe(host: String) async -> FoundTV? {
        let list = (try? await call("discover", ["hosts": [host]], timeout: 10)) as? [[String: Any]] ?? []
        return list.compactMap(found).first
    }

    private func found(_ d: [String: Any]) -> FoundTV? {
        guard let deviceID = d["id"] as? String, let host = d["host"] as? String else { return nil }
        return FoundTV(driver: id, deviceID: deviceID, name: d["name"] as? String ?? name,
                       host: host, model: d["model"] as? String)
    }

    func beginPairing(_ tv: FoundTV) async throws -> String? {
        let r = try await call("pair_begin", ["tv": ["id": tv.deviceID, "host": tv.host],
                                              "options": optionValues(RemoteModel.shared.tvs.first { $0.id == tv.id }?.options)],
                         timeout: 30) as? [String: Any]
        pairingTV = tv
        if r?["paired"] as? Bool == true { return nil }
        return r?["prompt"] as? String ?? "Enter the PIN shown on \(tv.name)."
    }

    func finishPairing(pin: String) async throws -> StoredTV {
        guard let tv = pairingTV else { throw TVError.pairing("Start pairing first.") }
        let r = try await call("pair_finish", ["pin": pin], timeout: 30) as? [String: Any]
        if r?["data"] == nil, let prompt = r?["prompt"] as? String {
            throw TVError.anotherPin(prompt)
        }
        pairingTV = nil
        var data = r?["data"] as? [String: String] ?? [:]
        data["id"] = tv.deviceID
        return StoredTV(id: tv.id, driver: id, name: r?["name"] as? String ?? tv.name,
                        host: r?["host"] as? String ?? tv.host, data: data)
    }

    func cancelPairing() async {
        pairingTV = nil
        _ = try? await call("pair_cancel", timeout: 5)
    }

    func connect(_ tv: StoredTV) -> any TVConnection {
        ScriptConnection(driver: self, tv: tv)
    }
}

// MARK: - Connection

@MainActor
final class ScriptConnection: TVConnection {
    private let driver: ScriptDriver
    private var tv: StoredTV
    private(set) var actions: Set<RemoteAction> = []
    let supportsAbsoluteVolume = false
    /// `driver.generation` at connect time; a restarted driver has forgotten us.
    private var session = -1
    private var connecting: Task<Void, Error>?

    init(driver: ScriptDriver, tv: StoredTV) {
        self.driver = driver
        self.tv = tv
    }

    private var payload: [String: Any] {
        ["id": tv.data["id"] ?? tv.id, "host": tv.host, "name": tv.name, "data": tv.data]
    }

    private func ensureConnected() async throws {
        if session == driver.generation, driver.generation > 0 { return }
        // Status reads and key presses may arrive together: connect once.
        if let connecting { return try await connecting.value }
        let task = Task { @MainActor in
            let r = try await driver.call("connect", ["tv": payload, "options": driver.optionValues(tv.options)],
                                          timeout: 30) as? [String: Any]
            actions = Set((r?["actions"] as? [String] ?? []).compactMap(RemoteAction.init(rawValue:)))
            if let host = r?["host"] as? String { tv.host = host }
            session = driver.generation
        }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    /// One call; when the driver says the link is gone (the TV restarted), reconnect once.
    private func call(_ op: String, _ params: [String: Any] = [:]) async throws -> Any? {
        try await ensureConnected()
        do {
            return try await driver.call(op, params)
        } catch TVError.failed("not_connected") {
            session = -1
            try await ensureConnected()
            return try await driver.call(op, params)
        }
    }

    func perform(_ action: RemoteAction, state: TVState) async throws {
        _ = try await call("action", ["action": action.rawValue])
    }

    func setVolume(_ value: Int) async throws {
        _ = try await call("volume", ["value": value])
    }

    func pick(_ picker: String, option: String) async throws {
        _ = try await call("pick", ["picker": picker, "option": option])
    }

    func sendText(_ text: String, previous: String, submit: Bool) async throws {
        _ = try await call("text", ["text": text, "previous": previous, "submit": submit])
    }

    func readText() async -> String? {
        ((try? await call("text_get")) as? [String: Any])?["text"] as? String
    }

    func readState() async throws -> TVState {
        let r = try await call("status") as? [String: Any] ?? [:]
        var state = TVState()
        state.power = r["power"] as? String ?? "—"
        state.volume = (r["volume"] as? NSNumber)?.intValue
        state.volumeMax = (r["volume_max"] as? NSNumber)?.intValue ?? 100
        state.muted = r["muted"] as? Bool ?? false
        state.playing = r["playing"] as? Bool
        if let p = r["picker"] as? [String: Any], let pid = p["id"] as? String {
            let options = (p["options"] as? [[String: Any]] ?? []).compactMap { o -> TVPicker.Option? in
                guard let oid = o["id"] as? String else { return nil }
                return TVPicker.Option(id: oid, title: o["title"] as? String ?? oid, icon: o["icon"] as? String)
            }
            state.picker = TVPicker(id: pid, label: p["label"] as? String ?? pid,
                                    symbol: p["symbol"] as? String ?? "list.bullet",
                                    options: options, current: p["current"] as? String,
                                    recent: p["recent"] as? [String] ?? [],
                                    active: p["active"] as? String)
        }
        return state
    }

    /// Reconnects; if the TV is not at its saved address, finds it again by its id.
    func relocate() async -> StoredTV? {
        session = -1
        if (try? await ensureConnected()) != nil { return tv }
        let want = (tv.data["id"] ?? "").lowercased()
        guard let match = await driver.discover().first(where: { $0.deviceID.lowercased() == want }),
              match.host != tv.host
        else { return nil }
        tv.host = match.host
        return (try? await ensureConnected()) != nil ? tv : nil
    }

    func close() {
        guard session == driver.generation else { return }
        let driver = driver
        Task { _ = try? await driver.call("disconnect", timeout: 5) }
    }
}
