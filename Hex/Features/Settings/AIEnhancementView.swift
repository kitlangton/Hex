// 
//  AIEnhancementView.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import ComposableArchitecture
import SwiftUI

struct AIEnhancementView: View {
    @Bindable var store: StoreOf<AIEnhancementFeature>
    @State private var showExpandedPrompt = false
    @State private var isHoveringModelSelect = false
    
    var body: some View {
        Form {
            // Activation Section (Always show this first)
            Section {
                activationToggle
            } header: {
                Text("AI Enhancement")
            } footer: {
                Text("Enable AI to improve transcription quality by fixing grammar, formatting, and errors.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
            
            // Only show other settings if AI enhancement is enabled
            if store.hexSettings.useAIEnhancement {
                // Connection Status Section (only if AI enhancement is enabled)
                if !store.isOllamaAvailable {
                    Section {
                        connectionStatusView
                    } header: {
                        Text("Ollama Status")
                    }
                }
                
                // Model Selection Section
                modelSelectionSection
                
                // Temperature Control Section
                temperatureSection
                
                // Prompt Configuration Section
                promptSection
            }
        }
        .formStyle(.grouped)
        .task {
            await store.send(.task).finish()
        }
    }
    
    // MARK: - Component Views
    
    // Connection Status View
    private var connectionStatusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ollama Not Connected")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("AI enhancement requires Ollama to be installed and running locally.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("To set up Ollama:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    bulletPoint(text: "Download and install Ollama from [ollama.com](https://ollama.com)")
                    bulletPoint(text: "Launch the Ollama application")
                    bulletPoint(text: "Pull a language model (llama3 recommended)")
                }
                .padding(.leading, 8)
            }
            
            HStack {
                Spacer()
                
                Button {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                } label: {
                    Label("Download Ollama", systemImage: "arrow.down.circle")
                }
                .buttonStyle(DefaultButtonStyle())
                .foregroundColor(Color.blue)
                
                Button {
                    store.send(.checkOllamaAvailability)
                } label: {
                    Label("Check Connection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DefaultButtonStyle())
                .foregroundColor(Color.blue)
            }
            .padding(.top, 4)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1))
        )
    }
    
    // Activation Toggle
    private var activationToggle: some View {
        VStack(spacing: 8) {
            // Main toggle row
            Toggle(isOn: Binding(
                get: { store.hexSettings.useAIEnhancement },
                set: { newValue in 
                    store.$hexSettings.withLock { $0.useAIEnhancement = newValue }
                    
                    // When enabling, check Ollama status
                    if newValue {
                        Task {
                            await store.send(.checkOllamaAvailability).finish()
                        }
                    }
                }
            )) {
                Text("Use AI Enhancement")
                    .font(.body)
            }
            
            // Connection status indicator (only show if AI enhancement is enabled and Ollama is available)
            if store.hexSettings.useAIEnhancement && store.isOllamaAvailable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Ollama Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.leading, 2)
            }
        }
    }
    
    // Model Selection Section
    private var modelSelectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Model selection header
                HStack {
                    Label {
                        Text("Language Model")
                            .font(.body)
                    } icon: {
                        Image(systemName: "brain")
                    }
                    
                    Spacer()
                    
                    // Refresh button for models
                    Button {
                        store.send(.loadAvailableModels)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .disabled(store.isLoadingModels)
                    .opacity(store.isLoadingModels ? 0.5 : 0.7)
                }
                
                if store.isLoadingModels {
                    // Loading indicator
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading available models...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else if !store.isOllamaAvailable {
                    // Ollama not available message
                    Text("Ollama connection required to view models")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else if let error = store.errorMessage {
                    // Error message
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text("Error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                } else if store.availableModels.isEmpty {
                    // No models available
                    HStack(alignment: .center) {
                        Text("No models found in Ollama")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Link("Browse Models", destination: URL(string: "https://ollama.com/library")!)
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    .padding(.vertical, 8)
                } else {
                    // Model picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Select AI model:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Picker("", selection: Binding(
                            get: { store.hexSettings.selectedAIModel },
                            set: { store.send(.setSelectedModel($0)) }
                        )) {
                            ForEach(store.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("Model Selection")
        } footer: {
            if !store.availableModels.isEmpty {
                Text("Smaller models are faster but less capable. Llama3 offers a good balance of speed and quality.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }
    
    // Temperature Section
    private var temperatureSection: some View {
        Section {
            // Label with temperature value
            HStack {
                Text("Response Style")
                    .font(.subheadline)
                
                Spacer()
                
                Text("\(store.hexSettings.aiEnhancementTemperature, specifier: "%.2f")")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40)
            }
            .padding(.bottom, 4)
            
            // Slider for temperature control - extend even further
            ZStack {
                Slider(
                    value: Binding(
                        get: { store.hexSettings.aiEnhancementTemperature },
                        set: { newValue in
                            store.$hexSettings.withLock { $0.aiEnhancementTemperature = newValue }
                        }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .padding(.horizontal, -40)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40)
            
            // Temperature descriptions
            HStack {
                Text("Precision")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Creativity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 0)
            .padding(.top, 4)
        } header: {
            Text("Response Style")
        } footer: {
            Text("Lower values produce more consistent, conservative improvements. Higher values allow more creative rewording.")
                .foregroundColor(.secondary.opacity(0.7))
                .font(.caption)
        }
    }
    
    // Prompt Configuration Section
    private var promptSection: some View {
        Section {
            VStack(spacing: 0) {
                // Header with edit button
                HStack {
                    Label {
                        Text("Instructions")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    
                    Spacer()
                    
                    Button(showExpandedPrompt ? "Done" : "Edit") {
                        withAnimation(.spring(duration: 0.3)) {
                            showExpandedPrompt.toggle()
                        }
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(showExpandedPrompt ? Color.primary : Color.accentColor)
                    .font(.caption)
                }
                .padding(.bottom, 8)
                
                if showExpandedPrompt {
                    // Expanded editor view
                    VStack(spacing: 8) {
                        // Editor
                        TextEditor(text: Binding(
                            get: { store.hexSettings.aiEnhancementPrompt },
                            set: { newValue in
                                store.$hexSettings.withLock { $0.aiEnhancementPrompt = newValue }
                            }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        
                        // Reset button
                        Button("Reset to Default") {
                            store.send(.resetToDefaultPrompt)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Collapsed preview
                    Text(store.hexSettings.aiEnhancementPrompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.05))
                        )
                }
            }
        } header: {
            Text("Enhancement Prompt")
        } footer: {
            if !showExpandedPrompt {
                Text("These instructions tell the AI how to improve your transcribed text.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            } else {
                Text("Make changes to customize how the AI enhances your transcriptions. Be specific about what should be preserved or changed.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }
    
    // Helper for bullet points
    private func bulletPoint(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
