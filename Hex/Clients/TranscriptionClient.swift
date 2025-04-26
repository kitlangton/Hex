//
//  TranscriptionClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import WhisperKit

/// A client that downloads and loads WhisperKit models, then transcribes audio files using the loaded model.
/// Exposes progress callbacks to report overall download-and-load percentage and transcription progress.
@DependencyClient
struct TranscriptionClient {
    /// Transcribes an audio file at the specified `URL` using the named `model`.
    /// Reports transcription progress via `progressCallback`.
    var transcribe: @Sendable (URL, String, DecodingOptions, @escaping (Progress) -> Void) async throws -> String
    
    /// Ensures a model is downloaded (if missing) and loaded into memory, reporting progress via `progressCallback`.
    var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void
    
    /// Deletes a model from disk if it exists
    var deleteModel: @Sendable (String) async throws -> Void
    
    /// Checks if a named model is already downloaded on this system.
    var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }
    
    /// Fetches a recommended set of models for the user's hardware from Hugging Face's `argmaxinc/whisperkit-coreml`.
    var getRecommendedModels: @Sendable () async throws -> ModelSupport
    
    /// Lists all model variants found in `argmaxinc/whisperkit-coreml`.
    var getAvailableModels: @Sendable () async throws -> [String]
}

extension TranscriptionClient: DependencyKey {
    static var liveValue: Self {
        let live = TranscriptionClientLive()
        return Self(
            transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, progressCallback: $3) },
            downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
            deleteModel: { try await live.deleteModel(variant: $0) },
            isModelDownloaded: { await live.isModelDownloaded($0) },
            getRecommendedModels: { await live.getRecommendedModels() },
            getAvailableModels: { try await live.getAvailableModels() }
        )
    }
}

extension DependencyValues {
    var transcription: TranscriptionClient {
        get { self[TranscriptionClient.self] }
        set { self[TranscriptionClient.self] = newValue }
    }
}

/// An `actor` that manages WhisperKit models by downloading (from Hugging Face),
//  loading them into memory, and then performing transcriptions.

actor TranscriptionClientLive {
    // MARK: - Stored Properties
    
    /// The current in-memory `WhisperKit` instance, if any.
    private var whisperKit: WhisperKit?
    
    /// The name of the currently loaded model, if any.
    private var currentModelName: String?
    
    /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
    private lazy var modelsBaseFolder: URL = {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            // Typically: .../Application Support/com.kitlangton.Hex
            let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
            // Inside there, store everything in /models
            let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            return baseURL
        } catch {
            fatalError("Could not create Application Support folder: \(error)")
        }
    }()
    
    // MARK: - Public Methods
    
    /// Ensures the given `variant` model is downloaded and loaded, reporting
    /// overall progress (0%–50% for downloading, 50%–100% for loading).
    func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
        // Special handling for corrupted or malformed variant names
        if variant.isEmpty {
            throw NSError(
                domain: "TranscriptionClient",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Cannot download model: Empty model name"
                ]
            )
        }
        
        let overallProgress = Progress(totalUnitCount: 100)
        overallProgress.completedUnitCount = 0
        progressCallback(overallProgress)
        
        print("[TranscriptionClientLive] Processing model: \(variant)")
        
        // 1) Model download phase (0-50% progress)
        if !(await isModelDownloaded(variant)) {
            try await downloadModelIfNeeded(variant: variant) { downloadProgress in
                let fraction = downloadProgress.fractionCompleted * 0.5
                overallProgress.completedUnitCount = Int64(fraction * 100)
                progressCallback(overallProgress)
            }
        } else {
            // Skip download phase if already downloaded
            overallProgress.completedUnitCount = 50
            progressCallback(overallProgress)
        }
        
        // 2) Model loading phase (50-100% progress)
        try await loadWhisperKitModel(variant) { loadingProgress in
            let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
            overallProgress.completedUnitCount = Int64(fraction * 100)
            progressCallback(overallProgress)
        }
        
        // Final progress update
        overallProgress.completedUnitCount = 100
        progressCallback(overallProgress)
    }
    
    /// Deletes a model from disk if it exists
    func deleteModel(variant: String) async throws {
        let modelFolder = modelPath(for: variant)
        
        // Check if the model exists
        guard FileManager.default.fileExists(atPath: modelFolder.path) else {
            // Model doesn't exist, nothing to delete
            return
        }
        
        // If this is the currently loaded model, unload it first
        if currentModelName == variant {
            unloadCurrentModel()
        }
        
        // Delete the model directory
        try FileManager.default.removeItem(at: modelFolder)
        
        print("[TranscriptionClientLive] Deleted model: \(variant)")
    }
    
    /// Returns `true` if the model is already downloaded to the local folder.
    /// Performs a thorough check to ensure the model files are actually present and usable.
    func isModelDownloaded(_ modelName: String) async -> Bool {
        let modelFolderPath = modelPath(for: modelName).path
        let fileManager = FileManager.default
        
        // First, check if the basic model directory exists
        guard fileManager.fileExists(atPath: modelFolderPath) else {
            // Don't print logs that would spam the console
            return false
        }
        
        do {
            // Check if the directory has actual model files in it
            let contents = try fileManager.contentsOfDirectory(atPath: modelFolderPath)
            
            // Model should have multiple files and certain key components
            guard !contents.isEmpty else {
                return false
            }
            
            // Check for specific model structure - need both tokenizer and model files
            let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
            let tokenizerFolderPath = tokenizerPath(for: modelName).path
            let hasTokenizer = fileManager.fileExists(atPath: tokenizerFolderPath)
            
            // Both conditions must be true for a model to be considered downloaded
            return hasModelFiles && hasTokenizer
        } catch {
            return false
        }
    }
    
    /// Returns a list of recommended models based on current device hardware.
    func getRecommendedModels() async -> ModelSupport {
        await WhisperKit.recommendedRemoteModels()
    }
    
    /// Lists all model variants available in the `argmaxinc/whisperkit-coreml` repository.
    func getAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }
    
    /// Transcribes the audio file at `url` using a `model` name.
    /// If the model is not yet loaded (or if it differs from the current model), it is downloaded and loaded first.
    /// Transcription progress can be monitored via `progressCallback`.
    func transcribe(
        url: URL,
        model: String,
        options: DecodingOptions,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        // Load or switch to the required model if needed.
        if whisperKit == nil || model != currentModelName {
            unloadCurrentModel()
            try await downloadAndLoadModel(variant: model) { p in
                // Debug logging, or scale as desired:
                progressCallback(p)
            }
        }
        
        guard let whisperKit = whisperKit else {
            throw NSError(
                domain: "TranscriptionClient",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
                ]
            )
        }
        
        // Perform the transcription.
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        
        // Concatenate results from all segments.
        let text = results.map(\.text).joined(separator: " ")
        return text
    }
    
    // MARK: - Private Helpers
    
    /// Creates or returns the local folder (on disk) for a given `variant` model.
    private func modelPath(for variant: String) -> URL {
        // Remove any possible path traversal or invalid characters from variant name
        let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
        
        return modelsBaseFolder
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(sanitizedVariant, isDirectory: true)
    }
    
    /// Creates or returns the local folder for the tokenizer files of a given `variant`.
    private func tokenizerPath(for variant: String) -> URL {
        modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
    }
    
    // Unloads any currently loaded model (clears `whisperKit` and `currentModelName`).
    private func unloadCurrentModel() {
        whisperKit = nil
        currentModelName = nil
    }
    
    /// Downloads the model to a temporary folder (if it isn't already on disk),
    /// then moves it into its final folder in `modelsBaseFolder`.
    private func downloadModelIfNeeded(
        variant: String,
        progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let modelFolder = modelPath(for: variant) // This determines the *final* location in App Support
        
        // If the model folder exists but isn't a complete model, clean it up
        let isDownloaded = await isModelDownloaded(variant)
        if FileManager.default.fileExists(atPath: modelFolder.path) && !isDownloaded {
            try FileManager.default.removeItem(at: modelFolder)
        }
        
        // If model is already fully downloaded (in the final App Support location), we're done
        if isDownloaded {
            print("[TranscriptionClientLive] Model \(variant) already downloaded and verified.")
            return
        }
        
        print("[TranscriptionClientLive] Starting download process for model: \(variant)")
        
        // --- BEGIN MODIFIED SECTION ---
        // Define and create the custom CACHE directory (~/.cache/hex/)
        let fileManager = FileManager.default
        let cacheBaseDir: URL
        do {
            // Construct the path: ~/.cache/hex/
            let homeDir = fileManager.homeDirectoryForCurrentUser
            let cacheDir = homeDir.appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("hex", isDirectory: true)
            
            // Ensure the directory exists
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            cacheBaseDir = cacheDir
            print("[TranscriptionClientLive] Using cache directory for downloads: \(cacheBaseDir.path)")
        } catch {
            // Log error - downloading might fail if cache dir can't be created
            print("Error creating cache directory ~/.cache/hex/: \(error). Download might fail or use default location.")
            // Decide how to handle: re-throw, or let WhisperKit use its default?
            // For now, we'll re-throw to make the failure explicit.
            throw error // Stop the process if we can't create the cache dir
        }
        // --- END MODIFIED SECTION ---
        
        
        // Create parent directories for the *final* destination (just in case)
        let parentDir = modelFolder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        do {
            // Download directly using the exact variant name provided, specifying the cache base
            print("[TranscriptionClientLive] Calling WhisperKit.download to cacheBaseDir...")
            let tempFolder = try await WhisperKit.download( // tempFolder will be inside cacheBaseDir
                variant: variant,
                downloadBase: cacheBaseDir, // <-- Use the custom cache directory
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                token: nil,
                progressCallback: { progress in
                    progressCallback(progress)
                }
            )
            print("[TranscriptionClientLive] WhisperKit download completed to temporary location: \(tempFolder.path)")
            
            // Ensure the *final* target folder exists (in Application Support)
            try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
            
            // Move the downloaded snapshot from the cache location to the final App Support location
            print("[TranscriptionClientLive] Moving contents from \(tempFolder.path) to final location \(modelFolder.path)")
            try moveContents(of: tempFolder, to: modelFolder) // Assuming moveContents is defined elsewhere in the class
            
            print("[TranscriptionClientLive] Successfully moved model \(variant) to: \(modelFolder.path)")
            
            // Optional: Clean up the temporary folder within the cache if `moveContents` didn't remove it
            // (Depends on how moveContents is implemented. If it moves items individually, the source folder might remain empty.)
            // try? fileManager.removeItem(at: tempFolder)
            
            
        } catch {
            // Clean up any potentially incomplete final model folder if an error occurred during download or move
            if FileManager.default.fileExists(atPath: modelFolder.path) {
                // Only remove if it looks incomplete; might be safer to leave it if unsure
                let isStillIncomplete = !(await isModelDownloaded(variant))
                if isStillIncomplete {
                    print("[TranscriptionClientLive] Cleaning up potentially incomplete model folder due to error: \(modelFolder.path)")
                    try? FileManager.default.removeItem(at: modelFolder)
                }
            }
            
            // Rethrow the original error
            print("[TranscriptionClientLive] Error during download/move process for model \(variant): \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Loads a local model folder via `WhisperKitConfig`, optionally reporting load progress.
    private func loadWhisperKitModel(
        _ modelName: String,
        progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let loadingProgress = Progress(totalUnitCount: 100)
        loadingProgress.completedUnitCount = 0
        progressCallback(loadingProgress)
        
        let modelFolder = modelPath(for: modelName)
        let tokenizerFolder = tokenizerPath(for: modelName)
        
        // Use WhisperKit's config to load the model
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            // verbose: true,
            // logLevel: .debug,
            prewarm: true,
            load: true
        )
        
        // The initializer automatically calls `loadModels`.
        whisperKit = try await WhisperKit(config)
        currentModelName = modelName
        
        // Finalize load progress
        loadingProgress.completedUnitCount = 100
        progressCallback(loadingProgress)
        
        print("[TranscriptionClientLive] Loaded WhisperKit model: \(modelName)")
    }
    
    /// Moves all items from `sourceFolder` into `destFolder` (shallow move of directory contents).
    private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
        for item in items {
            let src = sourceFolder.appendingPathComponent(item)
            let dst = destFolder.appendingPathComponent(item)
            try fileManager.moveItem(at: src, to: dst)
        }
    }
}
