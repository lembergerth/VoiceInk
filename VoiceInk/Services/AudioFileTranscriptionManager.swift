import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

struct BatchTranscriptionResult: Identifiable {
    let id = UUID()
    let fileName: String
    let transcription: Transcription
}

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    @Published var isProcessing = false
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var completedResults: [BatchTranscriptionResult] = []
    @Published var currentFileIndex: Int = 0
    @Published var totalFileCount: Int = 0
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Error>?
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")

    enum ProcessingPhase {
        case idle
        case loading
        case processingAudio
        case transcribing
        case enhancing
        case completed

        var message: String {
            switch self {
            case .idle:
                return ""
            case .loading:
                return "Loading transcription model..."
            case .processingAudio:
                return "Processing audio file for transcription..."
            case .transcribing:
                return "Transcribing audio..."
            case .enhancing:
                return "Enhancing transcription with AI..."
            case .completed:
                return "Transcription completed!"
            }
        }
    }

    private init() {}

    func startProcessing(url: URL, modelContext: ModelContext, whisperState: WhisperState) {
        startBatchProcessing(urls: [url], modelContext: modelContext, whisperState: whisperState)
    }

    func startBatchProcessing(urls: [URL], modelContext: ModelContext, whisperState: WhisperState) {
        cancelProcessing()

        isProcessing = true
        processingPhase = .loading
        completedResults = []
        totalFileCount = urls.count
        currentFileIndex = 0
        errorMessage = nil

        currentTask = Task {
            do {
                guard let currentModel = whisperState.currentTranscriptionModel else {
                    throw TranscriptionError.noModelSelected
                }

                let serviceRegistry = TranscriptionServiceRegistry(whisperState: whisperState, modelsDirectory: whisperState.modelsDirectory)
                defer {
                    serviceRegistry.cleanup()
                }

                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()

                    currentFileIndex = index + 1
                    let fileName = url.lastPathComponent

                    let transcription = try await processSingleFile(
                        url: url,
                        serviceRegistry: serviceRegistry,
                        currentModel: currentModel,
                        modelContext: modelContext,
                        whisperState: whisperState
                    )

                    completedResults.append(
                        BatchTranscriptionResult(fileName: fileName, transcription: transcription)
                    )
                }

                processingPhase = .completed
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await finishProcessing()

            } catch is CancellationError {
                await finishProcessing()
            } catch {
                await handleError(error)
            }
        }
    }

    private func processSingleFile(
        url: URL,
        serviceRegistry: TranscriptionServiceRegistry,
        currentModel: any TranscriptionModel,
        modelContext: ModelContext,
        whisperState: WhisperState
    ) async throws -> Transcription {
        processingPhase = .processingAudio
        let samples = try await audioProcessor.processAudioToSamples(url)

        let audioAsset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

        let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")

        let fileName = "transcribed_\(UUID().uuidString).wav"
        let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)

        processingPhase = .transcribing
        let transcriptionStart = Date()
        var text = try await serviceRegistry.transcribe(audioURL: permanentURL, model: currentModel)
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        text = TranscriptionOutputFilter.filter(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let powerModeManager = PowerModeManager.shared
        let activePowerModeConfig = powerModeManager.currentActiveConfiguration
        let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
        let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

        if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
            text = WhisperTextFormatter.format(text)
        }

        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)

        // Handle enhancement if enabled
        if let enhancementService = whisperState.enhancementService,
           enhancementService.isEnhancementEnabled,
           enhancementService.isConfigured {
            processingPhase = .enhancing
            do {
                let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(text)
                let transcription = Transcription(
                    text: text,
                    duration: duration,
                    enhancedText: enhancedText,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                    promptName: promptName,
                    transcriptionDuration: transcriptionDuration,
                    enhancementDuration: enhancementDuration,
                    aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                    aiRequestUserMessage: enhancementService.lastUserMessageSent,
                    powerModeName: powerModeName,
                    powerModeEmoji: powerModeEmoji
                )
                modelContext.insert(transcription)
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                return transcription
            } catch {
                if error is CancellationError {
                    logger.info("Enhancement cancelled")
                } else {
                    logger.error("Enhancement failed: \(error.localizedDescription)")
                }
                let transcription = Transcription(
                    text: text,
                    duration: duration,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    powerModeName: powerModeName,
                    powerModeEmoji: powerModeEmoji
                )
                modelContext.insert(transcription)
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                return transcription
            }
        } else {
            let transcription = Transcription(
                text: text,
                duration: duration,
                audioFileURL: permanentURL.absoluteString,
                transcriptionModelName: currentModel.displayName,
                promptName: nil,
                transcriptionDuration: transcriptionDuration,
                powerModeName: powerModeName,
                powerModeEmoji: powerModeEmoji
            )
            modelContext.insert(transcription)
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            return transcription
        }
    }

    func cancelProcessing() {
        currentTask?.cancel()
    }

    private func finishProcessing() {
        isProcessing = false
        processingPhase = .idle
        currentTask = nil
        currentFileIndex = 0
        totalFileCount = 0
    }

    private func handleError(_ error: Error) {
        logger.error("Transcription error: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        isProcessing = false
        processingPhase = .idle
        currentTask = nil
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No transcription model selected"
        case .transcriptionCancelled:
            return "Transcription was cancelled"
        }
    }
}
