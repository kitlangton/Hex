@testable import HexCore
import XCTest

final class LLMExecutableLocatorTests: XCTestCase {
    func testRespectsExplicitBinaryPathWhenExecutable() throws {
        let binaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: binaryDirectory) }

        let binaryURL = binaryDirectory.appendingPathComponent("claude")
        try writeExecutableStub(to: binaryURL)

        let provider = LLMProvider(id: "provider-claude", type: .claudeCode, binaryPath: binaryURL.path)
        let resolved = LLMExecutableLocator.resolveBinaryURL(for: provider)

        XCTAssertEqual(resolved?.path, binaryURL.path)
    }

    func testFallsBackToPathSearchWhenBinaryMissing() throws {
        let binaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: binaryDirectory) }

        let binaryURL = binaryDirectory.appendingPathComponent("ollama")
        try writeExecutableStub(to: binaryURL)

        let originalPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", binaryDirectory.path, 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let provider = LLMProvider(id: "provider-ollama", type: .ollama)
        let resolved = LLMExecutableLocator.resolveBinaryURL(for: provider)

        XCTAssertEqual(resolved?.path, binaryURL.path)
    }

    func testPrefersClaudeCLIHintsOverAppBundle() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let cliBinary = tempDirectory.appendingPathComponent("claude-cli")
        try writeExecutableStub(to: cliBinary)

        let originalHint = getenv("CLAUDE_CODE_BINARY_HINT").map { String(cString: $0) }
        setenv("CLAUDE_CODE_BINARY_HINT", cliBinary.path, 1)
        let originalSkipDefault = getenv("CLAUDE_CODE_SKIP_DEFAULT").map { String(cString: $0) }
        setenv("CLAUDE_CODE_SKIP_DEFAULT", "1", 1)
        defer {
            if let originalHint {
                setenv("CLAUDE_CODE_BINARY_HINT", originalHint, 1)
            } else {
                unsetenv("CLAUDE_CODE_BINARY_HINT")
            }
            if let originalSkipDefault {
                setenv("CLAUDE_CODE_SKIP_DEFAULT", originalSkipDefault, 1)
            } else {
                unsetenv("CLAUDE_CODE_SKIP_DEFAULT")
            }
        }

        let provider = LLMProvider(id: "provider-claude", type: .claudeCode)
        let resolved = LLMExecutableLocator.resolveBinaryURL(for: provider)

        XCTAssertEqual(resolved?.path, cliBinary.path)
    }

    func testIgnoresClaudeAppBundleExecutables() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let appContents = tempDirectory.appendingPathComponent("Claude.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appContents, withIntermediateDirectories: true)
        let appBinary = appContents.appendingPathComponent("claude")
        try writeExecutableStub(to: appBinary)

        let originalPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", appContents.path, 1)
        let originalSkipDefault = getenv("CLAUDE_CODE_SKIP_DEFAULT").map { String(cString: $0) }
        setenv("CLAUDE_CODE_SKIP_DEFAULT", "1", 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
            if let originalSkipDefault {
                setenv("CLAUDE_CODE_SKIP_DEFAULT", originalSkipDefault, 1)
            } else {
                unsetenv("CLAUDE_CODE_SKIP_DEFAULT")
            }
        }

        let provider = LLMProvider(id: "provider-claude", type: .claudeCode)
        let resolved = LLMExecutableLocator.resolveBinaryURL(for: provider)

        XCTAssertNil(resolved)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutableStub(to url: URL) throws {
        let data = "#!/bin/sh\nexit 0\n".data(using: .utf8)!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
