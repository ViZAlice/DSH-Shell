import Foundation
import Darwin

enum RuntimeError: LocalizedError {
    case commandFailed(String, Int32, String)
    case missingVersionTag
    case portInUse(Int32)
    case staleServerCouldNotStop
    case serverExited(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, output):
            return "命令失败（\(status)）：\(command)\n\(output)"
        case .missingVersionTag:
            return "DSH 仓库中没有可用的版本 tag。"
        case let .portInUse(pid):
            return "端口 3080 正被其他程序占用（PID \(pid)）。"
        case .staleServerCouldNotStop:
            return "检测到本项目遗留的 DSH Server，但无法将它安全停止。"
        case let .serverExited(output):
            return "DSH Server 意外退出。\n\(output)"
        case .timedOut:
            return "等待 DSH Server 启动超时。"
        }
    }

    var briefDescription: String {
        switch self {
        case let .commandFailed(_, status, _):
            return "准备 DSH 时有命令执行失败（退出码 \(status)）。"
        case .missingVersionTag:
            return "没有找到可用的 DSH 版本。"
        case .portInUse:
            return "端口 3080 正被另一个程序使用。"
        case .staleServerCouldNotStop:
            return "上一次遗留的 DSH Server 无法停止。"
        case .serverExited:
            return "DSH Server 意外退出。"
        case .timedOut:
            return "等待 DSH Server 启动超时。"
        }
    }
}

actor DSHRuntime {
    static let repositoryURL = URL(string: "https://github.com/deepseek-ai/deepseek-harness.git")!
    static let serverURL = URL(string: "http://127.0.0.1:3080")!

    private let fileManager = FileManager.default
    private let rootURL: URL
    nonisolated let consoleOutputURL: URL
    private(set) var serverProcess: Process?
    private var serverProcessGroupID: pid_t?
    private var serverOutputHandle: FileHandle?

    init() throws {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("DSHShell", isDirectory: true)
        rootURL = root
        consoleOutputURL = root.appendingPathComponent("server-output.log")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: consoleOutputURL.path) {
            fileManager.createFile(atPath: consoleOutputURL.path, contents: nil)
        }
    }

    var repositoryDirectory: URL {
        rootURL.appendingPathComponent("deepseek-harness", isDirectory: true)
    }

    func prepare(status: @escaping @MainActor (String, Double?) -> Void) async throws -> String {
        if !fileManager.fileExists(atPath: repositoryDirectory.appendingPathComponent(".git").path) {
            await status("正在获取 DSH…", 0)
            try await run(
                "git",
                ["clone", "--progress", "--tags", Self.repositoryURL.absoluteString, repositoryDirectory.path],
                in: rootURL,
                progressParser: Self.gitCloneProgress
            ) { progress in
                status("正在获取 DSH…", progress)
            }
        }

        await status("正在检查版本…", nil)
        let tags = try await run("git", ["tag", "--list"], in: repositoryDirectory)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let target = Self.latestPreferredTag(in: tags) else { throw RuntimeError.missingVersionTag }

        let current = try? await run("git", ["describe", "--tags", "--exact-match", "HEAD"], in: repositoryDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current != target {
            await status("正在切换到 \(target)…", nil)
            _ = try await run("git", ["checkout", "--detach", target], in: repositoryDirectory)
        }

        let markerURL = rootURL.appendingPathComponent("built-version.txt")
        let marker = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if marker != target {
            await status("正在安装依赖…", 0)
            _ = try await run(
                "pnpm",
                ["install", "--frozen-lockfile"],
                in: repositoryDirectory,
                progressParser: Self.pnpmInstallProgress
            ) { progress in
                status("正在安装依赖…", progress)
            }
            await status("正在构建 DSH…", 0)
            _ = try await run(
                "pnpm",
                ["run", "build"],
                in: repositoryDirectory,
                progressParser: Self.dshBuildProgress
            ) { progress in
                status("正在构建 DSH…", progress)
            }
            try target.write(to: markerURL, atomically: true, encoding: .utf8)
        }
        await status("DSH 准备完成", nil)
        return target
    }

    func startServer(status: @escaping @MainActor (String, Double?) -> Void) async throws -> URL {
        await status("正在启动 Server…", nil)
        try resetConsoleOutput()
        try await clearManagedServerUsingPort()

        let process = makeProcess("pnpm", ["dsh", "web", "--no-open"], in: repositoryDirectory)
        let outputHandle = try FileHandle(forWritingTo: consoleOutputURL)
        try outputHandle.seekToEnd()
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        serverProcess = process
        let group = getpgid(process.processIdentifier)
        serverProcessGroupID = group > 1 ? group : nil
        serverOutputHandle = outputHandle

        do {
            await status("正在等待服务…", nil)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                let output = (try? String(contentsOf: consoleOutputURL, encoding: .utf8)) ?? ""
                if !process.isRunning {
                    closeServerOutput()
                    serverProcess = nil
                    throw RuntimeError.serverExited(Self.redactingLaunchToken(in: output))
                }
                if let authenticatedURL = Self.authenticatedServerURL(in: output) {
                    return authenticatedURL
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            appendConsoleOutput("[DeepSeek Harness] 等待 Server 启动超时。\n")
            await stop()
            throw RuntimeError.timedOut
        } catch {
            await stop()
            throw error
        }
    }

    func fetchNewVersion(comparedTo currentTag: String) async -> String? {
        do {
            _ = try await run("git", ["fetch", "--tags", "--prune"], in: repositoryDirectory)
            let tags = try await run("git", ["tag", "--list"], in: repositoryDirectory)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            guard let latest = Self.latestPreferredTag(in: tags), latest != currentTag else { return nil }
            return Self.versionCompare(latest, currentTag) == .orderedDescending ? latest : nil
        } catch {
            NSLog("DSH background fetch failed: %@", error.localizedDescription)
            return nil
        }
    }

    func stop() async {
        let process = serverProcess
        let group = serverProcessGroupID
        if let group, group > 1, group != getpgrp() {
            _ = Darwin.kill(-group, SIGTERM)
            for _ in 0..<30 where Self.processGroupExists(group) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if Self.processGroupExists(group) {
                _ = Darwin.kill(-group, SIGKILL)
            }
        } else if let process, process.isRunning {
            process.terminate()
        }
        self.serverProcess = nil
        serverProcessGroupID = nil
        closeServerOutput()
    }

    func recordDiagnostic(_ message: String) {
        appendConsoleOutput("\n[DeepSeek Harness] \(message)\n")
    }

    /// Reclaims only a listener that can be verified as DSH running from this
    /// shell's managed checkout. An unrelated owner is reported, never killed.
    private func clearManagedServerUsingPort() async throws {
        let listeners = try listeningProcessIDs()
        guard !listeners.isEmpty else { return }

        var groups = Set<pid_t>()
        for pid in listeners {
            guard isManagedDSHServer(pid: pid) else {
                appendConsoleOutput("[DeepSeek Harness] 端口 3080 已被非托管进程 PID \(pid) 占用。\n")
                throw RuntimeError.portInUse(pid)
            }
            let group = getpgid(pid)
            guard group > 1, group != getpgrp() else {
                appendConsoleOutput("[DeepSeek Harness] 无法安全确定遗留 Server PID \(pid) 的进程组。\n")
                throw RuntimeError.staleServerCouldNotStop
            }
            groups.insert(group)
        }

        appendConsoleOutput("[DeepSeek Harness] 正在清理上一次遗留的 DSH Server。\n")
        for group in groups { _ = Darwin.kill(-group, SIGTERM) }
        for _ in 0..<30 {
            if (try? listeningProcessIDs().isEmpty) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        for group in groups where Self.processGroupExists(group) {
            _ = Darwin.kill(-group, SIGKILL)
        }
        for _ in 0..<10 {
            if (try? listeningProcessIDs().isEmpty) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeError.staleServerCouldNotStop
    }

    private func listeningProcessIDs() throws -> [pid_t] {
        let result = try probe(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:3080", "-sTCP:LISTEN"]
        )
        if result.status == 1 { return [] }
        guard result.status == 0 else {
            throw RuntimeError.commandFailed("lsof TCP:3080", result.status, result.output)
        }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func isManagedDSHServer(pid: pid_t) -> Bool {
        guard let cwd = try? processWorkingDirectory(pid: pid),
              cwd == repositoryDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
              let command = try? processCommand(pid: pid)
        else { return false }
        return command.contains("apps/cli/src/bin.ts")
            && command.contains(" web")
            && command.contains("--no-open")
    }

    private func processWorkingDirectory(pid: pid_t) throws -> String {
        let result = try probe(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        )
        guard result.status == 0,
              let path = result.output.split(whereSeparator: \.isNewline)
                .first(where: { $0.first == "n" })?.dropFirst()
        else { return "" }
        return URL(fileURLWithPath: String(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func processCommand(pid: pid_t) throws -> String {
        let result = try probe(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        )
        return result.status == 0 ? result.output : ""
    }

    private func probe(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func resetConsoleOutput() throws {
        closeServerOutput()
        try Data().write(to: consoleOutputURL, options: .atomic)
    }

    private func appendConsoleOutput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            if !fileManager.fileExists(atPath: consoleOutputURL.path) {
                fileManager.createFile(atPath: consoleOutputURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: consoleOutputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Unable to append DSH console output: %@", error.localizedDescription)
        }
    }

    private nonisolated static func processGroupExists(_ group: pid_t) -> Bool {
        Darwin.kill(-group, 0) == 0 || errno == EPERM
    }

    private func closeServerOutput() {
        try? serverOutputHandle?.close()
        serverOutputHandle = nil
    }

    private nonisolated static func authenticatedServerURL(in output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "dsh web:") else { continue }
            let remainder = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let candidate = remainder.split(whereSeparator: \.isWhitespace).first,
                  let url = URL(string: String(candidate)),
                  url.scheme == "http",
                  url.host == "127.0.0.1" || url.host == "localhost",
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true
            else { continue }
            return url
        }
        return nil
    }

    private nonisolated static func redactingLaunchToken(in output: String) -> String {
        output.replacingOccurrences(
            of: #"([?&]token=)[^\s&)]*"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
    }

    @discardableResult
    private func run(
        _ command: String,
        _ arguments: [String],
        in directory: URL,
        progressParser: ((String) -> Double?)? = nil,
        reportProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> String {
        let process = makeProcess(command, arguments, in: directory)
        let outputURL = rootURL.appendingPathComponent("command-\(UUID().uuidString).log")
        try Data().write(to: outputURL, options: .atomic)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
            var lastProgress = -1.0
            while process.isRunning {
                if let progressParser,
                   let output = try? String(contentsOf: outputURL, encoding: .utf8),
                   let progress = progressParser(output),
                   progress > lastProgress {
                    lastProgress = progress
                    await reportProgress?(progress)
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }

        process.waitUntilExit()
        try? outputHandle.synchronize()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            appendConsoleOutput("\n$ \(([command] + arguments).joined(separator: " "))\n\(output)\n")
            throw RuntimeError.commandFailed(([command] + arguments).joined(separator: " "), process.terminationStatus, output)
        }
        await reportProgress?(1)
        return output
    }

    private nonisolated static func gitCloneProgress(_ output: String) -> Double? {
        if let resolving = lastInteger(in: output, matching: #"Resolving deltas:\s+(\d+)%"#) {
            return 0.9 + min(Double(resolving), 100) / 1_000
        }
        if let receiving = lastInteger(in: output, matching: #"Receiving objects:\s+(\d+)%"#) {
            return min(Double(receiving), 100) * 0.009
        }
        return nil
    }

    private nonisolated static func pnpmInstallProgress(_ output: String) -> Double? {
        if output.range(of: #"Done in \d"#, options: .regularExpression) != nil { return 1 }
        guard let total = lastInteger(in: output, matching: #"Packages:\s+\+(\d+)"#), total > 0,
              let added = lastInteger(in: output, matching: #"Progress:[^\r\n]*added\s+(\d+)"#)
        else { return nil }
        return min(Double(added) / Double(total), 1)
    }

    private nonisolated static func dshBuildProgress(_ output: String) -> Double? {
        if output.contains("build: recorded ") { return 1 }
        if output.range(of: #"(?m)^> .* build:web(?:\s|$)"#, options: .regularExpression) != nil {
            return 0.5
        }
        return nil
    }

    private nonisolated static func lastInteger(in text: String, matching pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(in: text, range: range).last,
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[capture])
    }

    private func makeProcess(_ command: String, _ arguments: [String], in directory: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$@\"", "dsh-shell", command] + arguments
        process.currentDirectoryURL = directory
        return process
    }

    nonisolated static func latestPreferredTag(in tags: [String]) -> String? {
        let versionTags = tags.filter { $0.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil }
        let releaseCandidates = versionTags.filter {
            $0.range(of: #"(?:^|[.\-_])rc(?:[.\-_]?\d+)?(?:$|[.\-_])"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return (releaseCandidates.isEmpty ? versionTags : releaseCandidates)
            .max { versionCompare($0, $1) == .orderedAscending }
    }

    nonisolated static func versionCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let tokenize: (String) -> [String] = { value in
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        for index in 0..<max(left.count, right.count) {
            guard index < left.count else { return .orderedAscending }
            guard index < right.count else { return .orderedDescending }
            let a = left[index]
            let b = right[index]
            if let ai = Int(a), let bi = Int(b), ai != bi { return ai < bi ? .orderedAscending : .orderedDescending }
            if a != b { return a.localizedStandardCompare(b) }
        }
        return .orderedSame
    }
}
