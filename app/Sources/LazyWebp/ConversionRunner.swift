import Foundation
import Observation

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

// MARK: - Debug File Logger

private final class DebugLog: @unchecked Sendable {
    let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = h
    }

    deinit {
        try? handle.close()
    }

    func write(_ msg: String, file: String, line: Int) {
        let ts = formatter.string(from: Date())
        let fn = (file as NSString).lastPathComponent
        let entry = "[\(ts)] \(fn):\(line) \(msg)\n"
        if let data = entry.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}

private let debugLog: DebugLog? = {
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LazyWebp")
        .path
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    return DebugLog(path: "\(logDir)/debug.log")
}()

private func dlog(_ msg: String, file: String = #file, line: Int = #line) {
    debugLog?.write(msg, file: file, line: line)
}

@Observable
final class ConversionRunner: @unchecked Sendable {
    var files: [FileItem] = []
    var isRunning = false
    var isPreparing = false
    var preparingCount = 0
    var error: String?
    var logLines: [LogEntry] = []

    private var currentTask: Task<Void, Never>?
    nonisolated(unsafe) private static var cachedBinary: (binary: String, extraPath: [String])?

    // MARK: - Computed from files[]

    var doneCount: Int {
        convertedCount + failedCount + skippedCount
    }

    var convertedCount: Int {
        files.count { $0.status == .done }
    }

    var failedCount: Int {
        files.count { $0.status == .failed }
    }

    var skippedCount: Int {
        files.count { $0.status == .skipped }
    }

    var totalOriginalBytes: Int64 {
        files.compactMap(\.originalSize).reduce(0, +)
    }

    var totalResultBytes: Int64 {
        files.filter { $0.status == .done }.compactMap(\.resultSize).reduce(0, +)
    }

    var overallProgress: Double {
        files.isEmpty ? 0 : Double(doneCount) / Double(files.count)
    }

    var totalSavings: Double? {
        let orig = totalOriginalBytes
        let result = totalResultBytes
        guard orig > 0, convertedCount > 0 else { return nil }
        return Double(orig - result) / Double(orig)
    }

    // MARK: - Image extensions

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp"
    ]

    private static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Prepare & Enumerate

    func prepareForDrop(count: Int) {
        isPreparing = true
        preparingCount = count
    }

    func enumerateFiles(from urls: [URL], recursive: Bool) {
        var items: [FileItem] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                ) {
                    for case let fileURL as URL in enumerator {
                        if Self.isImageFile(fileURL) {
                            items.append(FileItem(url: fileURL))
                        }
                    }
                }
            } else if Self.isImageFile(url) {
                items.append(FileItem(url: url))
            }
        }

        self.files = items
        self.isPreparing = false
        dlog("enumerateFiles: found \(items.count) files")
    }

    // MARK: - Convert

    func convert(quality: Int) {
        guard !files.isEmpty else { return }
        guard !isRunning else { return }

        isRunning = true
        error = nil
        logLines = []

        dlog("convert: starting \(files.count) files, quality=\(quality)")

        currentTask = Task.detached { [weak self] in
            guard let self else { return }

            guard let located = Self.locateBinary() else {
                dlog("convert: binary not found!")
                await MainActor.run {
                    self.error = "lazywebp not found. Install with 'npm install -g lazywebp' first."
                    self.isRunning = false
                }
                return
            }

            dlog("convert: binary=\(located.binary), extraPath=\(located.extraPath)")

            let semaphore = AsyncSemaphore(limit: 4)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<self.files.count {
                    // Check cancellation before adding more work
                    if Task.isCancelled {
                        dlog("convert: cancelled before adding task \(i)")
                        break
                    }

                    group.addTask {
                        dlog("[\(i)] waiting on semaphore")
                        let acquired = await semaphore.wait()

                        guard acquired else {
                            dlog("[\(i)] cancelled while waiting")
                            return
                        }
                        dlog("[\(i)] acquired semaphore")

                        guard !Task.isCancelled else {
                            dlog("[\(i)] cancelled after acquiring semaphore")
                            await semaphore.signal()
                            return
                        }

                        let file = await MainActor.run {
                            self.files[i].status = .converting
                            return self.files[i]
                        }

                        dlog("[\(i)] starting: \(file.fileName) path=\(file.url.path)")

                        let result = await self.runSingleFile(
                            index: i,
                            binary: located.binary,
                            extraPath: located.extraPath,
                            quality: quality,
                            file: file
                        )

                        dlog("[\(i)] result: status=\(result.status), size=\(result.resultSize ?? -1), err=\(result.errorMessage ?? "none")")

                        await MainActor.run {
                            self.files[i].status = result.status
                            self.files[i].resultSize = result.resultSize
                            self.files[i].errorMessage = result.errorMessage
                        }

                        dlog("[\(i)] signaling semaphore")
                        await semaphore.signal()
                        dlog("[\(i)] done")
                    }
                }
            }

            dlog("convert: all tasks complete")

            await MainActor.run {
                self.isRunning = false
                self.currentTask = nil
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    // MARK: - Single File Process

    private struct SingleFileResult {
        let status: FileStatus
        let resultSize: Int64?
        let errorMessage: String?
    }

    private func runSingleFile(
        index: Int,
        binary: String,
        extraPath: [String],
        quality: Int,
        file: FileItem
    ) async -> SingleFileResult {
        // Build expected output path (same dir, .webp extension)
        let outputURL = file.url
            .deletingPathExtension()
            .appendingPathExtension("webp")

        dlog("[\(index)] outputURL=\(outputURL.path)")

        // Already a webp — skip
        if file.url.pathExtension.lowercased() == "webp" {
            dlog("[\(index)] skipping: already webp")
            return SingleFileResult(status: .skipped, resultSize: nil, errorMessage: "Already WebP")
        }

        var args: [String] = []
        if quality != 90 {
            args += ["-q", "\(quality)"]
        }
        args.append(file.url.path)

        dlog("[\(index)] launching: \(binary) \(args.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args

        if !extraPath.isEmpty {
            var env = ProcessInfo.processInfo.environment
            let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = (extraPath + [existing]).joined(separator: ":")
            proc.environment = env
        }

        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                proc.terminationHandler = { _ in
                    dlog("[\(index)] terminationHandler fired")
                    c.resume()
                }
                do {
                    try proc.run()
                    dlog("[\(index)] proc.run() succeeded, pid=\(proc.processIdentifier)")
                } catch {
                    dlog("[\(index)] proc.run() FAILED: \(error)")
                    proc.terminationHandler = nil
                    c.resume(throwing: error)
                }
            }
        } catch {
            dlog("[\(index)] launch error: \(error)")
            return SingleFileResult(
                status: .failed,
                resultSize: nil,
                errorMessage: "Failed to launch: \(error.localizedDescription)"
            )
        }

        dlog("[\(index)] process exited, status=\(proc.terminationStatus)")

        // Close Pipe's write handle so readDataToEndOfFile returns immediately
        try? stderrPipe.fileHandleForWriting.close()
        dlog("[\(index)] reading stderr...")
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        dlog("[\(index)] stderr read complete, \(stderrData.count) bytes")

        let stderrStr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !stderrStr.isEmpty {
            dlog("[\(index)] stderr: \(stderrStr)")
            let entries = stderrStr
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { LogEntry(text: "\(file.fileName): \($0)", isError: true) }
            if !entries.isEmpty {
                await MainActor.run { [entries] in
                    self.logLines.append(contentsOf: entries)
                }
            }
        }

        if proc.terminationStatus != 0 {
            dlog("[\(index)] FAILED: exit \(proc.terminationStatus), stderr=\(stderrStr)")
            return SingleFileResult(
                status: .failed,
                resultSize: nil,
                errorMessage: stderrStr.isEmpty ? "Exit code \(proc.terminationStatus)" : stderrStr
            )
        }

        // Stat the output webp file
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: outputURL.path)
        dlog("[\(index)] output exists=\(exists) at \(outputURL.path)")

        if exists,
           let attrs = try? fm.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? Int64
        {
            dlog("[\(index)] SUCCESS: size=\(size)")
            return SingleFileResult(status: .done, resultSize: size, errorMessage: nil)
        }

        dlog("[\(index)] WARNING: exit 0 but no output file found!")
        return SingleFileResult(status: .done, resultSize: nil, errorMessage: nil)
    }

    // MARK: - Binary Location (cached)

    private static func locateBinary() -> (binary: String, extraPath: [String])? {
        // Return cached if still valid
        if let cached = cachedBinary,
           FileManager.default.isExecutableFile(atPath: cached.binary)
        {
            return cached
        }

        let result = findBinary()
        cachedBinary = result
        return result
    }

    private static func findBinary() -> (binary: String, extraPath: [String])? {
        let candidates = [
            "/usr/local/bin/lazywebp",
            "/opt/homebrew/bin/lazywebp",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return (path, [])
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDefault = "\(home)/.nvm/versions/node"
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: nvmDefault) {
            for node in nodes.sorted().reversed() {
                let binDir = "\(nvmDefault)/\(node)/bin"
                let p = "\(binDir)/lazywebp"
                if FileManager.default.isExecutableFile(atPath: p) {
                    return (p, [binDir])
                }
            }
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/sh")
        which.arguments = ["-l", "-c", "which lazywebp"]
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

    // MARK: - Reset

    func reset() {
        files = []
        error = nil
        logLines = []
    }
}
