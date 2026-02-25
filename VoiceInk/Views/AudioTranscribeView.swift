import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct AudioTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var whisperState: WhisperState
    @StateObject private var transcriptionManager = AudioTranscriptionManager.shared
    @State private var isDropTargeted = false
    @State private var selectedAudioURLs: [URL] = []
    @State private var areAudioFilesSelected = false
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if transcriptionManager.isProcessing {
                    processingView
                } else {
                    dropZoneView
                }

                Divider()
                    .padding(.vertical)

                // Show transcription results
                if !transcriptionManager.completedResults.isEmpty {
                    if transcriptionManager.completedResults.count == 1,
                       let result = transcriptionManager.completedResults.first {
                        TranscriptionResultView(transcription: result.transcription)
                    } else {
                        BatchTranscriptionResultsView(results: transcriptionManager.completedResults)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL, .data, .audio, .movie], isTargeted: $isDropTargeted) { providers in
            if !transcriptionManager.isProcessing && !areAudioFilesSelected {
                handleDroppedFiles(providers)
                return true
            }
            return false
        }
        .alert("Error", isPresented: .constant(transcriptionManager.errorMessage != nil)) {
            Button("OK", role: .cancel) {
                transcriptionManager.errorMessage = nil
            }
        } message: {
            if let errorMessage = transcriptionManager.errorMessage {
                Text(errorMessage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                // Do not auto-start; only select file for manual transcription
                validateAndSetAudioFile(url)
            }
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: 16) {
            if areAudioFilesSelected {
                VStack(spacing: 16) {
                    if selectedAudioURLs.count == 1 {
                        Text("Audio file selected: \(selectedAudioURLs.first?.lastPathComponent ?? "")")
                            .font(.headline)
                    } else {
                        Text("\(selectedAudioURLs.count) audio files selected")
                            .font(.headline)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(selectedAudioURLs.enumerated()), id: \.offset) { index, url in
                                    Text("\(index + 1). \(url.lastPathComponent)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(.horizontal)
                    }

                    // AI Enhancement Settings
                    if let enhancementService = whisperState.getEnhancementService() {
                        VStack(spacing: 16) {
                            // AI Enhancement and Prompt in the same row
                            HStack(spacing: 16) {
                                Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                                    .toggleStyle(.switch)
                                    .onChange(of: isEnhancementEnabled) { oldValue, newValue in
                                        enhancementService.isEnhancementEnabled = newValue
                                    }

                                if isEnhancementEnabled {
                                    Divider()
                                        .frame(height: 20)

                                    // Prompt Selection
                                    HStack(spacing: 8) {
                                        Text("Prompt:")
                                            .font(.subheadline)

                                        if enhancementService.allPrompts.isEmpty {
                                            Text("No prompts available")
                                                .foregroundColor(.secondary)
                                                .italic()
                                                .font(.caption)
                                        } else {
                                            let promptBinding = Binding<UUID>(
                                                get: {
                                                    selectedPromptId ?? enhancementService.allPrompts.first?.id ?? UUID()
                                                },
                                                set: { newValue in
                                                    selectedPromptId = newValue
                                                    enhancementService.selectedPromptId = newValue
                                                }
                                            )

                                            Picker("", selection: promptBinding) {
                                                ForEach(enhancementService.allPrompts) { prompt in
                                                    Text(prompt.title).tag(prompt.id)
                                                }
                                            }
                                            .labelsHidden()
                                            .fixedSize()
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                                        .background(CardBackground(isSelected: false))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onAppear {
                            // Initialize local state from enhancement service
                            isEnhancementEnabled = enhancementService.isEnhancementEnabled
                            selectedPromptId = enhancementService.selectedPromptId
                        }
                    }

                    // Action Buttons in a row
                    HStack(spacing: 12) {
                        Button("Start Transcription") {
                            transcriptionManager.startBatchProcessing(
                                urls: selectedAudioURLs,
                                modelContext: modelContext,
                                whisperState: whisperState
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Choose Different File\(selectedAudioURLs.count > 1 ? "s" : "")") {
                            selectedAudioURLs = []
                            areAudioFilesSelected = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.windowBackgroundColor).opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    style: StrokeStyle(
                                        lineWidth: 2,
                                        dash: [8]
                                    )
                                )
                                .foregroundColor(isDropTargeted ? .blue : .gray.opacity(0.5))
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 32))
                            .foregroundColor(isDropTargeted ? .blue : .gray)

                        Text("Drop audio or video files here")
                            .font(.headline)

                        Text("or")
                            .foregroundColor(.secondary)

                        Button("Choose Files") {
                            selectFiles()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(32)
                }
                .frame(height: 200)
                .padding(.horizontal)
            }

            Text("Supported formats: WAV, MP3, M4A, AIFF, MP4, MOV, AAC, FLAC, CAF, AMR, OGG, OPUS, 3GP")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.8)

            if transcriptionManager.totalFileCount > 1 {
                Text("File \(transcriptionManager.currentFileIndex) of \(transcriptionManager.totalFileCount)")
                    .font(.headline)
                Text(transcriptionManager.processingPhase.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ProgressView(
                    value: Double(transcriptionManager.currentFileIndex - 1),
                    total: Double(transcriptionManager.totalFileCount)
                )
                .frame(maxWidth: 200)
            } else {
                Text(transcriptionManager.processingPhase.message)
                    .font(.headline)
            }

            Button("Cancel") {
                transcriptionManager.cancelProcessing()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio, .movie
        ]

        if panel.runModal() == .OK {
            let validURLs = panel.urls.filter { SupportedMedia.isSupported(url: $0) }
            if !validURLs.isEmpty {
                selectedAudioURLs = validURLs
                areAudioFilesSelected = true
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.movie.identifier,
            UTType.data.identifier,
            "public.file-url"
        ]

        var collectedURLs: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
            for typeIdentifier in typeIdentifiers {
                if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { (item, error) in
                        defer { group.leave() }

                        if let error = error {
                            print("Error loading dropped file with type \(typeIdentifier): \(error)")
                            return
                        }

                        var fileURL: URL?

                        if let url = item as? URL {
                            fileURL = url
                        } else if let data = item as? Data {
                            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                                fileURL = url
                            } else if let urlString = String(data: data, encoding: .utf8),
                                      let url = URL(string: urlString) {
                                fileURL = url
                            }
                        } else if let urlString = item as? String {
                            fileURL = URL(string: urlString)
                        }

                        if let finalURL = fileURL {
                            lock.lock()
                            collectedURLs.append(finalURL)
                            lock.unlock()
                        }
                    }
                    break // Stop trying other type identifiers for this provider
                }
            }
        }

        group.notify(queue: .main) {
            // Deduplicate by path and validate
            var seen = Set<String>()
            let uniqueURLs = collectedURLs.filter { url in
                let path = url.path
                guard !seen.contains(path) else { return false }
                seen.insert(path)
                return true
            }

            let validURLs = uniqueURLs.filter { url in
                FileManager.default.fileExists(atPath: url.path) && SupportedMedia.isSupported(url: url)
            }

            if !validURLs.isEmpty {
                self.selectedAudioURLs = validURLs
                self.areAudioFilesSelected = true
            }
        }
    }

    private func validateAndSetAudioFile(_ url: URL) {
        print("Attempting to validate file: \(url.path)")

        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("File does not exist at path: \(url.path)")
            return
        }

        // Try to access security scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Validate file type
        guard SupportedMedia.isSupported(url: url) else { return }

        print("File validated successfully: \(url.lastPathComponent)")
        selectedAudioURLs = [url]
        areAudioFilesSelected = true
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
