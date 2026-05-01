import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Separation Model

enum SeparationModel: String, CaseIterable, Identifiable {
    case fast     = "Fast"
    case standard = "Standard"
    case full     = "6 Tracks"

    var id: String { rawValue }

    var modelName: String {
        switch self {
        case .fast:     return "mdx_extra_q"
        case .standard: return "htdemucs"
        case .full:     return "htdemucs_6s"
        }
    }

    var stems: [String] {
        switch self {
        case .fast, .standard: return ["vocals", "drums", "bass", "other"]
        case .full:            return ["vocals", "drums", "bass", "other", "guitar", "piano"]
        }
    }

    var demucsArgs: [String] {
        switch self {
        case .fast:     return ["-n", "mdx_extra_q"]
        case .standard: return ["-n", "htdemucs"]
        case .full:     return ["-n", "htdemucs_6s"]
        }
    }

    var detail: String {
        switch self {
        case .fast:     return "mdx_extra_q · Vocals, Drums, Bass, Other"
        case .standard: return "htdemucs · Vocals, Drums, Bass, Other"
        case .full:     return "htdemucs_6s · Vocals, Guitar, Piano, Drums, Bass, Other"
        }
    }

    static func label(_ stem: String) -> String {
        switch stem {
        case "vocals":    return "Vocals"
        case "no_vocals": return "Instrumental"
        case "drums":     return "Drums"
        case "bass":      return "Bass"
        case "other":     return "Other"
        case "guitar":    return "Guitar"
        case "piano":     return "Piano"
        default:          return stem.capitalized
        }
    }

    static func icon(_ stem: String) -> String {
        switch stem {
        case "vocals":    return "mic.fill"
        case "no_vocals": return "music.note"
        case "drums":     return "waveform"
        case "bass":      return "waveform.path.ecg"
        case "other":     return "ellipsis.circle"
        case "guitar":    return "music.quarternote.3"
        case "piano":     return "music.note.list"
        default:          return "waveform"
        }
    }
}

// MARK: - Queue Item

struct QueueItem: Identifiable {
    let id = UUID()
    let url: URL
    let model: SeparationModel
    var status: Status

    var fileName: String { url.lastPathComponent }
    var baseName: String {
        URL(fileURLWithPath: url.lastPathComponent).deletingPathExtension().lastPathComponent
    }

    enum Status {
        case waiting
        case processing(String)
        case done([(stem: String, url: URL)])
        case error(String)
    }
}

// MARK: - Queue Manager

class QueueManager: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var isDragOver = false
    @Published var selectedModel: SeparationModel = .standard

    private var isRunning = false

    func enqueue(urls: [URL]) {
        let model = selectedModel
        for url in urls {
            let alreadyActive = items.contains(where: { item in
                guard item.url == url else { return false }
                switch item.status {
                case .waiting, .processing: return true
                default: return false
                }
            })
            if !alreadyActive {
                items.append(QueueItem(url: url, model: model, status: .waiting))
            }
        }
        processNext()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clearCompleted() {
        items.removeAll {
            switch $0.status {
            case .done, .error: return true
            default: return false
            }
        }
    }

    private func processNext() {
        guard !isRunning else { return }
        guard let idx = items.firstIndex(where: { if case .waiting = $0.status { return true }; return false }) else { return }
        isRunning = true
        let item = items[idx]
        setStatus(id: item.id, .processing("Starting…"))
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("StemSep_\(item.id.uuidString)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(item: item, outputDir: outputDir)
        }
    }

    private func run(item: QueueItem, outputDir: URL) {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            finish(id: item.id, error: "Cannot create temp dir")
            return
        }

        guard let demucsPath = locateDemucs() else {
            finish(id: item.id, error: "demucs not found.\n\nInstall with: pip install demucs")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: demucsPath)
        process.arguments = item.model.demucsArgs + ["-o", outputDir.path, item.url.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            + ":/Library/Frameworks/Python.framework/Versions/3.13/bin"
            + ":/Library/Frameworks/Python.framework/Versions/3.12/bin"
            + ":/Library/Frameworks/Python.framework/Versions/3.11/bin"
            + ":" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let last = text.components(separatedBy: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            self?.setStatus(id: item.id, .processing(last))
        }

        do { try process.run() } catch {
            finish(id: item.id, error: "Failed to launch demucs")
            return
        }

        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            finish(id: item.id, error: "Demucs exited with error \(process.terminationStatus)")
            return
        }

        let baseName = item.url.deletingPathExtension().lastPathComponent
        let stems = findStems(in: outputDir, baseName: baseName, expected: item.model.stems)
        guard !stems.isEmpty else {
            finish(id: item.id, error: "Output files not found after separation")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setStatus(id: item.id, .done(stems))
            self.isRunning = false
            self.processNext()
        }
    }

    private func finish(id: UUID, error msg: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setStatus(id: id, .error(msg))
            self.isRunning = false
            self.processNext()
        }
    }

    private func setStatus(id: UUID, _ status: QueueItem.Status) {
        DispatchQueue.main.async { [weak self] in
            if let idx = self?.items.firstIndex(where: { $0.id == id }) {
                self?.items[idx].status = status
            }
        }
    }

    private func locateDemucs() -> String? {
        let candidates = [
            "/opt/homebrew/bin/demucs",
            "/usr/local/bin/demucs",
            "/usr/bin/demucs",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/demucs",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/demucs",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/demucs",
        ]
        for path in candidates { if FileManager.default.fileExists(atPath: path) { return path } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["demucs"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private func findStems(in outputDir: URL, baseName: String, expected: [String]) -> [(stem: String, url: URL)] {
        let fm = FileManager.default

        func check(dir: URL) -> [(stem: String, url: URL)] {
            let found = expected.compactMap { stem -> (stem: String, url: URL)? in
                let f = dir.appendingPathComponent("\(stem).wav")
                return fm.fileExists(atPath: f.path) ? (stem, f) : nil
            }
            return found.count == expected.count ? found : []
        }

        guard let modelDirs = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) else { return [] }
        for modelDir in modelDirs {
            let exact = check(dir: modelDir.appendingPathComponent(baseName))
            if !exact.isEmpty { return exact }
            if let subdirs = try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil) {
                for sd in subdirs {
                    let found = check(dir: sd)
                    if !found.isEmpty { return found }
                }
            }
        }
        return []
    }

    func saveFile(at source: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                try? FileManager.default.copyItem(at: source, to: dest)
            }
        }
    }

    func saveAll(stems: [(stem: String, url: URL)], baseName: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder — all stems will be saved there"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            for (stem, url) in stems {
                try? FileManager.default.copyItem(
                    at: url,
                    to: dest.appendingPathComponent("\(baseName)_\(stem).wav")
                )
            }
        }
    }
}

// MARK: - Stem Save Buttons

struct StemSaveButtons: View {
    let stems: [(stem: String, url: URL)]
    let baseName: String
    let queue: QueueManager

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var instrumentalStems: [(stem: String, url: URL)] {
        stems.filter { $0.stem != "vocals" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(stems, id: \.stem) { stem, url in
                    Button {
                        queue.saveFile(at: url, suggestedName: "\(baseName)_\(stem).wav")
                    } label: {
                        Label(SeparationModel.label(stem), systemImage: SeparationModel.icon(stem))
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Button {
                    queue.saveAll(stems: instrumentalStems, baseName: baseName)
                } label: {
                    Label("Save Instrumentals", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    queue.saveAll(stems: stems, baseName: baseName)
                } label: {
                    Label("Save All", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.leading, 28)
    }
}

// MARK: - Queue Row

struct QueueItemRow: View {
    let item: QueueItem
    let queue: QueueManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.model.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                removeButton
            }

            statusDetail
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 18)
        case .processing:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 18)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 18)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .frame(width: 18)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch item.status {
        case .waiting:
            Text("Waiting in queue")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)

        case .processing(let text):
            Text(text.isEmpty ? "Processing…" : text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 28)

        case .done(let stems):
            StemSaveButtons(stems: stems, baseName: item.baseName, queue: queue)

        case .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(3)
                .padding(.leading, 28)
        }
    }

    private var removeButton: some View {
        Button { queue.remove(id: item.id) } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled({ if case .processing = item.status { return true }; return false }())
        .opacity({ if case .processing = item.status { return 0 }; return 1 }())
    }

    private var rowBackground: some View {
        Group {
            switch item.status {
            case .done:       Color.green.opacity(0.06)
            case .error:      Color.red.opacity(0.06)
            case .processing: Color.accentColor.opacity(0.05)
            case .waiting:    Color(NSColor.controlBackgroundColor)
            }
        }
    }
}

// MARK: - Drop Zone

struct DropZoneView: View {
    @ObservedObject var queue: QueueManager
    let compact: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 10 : 16)
                .fill(queue.isDragOver
                      ? Color.accentColor.opacity(0.1)
                      : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 10 : 16)
                        .strokeBorder(
                            queue.isDragOver ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: queue.isDragOver ? [] : [8])
                        )
                )

            if compact {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(queue.isDragOver ? Color.accentColor : Color.secondary)
                    Text(queue.isDragOver ? "Release to add" : "Drop more files here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Files…") { openPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(queue.isDragOver ? Color.accentColor : Color.secondary)
                    VStack(spacing: 4) {
                        Text("Drop audio files here")
                            .font(.headline)
                        Text("MP3 · WAV · FLAC · M4A · AIFF")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(queue.selectedModel.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    Button("Choose Files…") { openPanel() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $queue.isDragOver) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { queue.enqueue(urls: urls) }
            return true
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            if response == .OK { queue.enqueue(urls: panel.urls) }
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var queue = QueueManager()

    private var doneCount: Int {
        queue.items.filter { if case .done = $0.status { return true }; return false }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modelPicker
            Divider()

            if queue.items.isEmpty {
                DropZoneView(queue: queue, compact: false)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DropZoneView(queue: queue, compact: true)
                    .frame(height: 48)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                Divider().padding(.top, 10)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(queue.items) { item in
                            QueueItemRow(item: item, queue: queue)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 580)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Stem Separator")
                .font(.title2.weight(.semibold))
            Spacer()
            if doneCount > 0 {
                Button("Clear Done (\(doneCount))") { queue.clearCompleted() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var modelPicker: some View {
        HStack(spacing: 12) {
            Text("Model")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("", selection: $queue.selectedModel) {
                ForEach(SeparationModel.allCases) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Text(queue.selectedModel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}
