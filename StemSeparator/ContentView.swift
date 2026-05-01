import SwiftUI
import UniformTypeIdentifiers
import AppKit

class SeparationState: ObservableObject {
    enum Phase {
        case idle
        case processing
        case done(URL, URL)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var isDragOver = false
    @Published var statusText = ""
    @Published var droppedFileName = ""

    func process(url: URL) {
        droppedFileName = url.lastPathComponent
        phase = .processing
        statusText = "Preparing..."

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSep_\(UUID().uuidString)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runDemucs(inputURL: url, outputDir: outputDir)
        }
    }

    private func runDemucs(inputURL: URL, outputDir: URL) {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            setError("Cannot create temp directory:\n\(error.localizedDescription)")
            return
        }

        guard let demucsPath = locateDemucs() else {
            setError("demucs not found.\n\nInstall it with:\n  pip install demucs\n\nThen make sure it's on your PATH\n(/opt/homebrew/bin or /usr/local/bin)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: demucsPath)
        process.arguments = ["--two-stems", "vocals", "-o", outputDir.path, inputURL.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:/Library/Frameworks/Python.framework/Versions/3.12/bin:/Library/Frameworks/Python.framework/Versions/3.11/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lastLine = text
                .components(separatedBy: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            DispatchQueue.main.async { self?.statusText = lastLine }
        }

        do {
            try process.run()
        } catch {
            setError("Failed to launch demucs:\n\(error.localizedDescription)")
            return
        }

        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            setError("Demucs exited with error \(process.terminationStatus).\n\nInstall demucs:\n  pip install demucs")
            return
        }

        let baseName = inputURL.deletingPathExtension().lastPathComponent
        guard let (vocals, instrumental) = findStems(in: outputDir, baseName: baseName) else {
            setError("Demucs finished but output files not found.\n\nCheck temp folder:\n\(outputDir.path)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.phase = .done(vocals, instrumental)
            self?.statusText = ""
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
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["demucs"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:/Library/Frameworks/Python.framework/Versions/3.12/bin:/Library/Frameworks/Python.framework/Versions/3.11/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private func findStems(in outputDir: URL, baseName: String) -> (URL, URL)? {
        let fm = FileManager.default
        guard let modelDirs = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) else { return nil }
        for modelDir in modelDirs {
            let songDir = modelDir.appendingPathComponent(baseName)
            let v = songDir.appendingPathComponent("vocals.wav")
            let nv = songDir.appendingPathComponent("no_vocals.wav")
            if fm.fileExists(atPath: v.path) && fm.fileExists(atPath: nv.path) { return (v, nv) }
            if let subdirs = try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil) {
                for sd in subdirs {
                    let v2 = sd.appendingPathComponent("vocals.wav")
                    let nv2 = sd.appendingPathComponent("no_vocals.wav")
                    if fm.fileExists(atPath: v2.path) && fm.fileExists(atPath: nv2.path) { return (v2, nv2) }
                }
            }
        }
        return nil
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = .error(message)
            self?.statusText = ""
        }
    }

    func reset() {
        phase = .idle
        statusText = ""
        droppedFileName = ""
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

    func saveBoth(vocals: URL, instrumental: URL, baseName: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder to save both stems"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            let base = baseName.isEmpty ? "track" : baseName
            try? FileManager.default.copyItem(at: vocals, to: dest.appendingPathComponent("\(base)_vocals.wav"))
            try? FileManager.default.copyItem(at: instrumental, to: dest.appendingPathComponent("\(base)_instrumental.wav"))
        }
    }
}

struct ContentView: View {
    @StateObject private var state = SeparationState()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Stem Separator")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var mainContent: some View {
        if case .idle = state.phase {
            idleView
        } else if case .processing = state.phase {
            processingView
        } else if case .done(let vocals, let instrumental) = state.phase {
            doneView(vocals: vocals, instrumental: instrumental)
        } else if case .error(let message) = state.phase {
            errorView(message: message)
        }
    }

    private var idleView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(state.isDragOver
                      ? Color.accentColor.opacity(0.1)
                      : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            state.isDragOver ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: state.isDragOver ? [] : [8])
                        )
                )

            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(state.isDragOver ? Color.accentColor : Color.secondary)

                VStack(spacing: 4) {
                    Text("Drop an audio file here")
                        .font(.headline)
                    Text("MP3 · WAV · FLAC · M4A · AIFF")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button("Choose File…") { openPanel() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $state.isDragOver) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { self.state.process(url: url) }
            }
            return true
        }
    }

    private var processingView: some View {
        VStack(spacing: 20) {
            if !state.droppedFileName.isEmpty {
                Label(state.droppedFileName, systemImage: "music.note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView()
                .scaleEffect(1.4)
            VStack(spacing: 6) {
                Text("Separating tracks…")
                    .font(.headline)
                if !state.statusText.isEmpty {
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        .lineLimit(2)
                }
            }
        }
        .padding(28)
    }

    private func doneView(vocals: URL, instrumental: URL) -> some View {
        let raw = URL(fileURLWithPath: state.droppedFileName).deletingPathExtension().lastPathComponent
        let baseName = raw.isEmpty ? "track" : raw

        return VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Separation Complete")
                    .font(.title3.weight(.semibold))
                if !state.droppedFileName.isEmpty {
                    Text(state.droppedFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    state.saveFile(at: vocals, suggestedName: "\(baseName)_vocals.wav")
                } label: {
                    Label("Save Vocals", systemImage: "mic.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    state.saveFile(at: instrumental, suggestedName: "\(baseName)_instrumental.wav")
                } label: {
                    Label("Save Instrumental", systemImage: "music.note")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    state.saveBoth(vocals: vocals, instrumental: instrumental, baseName: baseName)
                } label: {
                    Label("Save Both", systemImage: "arrow.down.circle.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("Process Another File") { state.reset() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Start Over") { state.reset() }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.state.process(url: url)
            }
        }
    }
}
