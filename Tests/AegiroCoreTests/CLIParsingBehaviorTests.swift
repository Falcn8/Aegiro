import Foundation
import XCTest

final class CLIParsingBehaviorTests: XCTestCase {
    private func cliExecutableURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = env["AEGIRO_CLI_BIN"], !fromEnv.isEmpty {
            let url = URL(fileURLWithPath: fromEnv)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            ".build/debug/aegiro-cli",
            ".build/arm64-apple-macosx/debug/aegiro-cli",
            ".build/x86_64-apple-macosx/debug/aegiro-cli"
        ].map { URL(fileURLWithPath: cwd).appendingPathComponent($0).standardizedFileURL }

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }

        throw XCTSkip("aegiro-cli executable not found for parser integration tests.")
    }

    private func runCLI(_ args: [String], stdin: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try cliExecutableURL()
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func testUnknownOptionIsRejected() throws {
        let result = try runCLI(["import", "--vault", "/tmp/test.agvt", "--unknown"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Unknown option '--unknown'"))
    }

    func testMutuallyExclusivePassphraseInputsAreRejected() throws {
        let result = try runCLI(
            ["list", "--vault", "/tmp/test.agvt", "--passphrase", "abc", "--passphrase-stdin"],
            stdin: "abc\n"
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Use either --passphrase or --passphrase-stdin"))
    }

    func testVersionCommandPrintsSemanticVersion() throws {
        let result = try runCLI(["version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Aegiro CLI v"))
    }
}
