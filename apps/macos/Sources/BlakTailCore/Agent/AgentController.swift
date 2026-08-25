import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        }
    }
}

public struct AgentStatus: Equatable, Sendable {
    public var connected: Bool
    public var nodeID: String?
    public var address: String?
    public var coordinator: String?

    public static let disconnected = AgentStatus(connected: false, nodeID: nil, address: nil, coordinator: nil)

    public init(connected: Bool, nodeID: String?, address: String?, coordinator: String?) {
        self.connected = connected
        self.nodeID = nodeID
        self.address = address
        self.coordinator = coordinator
    }

    /// Parses `blaktaild status` stdout. Join keys never appear in this output.
    public static func parse(_ output: String) -> AgentStatus {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "joined" }) else {
            return .disconnected
        }
        var nodeID: String?
        var address: String?
        var coordinator: String?
        for line in lines {
            if line.hasPrefix("node: ") {
                nodeID = String(line.dropFirst("node: ".count))
            } else if line.hasPrefix("address: ") {
                address = String(line.dropFirst("address: ".count))
            } else if line.hasPrefix("coordinator: ") {
                coordinator = String(line.dropFirst("coordinator: ".count))
            }
        }
        return AgentStatus(connected: true, nodeID: nodeID, address: address, coordinator: coordinator)
    }
}

public enum AgentControllerError: LocalizedError, Sendable {
    case agentMissing
    case privilegeRequired
    case failed(String)
    case joinKeyMustNotAppearInArguments

    public var errorDescription: String? {
        switch self {
        case .agentMissing:
            return "blaktaild was not found at /usr/local/bin/blaktaild. Install the Mac agent first."
        case .privilegeRequired:
            return "Administrator access is required to start the local agent."
        case .failed(let message):
            return message
        case .joinKeyMustNotAppearInArguments:
            return "Internal error: join key must not be passed on the command line."
        }
    }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], stdin: Data?, privileged: Bool) throws -> ProcessResult
}

/// Drives local `blaktaild` and the LaunchDaemon. Join keys travel only on stdin (or a scrubbed temp file for elevated runs).
public struct AgentController: Sendable {
    public var agentPath: String
    public var launchDaemonLabel: String
    public var launchDaemonPlist: String
    public var runner: any ProcessRunner

    public static let `default` = AgentController(
        agentPath: "/usr/local/bin/blaktaild",
        launchDaemonLabel: "com.blaktail.agent",
        launchDaemonPlist: "/Library/LaunchDaemons/com.blaktail.agent.plist",
        runner: FoundationProcessRunner()
    )

    public init(
        agentPath: String,
        launchDaemonLabel: String,
        launchDaemonPlist: String,
        runner: any ProcessRunner
    ) {
        self.agentPath = agentPath
        self.launchDaemonLabel = launchDaemonLabel
        self.launchDaemonPlist = launchDaemonPlist
        self.runner = runner
    }

    /// Arguments for `blaktaild up`. The join key is intentionally absent; the
    /// tailnet address is assigned by the onshore coordinator, never chosen here.
    /// `--exit-after-join` returns after the first successful peer sync so the
    /// LaunchDaemon (`blaktaild run`) takes over synchronisation.
    public static func upArguments(
        agentPath: String = "/usr/local/bin/blaktaild",
        coordinator: String,
        name: String
    ) -> [String] {
        [agentPath, "up", "--coord", coordinator, "--name", name, "--exit-after-join"]
    }

    public static func assertNoJoinKeyInArguments(_ arguments: [String], joinKey: String) throws {
        guard !joinKey.isEmpty else { return }
        if arguments.contains(where: { $0.contains(joinKey) }) {
            throw AgentControllerError.joinKeyMustNotAppearInArguments
        }
    }

    public func status() throws -> AgentStatus {
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            return .disconnected
        }
        let result = try runner.run(
            executable: agentPath,
            arguments: ["status"],
            stdin: nil,
            privileged: false
        )
        if result.exitCode != 0 {
            return .disconnected
        }
        var status = AgentStatus.parse(result.stdout)
        guard status.nodeID != nil else { return .disconnected }
        let daemon = try? runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "system/\(launchDaemonLabel)"],
            stdin: nil,
            privileged: false
        )
        status.connected = daemon?.exitCode == 0
        return status
    }

    public func connect(joinKey: String, coordinator: String, name: String) throws {
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw AgentControllerError.agentMissing
        }
        let arguments = Array(Self.upArguments(
            agentPath: agentPath,
            coordinator: coordinator,
            name: name
        ).dropFirst())
        try Self.assertNoJoinKeyInArguments([agentPath] + arguments, joinKey: joinKey)

        let up = try runner.run(
            executable: agentPath,
            arguments: arguments,
            stdin: Data(joinKey.utf8),
            privileged: true
        )
        if up.exitCode != 0 {
            let message = up.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentControllerError.failed(message.isEmpty ? "Could not connect the local agent." : message)
        }

        try startLaunchDaemon()
    }

    public func resume() throws {
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            throw AgentControllerError.agentMissing
        }
        try startLaunchDaemon()
    }

    public func pause() throws {
        _ = try? runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "system/\(launchDaemonLabel)"],
            stdin: nil,
            privileged: true
        )
        if FileManager.default.isExecutableFile(atPath: agentPath) {
            let down = try runner.run(
                executable: agentPath,
                arguments: ["pause"],
                stdin: nil,
                privileged: true
            )
            if down.exitCode != 0 {
                let message = down.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AgentControllerError.failed(
                    message.isEmpty ? "Could not pause the local agent." : message
                )
            }
        }
    }

    private func startLaunchDaemon() throws {
        _ = try? runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "system/\(launchDaemonLabel)"],
            stdin: nil,
            privileged: true
        )
        let boot = try runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "system", launchDaemonPlist],
            stdin: nil,
            privileged: true
        )
        if boot.exitCode != 0 {
            let message = boot.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentControllerError.failed(
                message.isEmpty
                    ? "The local agent could not be started."
                    : message
            )
        }
    }
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String], stdin: Data?, privileged: Bool) throws -> ProcessResult {
        if privileged {
            if let probe = try? runDirect(executable: "/usr/bin/sudo", arguments: ["-n", "true"], stdin: nil),
               probe.exitCode == 0 {
                return try runDirect(
                    executable: "/usr/bin/sudo",
                    arguments: ["-n", executable] + arguments,
                    stdin: stdin
                )
            }
            return try runPrivileged(executable: executable, arguments: arguments, stdin: stdin)
        }
        return try runDirect(executable: executable, arguments: arguments, stdin: stdin)
    }

    private func runDirect(executable: String, arguments: [String], stdin: Data?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Elevates without putting secrets into the AppleScript source. Stdin material is written to a 0600 temp file and removed afterwards.
    private func runPrivileged(executable: String, arguments: [String], stdin: Data?) throws -> ProcessResult {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("blaktail-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        var shell = shellEscape(executable)
        for argument in arguments {
            shell += " " + shellEscape(argument)
        }

        if let stdin {
            let keyFile = tempDir.appendingPathComponent("stdin", isDirectory: false)
            fm.createFile(atPath: keyFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try stdin.write(to: keyFile)
            shell = "\(shell) < \(shellEscape(keyFile.path))"
        }

        let script = "do shell script \(appleScriptString(shell)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lowered = stderr.lowercased()
        if process.terminationStatus != 0, lowered.contains("canceled") || lowered.contains("cancelled") {
            throw AgentControllerError.privilegeRequired
        }
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
