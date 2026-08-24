import BlakTailCore
import XCTest

final class AgentStatusParserTests: XCTestCase {
    func testParsesJoinedStatus() {
        let status = AgentStatus.parse(
            """
            joined
            node: 00000000-0000-0000-0000-000000000001
            address: 100.64.0.1/32
            coordinator: https://coord.example.org.au
            """
        )
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.address, "100.64.0.1/32")
        XCTAssertEqual(status.coordinator, "https://coord.example.org.au")
    }

    func testMissingJoinedMeansDisconnected() {
        XCTAssertFalse(AgentStatus.parse("error: not joined\n").connected)
    }
}

final class JoinKeySafetyTests: XCTestCase {
    func testUpArgumentsOmitJoinKey() throws {
        let joinKey = "bt_join_secret_value_do_not_leak"
        let args = AgentController.upArguments(
            coordinator: "https://coord.example.org.au",
            name: "mac-one"
        )
        try AgentController.assertNoJoinKeyInArguments(args, joinKey: joinKey)
        XCTAssertFalse(args.contains(joinKey))
        XCTAssertFalse(args.contains("--join-key"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("BLAKTAIL_JOIN_KEY") }))
        // Server-assigned addressing: the app never passes a tailnet address.
        XCTAssertFalse(args.contains("--address"))
        XCTAssertTrue(args.contains("--coord"))
        XCTAssertTrue(args.contains("--exit-after-join"))
    }

    func testDetectsJoinKeyLeakInArguments() {
        let joinKey = "bt_join_secret_value_do_not_leak"
        XCTAssertThrowsError(
            try AgentController.assertNoJoinKeyInArguments(
                ["blaktaild", "up", "--join-key", joinKey],
                joinKey: joinKey
            )
        )
    }

    func testConnectPassesJoinKeyOnlyOnStdin() throws {
        let joinKey = "bt_join_secret_value_do_not_leak"
        let runner = RecordingRunner()
        let agentPath = makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: agentPath) }

        let controller = AgentController(
            agentPath: agentPath,
            launchDaemonLabel: "com.blaktail.agent",
            launchDaemonPlist: "/Library/LaunchDaemons/com.blaktail.agent.plist",
            runner: runner
        )
        try controller.connect(
            joinKey: joinKey,
            coordinator: "https://coord.example.org.au",
            name: "mac-one"
        )

        let up = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(up.executable, agentPath)
        XCTAssertEqual(up.arguments.first, "up")
        XCTAssertFalse(up.arguments.contains(joinKey))
        XCTAssertEqual(up.stdin.flatMap { String(data: $0, encoding: .utf8) }, joinKey)
        XCTAssertTrue(up.privileged)
    }
}

final class TaglineTests: XCTestCase {
    func testSharedProjectMission() {
        XCTAssertEqual(
            Tagline.text,
            "Built by Indigenous Australians for Indigenous Australian organisations. Data stays onshore, Indigenous Australian organisations stay in control, and the code stays public."
        )
    }
}

final class BrowserSignInTokenTests: XCTestCase {
    func testReadsTokenFromFragment() throws {
        let url = URL(string: "blaktail://auth/callback#token=abc%20def")!
        XCTAssertEqual(try BrowserSignIn.token(from: url), "abc def")
    }

    func testReadsTokenFromQuery() throws {
        let url = URL(string: "blaktail://auth/callback?token=session-token")!
        XCTAssertEqual(try BrowserSignIn.token(from: url), "session-token")
    }
}

private final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
        var stdin: Data?
        var privileged: Bool
    }

    private(set) var calls: [Call] = []

    func run(executable: String, arguments: [String], stdin: Data?, privileged: Bool) throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin, privileged: privileged))
        return ProcessResult(exitCode: 0, stdout: "ok\n", stderr: "")
    }
}

private func makeTempExecutable() -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("blaktaild-fake-\(UUID().uuidString)")
        .path
    FileManager.default.createFile(
        atPath: path,
        contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755]
    )
    return path
}
