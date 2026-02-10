import Foundation
import Observation

private final class StringAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ str: String) {
        lock.lock()
        buffer += str
        lock.unlock()
    }

    func set(_ str: String) {
        lock.lock()
        buffer = str
        lock.unlock()
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ConversionResult {
    var totalFiles = 0
    var processed = 0
    var skipped = 0
    var failed = 0
    var duration = ""
    var totalSize = ""
    var savedSize = ""
    var compressionRatio = ""
}

@Observable
final class ConversionRunner: @unchecked Sendable {
    var isRunning = false
    var progress: Double = 0
    var progressText = ""
    var result: ConversionResult?
    var error: String?
    var logLines: [LogEntry] = []

    private var process: Process?

    /// Returns (towebp binary path, extra PATH entries needed for node).
    private static func locateBinary() -> (binary: String, extraPath: [String])? {
        // Check common paths — node is already in system PATH here
        let candidates = [
            "/usr/local/bin/towebp",
            "/opt/homebrew/bin/towebp",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return (path, [])
            }
        }

        // Try nvm / fnm managed node paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDefault = "\(home)/.nvm/versions/node"
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: nvmDefault) {
            for node in nodes.sorted().reversed() {
                let binDir = "\(nvmDefault)/\(node)/bin"
                let p = "\(binDir)/towebp"
                if FileManager.default.isExecutableFile(atPath: p) {
                    return (p, [binDir])
                }
            }
        }

        // Fallback: `which towebp` via shell
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/sh")
        which.arguments = ["-l", "-c", "which towebp"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            let binDir = (path as NSString).deletingLastPathComponent
            return (path, [binDir])
        }

        return nil
    }

    func convert(paths: [URL], quality: Int, recursive: Bool) {
        guard !isRunning else { return }

        guard let located = Self.locateBinary() else {
            error = "towebp not found. Run 'npm link' in the towebp project first."
            return
        }

        isRunning = true
        progress = 0
        progressText = ""
        result = nil
        error = nil
        logLines = []

        Task.detached { [weak self] in
            await self?.runProcess(binary: located.binary, extraPath: located.extraPath, paths: paths, quality: quality, recursive: recursive)
        }
    }

    func cancel() {
        process?.terminate()
    }

    @MainActor
    private func runProcess(binary: String, extraPath: [String], paths: [URL], quality: Int, recursive: Bool) {
        var args: [String] = []
        if quality != 90 {
            args += ["-q", "\(quality)"]
        }
        if recursive {
            args.append("-r")
        }
        for url in paths {
            args.append(url.path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args

        // Ensure node is in PATH for the #!/usr/bin/env node shebang
        if !extraPath.isEmpty {
            var env = ProcessInfo.processInfo.environment
            let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = (extraPath + [existing]).joined(separator: ":")
            proc.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let stdoutAccumulator = StringAccumulator()
        let stderrAccumulator = StringAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            stdoutAccumulator.append(chunk)
            var buf = stdoutAccumulator.value
            let lines = self?.parseStdout(buffer: &buf) ?? []
            stdoutAccumulator.set(buf)
            if !lines.isEmpty {
                let entries = lines.map { LogEntry(text: $0, isError: false) }
                Task { @MainActor in
                    self?.logLines.append(contentsOf: entries)
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let chunk = String(data: data, encoding: .utf8) {
                stderrAccumulator.append(chunk)
                let lines = chunk.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !lines.isEmpty {
                    let entries = lines.map { LogEntry(text: $0, isError: true) }
                    Task { @MainActor in
                        self?.logLines.append(contentsOf: entries)
                    }
                }
            }
        }

        self.process = proc

        do {
            try proc.run()
        } catch {
            Task { @MainActor in
                self.error = "Failed to launch towebp: \(error.localizedDescription)"
                self.isRunning = false
            }
            return
        }

        proc.waitUntilExit()

        // Read remaining data
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            stdoutAccumulator.append(remaining)
        }
        if let remaining = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            stderrAccumulator.append(remaining)
            let errLines = remaining.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            self.logLines.append(contentsOf: errLines.map { LogEntry(text: $0, isError: true) })
        }

        // Parse final stdout lines for log entries
        var finalBuf = stdoutAccumulator.value
        let finalLines = parseStdout(buffer: &finalBuf)
        self.logLines.append(contentsOf: finalLines.map { LogEntry(text: $0, isError: false) })

        // Parse final summary from complete buffer
        self.parseSummary(buffer: stdoutAccumulator.value)

        if proc.terminationStatus != 0 && self.result == nil {
            let errMsg = stderrAccumulator.value.trimmingCharacters(in: .whitespacesAndNewlines)
            self.error = errMsg.isEmpty ? "towebp exited with code \(proc.terminationStatus)" : errMsg
        }

        self.progress = 1.0
        self.isRunning = false
        self.process = nil
    }

    /// Parses complete lines from the buffer, updates progress, and returns non-progress lines for logging.
    private func parseStdout(buffer: inout String) -> [String] {
        var loggedLines: [String] = []
        // Progress lines use \r, so split on both \r and \n
        while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            if line.isEmpty { continue }

            // Parse: Progress: XX.X% (N/M) | Saved: X.XXMB
            if line.contains("Progress:") {
                parseProgressLine(line)
            } else {
                loggedLines.append(line)
            }
        }
        return loggedLines
    }

    private func parseProgressLine(_ line: String) {
        // Extract percentage
        guard let percentRange = line.range(of: #"(\d+\.?\d*)%"#, options: .regularExpression) else { return }
        let percentStr = line[percentRange].dropLast() // remove %
        guard let percent = Double(percentStr) else { return }

        Task { @MainActor [weak self] in
            self?.progress = percent / 100.0
            self?.progressText = line.trimmingCharacters(in: .whitespaces)
        }
    }

    private func parseSummary(buffer: String) {
        guard buffer.contains("Conversion completed:") else { return }

        var res = ConversionResult()

        let lines = buffer.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Total files:") {
                res.totalFiles = Int(trimmed.replacingOccurrences(of: "Total files:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Processed:") {
                res.processed = Int(trimmed.replacingOccurrences(of: "Processed:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Skipped:") {
                res.skipped = Int(trimmed.replacingOccurrences(of: "Skipped:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Failed:") {
                res.failed = Int(trimmed.replacingOccurrences(of: "Failed:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Duration:") {
                res.duration = trimmed.replacingOccurrences(of: "Duration:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Total size:") {
                res.totalSize = trimmed.replacingOccurrences(of: "Total size:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Saved:") {
                res.savedSize = trimmed.replacingOccurrences(of: "Saved:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Compression:") {
                res.compressionRatio = trimmed.replacingOccurrences(of: "Compression:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        self.result = res
    }
}
