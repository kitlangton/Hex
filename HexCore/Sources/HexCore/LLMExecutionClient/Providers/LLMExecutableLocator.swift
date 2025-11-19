import Foundation

enum LLMExecutableLocator {
    private static let logger = HexLog.llm

    static func resolveBinaryURL(for provider: LLMProvider) -> URL? {
        if let override = provider.binaryPath {
            if let url = executableURL(at: override) {
                return url
            } else {
                logger.error(
                    "Configured binary missing for provider \(provider.id, privacy: .public) at \(override, privacy: .private); falling back to auto-discovery"
                )
            }
        }

        guard let detected = autodetectedBinaryURL(for: provider.type) else {
            return nil
        }

        logger.notice(
            "Auto-detected \(provider.type.rawValue, privacy: .public) provider binary at \(detected.path, privacy: .private)"
        )
        return detected
    }

    static func claudeSearchPath(existingPATH: String?) -> String {
        claudeExecutableDirectories(existingPATH: existingPATH).joined(separator: ":")
    }

    private static func autodetectedBinaryURL(for type: LLMProvider.ProviderType) -> URL? {
        let envPATH = ProcessInfo.processInfo.environment["PATH"]
        for candidate in candidateExecutablePaths(for: type, envPATH: envPATH) {
            let normalized = normalizedPath(candidate)
            guard FileManager.default.isExecutableFile(atPath: normalized) else { continue }
            if type == .claudeCode && isAppBundleExecutable(normalized) {
                continue
            }
            return URL(fileURLWithPath: normalized)
        }
        return nil
    }

    private static func candidateExecutablePaths(for type: LLMProvider.ProviderType, envPATH: String?) -> [String] {
        switch type {
        case .claudeCode:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var candidates: [String] = []
            candidates.append(contentsOf: claudePreferredBinaryPaths(homeDirectory: home))
            let directories = claudeExecutableDirectories(existingPATH: envPATH)
            let directoryExecutables = directoriesToExecutablePaths(directories, binaryName: "claude")
            candidates.append(contentsOf: directoryExecutables)
            return dedupeStandardizedPaths(candidates)
        case .ollama:
            let directories = standardExecutableDirectories(existingPATH: envPATH)
            let directoryExecutables = directoriesToExecutablePaths(directories, binaryName: "ollama")
            return dedupeStandardizedPaths(directoryExecutables)
        default:
            return []
        }
    }

    private static func claudePreferredBinaryPaths(homeDirectory: String) -> [String] {
        var paths: [String] = []
        let environment = ProcessInfo.processInfo.environment

        if let hints = environment["CLAUDE_CODE_BINARY_HINT"], !hints.isEmpty {
            let components = hints.split(separator: ":").map { normalizedPath(String($0)) }
            paths.append(contentsOf: components)
        }

        if let overrideRoot = environment["CLAUDE_CODE_ROOT"], !overrideRoot.isEmpty {
            paths.append(contentsOf: claudeRootCandidates(for: overrideRoot))
        }

        if environment["CLAUDE_CODE_SKIP_DEFAULT"] != "1" {
            let localRoot = "\(homeDirectory)/.claude/local"
            paths.append(contentsOf: claudeRootCandidates(for: localRoot))
        }

        return paths
    }

    private static func claudeRootCandidates(for root: String) -> [String] {
        let normalizedRoot = normalizedPath(root)
        return [
            (normalizedRoot as NSString).appendingPathComponent("claude"),
            (normalizedRoot as NSString).appendingPathComponent("bin/claude"),
            (normalizedRoot as NSString).appendingPathComponent("node_modules/.bin/claude")
        ]
    }

    private static func claudeExecutableDirectories(existingPATH: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = claudeFallbackDirectories(homeDirectory: home)
        let pathEntries = pathDirectories(from: existingPATH)
        return dedupeStandardizedPaths(fallback + pathEntries)
    }

    private static func standardExecutableDirectories(existingPATH: String?) -> [String] {
        let fallback = defaultBinaryDirectories()
        let pathEntries = pathDirectories(from: existingPATH)
        return dedupeStandardizedPaths(pathEntries + fallback)
    }

    private static func claudeFallbackDirectories(homeDirectory: String) -> [String] {
        var directories: [String] = []
        directories.append(contentsOf: nvmExecutableDirectories(homeDirectory: homeDirectory))

        let brewPrefixes = ["/usr/local/opt", "/opt/homebrew/opt"]
        let fm = FileManager.default
        for prefix in brewPrefixes {
            let candidate = "\(prefix)/claude/bin"
            if fm.fileExists(atPath: candidate) {
                directories.append(candidate)
            }
        }

        directories.append(contentsOf: defaultBinaryDirectories())
        return directories
    }

    private static func defaultBinaryDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ]
    }

    private static func directoriesToExecutablePaths(_ directories: [String], binaryName: String) -> [String] {
        directories.map { path in
            if path.hasSuffix("/\(binaryName)") {
                return path
            }
            return (path as NSString).appendingPathComponent(binaryName)
        }
    }

    private static func pathDirectories(from path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path
            .split(separator: ":")
            .map(String.init)
            .compactMap { entry in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : normalizedPath(trimmed)
            }
    }

    private static func executableURL(at path: String) -> URL? {
        let normalized = normalizedPath(path)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: normalized) else {
            return nil
        }
        return URL(fileURLWithPath: normalized)
    }

    private static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private static func dedupeStandardizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = normalizedPath(trimmed)
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        return ordered
    }

    private static func nvmExecutableDirectories(homeDirectory: String) -> [String] {
        let fm = FileManager.default
        var directories: [String] = []
        let nvmDir = "\(homeDirectory)/.nvm"
        let currentDir = "\(nvmDir)/versions/node/current/bin"
        let versionsDir = "\(nvmDir)/versions/node"

        if fm.fileExists(atPath: currentDir) {
            directories.append(currentDir)
        }

        if let versionFolders = try? fm.contentsOfDirectory(atPath: versionsDir) {
            for version in versionFolders.sorted(by: >) {
                guard !version.hasPrefix(".") else { continue }
                let versionDir = "\(versionsDir)/\(version)/bin"
                directories.append(versionDir)
            }
        }

        return directories
    }

    private static func isAppBundleExecutable(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains(".app/contents/macos/")
    }
}
