import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class SendableURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var values: [URL] { lock.withLock { urls } }
}

struct FloatingWindowSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.backgroundColor = .clear
            view.window?.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @State private var runner = ConversionRunner()
    @State private var quality: Double = 90
    @State private var recursive = false
    @State private var isDragOver = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone

            HStack(spacing: 16) {
                openButton

                Toggle("Recursive", isOn: $recursive)
                    .toggleStyle(.checkbox)
                    .disabled(runner.isRunning)
            }

            qualitySlider

            if runner.isRunning {
                progressSection
            }

            if let error = runner.error {
                errorBanner(error)
            }

            if let result = runner.result {
                resultCard(result)
            }

            if !runner.logLines.isEmpty {
                logPanel
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 500)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .containerBackground(.clear, for: .window)
        .background(FloatingWindowSetter())
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragOver ? Color.accentColor.opacity(0.08) : .clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop images or folders here")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("JPG, PNG, GIF, BMP, TIFF")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 140)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Open Button

    private var openButton: some View {
        Button {
            openPanel()
        } label: {
            Label("Open...", systemImage: "folder")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(runner.isRunning)
    }

    // MARK: - Quality Slider

    private var qualitySlider: some View {
        HStack(spacing: 12) {
            Text("Quality")
                .foregroundStyle(.secondary)
            Slider(value: $quality, in: 1...100, step: 1)
                .disabled(runner.isRunning)
            Text("\(Int(quality))")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 6) {
            ProgressView(value: runner.progress)
                .progressViewStyle(.linear)

            HStack {
                if !runner.progressText.isEmpty {
                    Text(runner.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    runner.cancel()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 8))
    }

    // MARK: - Results

    private func resultCard(_ result: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Conversion Complete", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                resultRow("Total files", "\(result.totalFiles)")
                resultRow("Processed", "\(result.processed)")
                resultRow("Skipped", "\(result.skipped)")
                resultRow("Failed", "\(result.failed)")
                resultRow("Duration", result.duration)
                resultRow("Total size", result.totalSize)
                resultRow("Saved", result.savedSize)
                resultRow("Compression", result.compressionRatio)
            }
            .font(.callout)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
        }
    }

    // MARK: - Log Panel

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Logs")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(runner.logLines) { entry in
                            Text(entry.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.isError ? .red : .secondary)
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 150)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .onChange(of: runner.logLines.count) {
                    if let last = runner.logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urls = SendableURLs()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let result = urls.values
            if !result.isEmpty {
                runner.convert(paths: result, quality: Int(quality), recursive: recursive)
            }
        }

        return true
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [
            .image, .folder,
            .jpeg, .png, .gif, .bmp, .tiff,
        ]
        panel.message = "Select images or folders to convert to WebP"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if !urls.isEmpty {
            runner.convert(paths: urls, quality: Int(quality), recursive: recursive)
        }
    }
}
