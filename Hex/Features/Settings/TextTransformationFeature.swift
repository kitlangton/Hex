import ComposableArchitecture
import Foundation
import HexCore

@Reducer
struct TextTransformationFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.hexSettings) var hexSettings: HexSettings
		var previewText: String = "Hello World! This is a test."
		var previewResult: String = ""
		var isPreviewLoading: Bool = false
		
		var editingReplacement: ReplaceTextConfig?
		var editingPrefix: String?
		var editingSuffix: String?
	}
	
	enum Action: BindableAction {
		case binding(BindingAction<State>)
		
		// Pipeline control
		case togglePipeline
		case addTransformation(TransformationType)
		case deleteTransformation(UUID)
		case toggleTransformation(UUID)
		case moveTransformation(from: Int, to: Int)
		
		// Editing
		case startEditingReplacement(UUID?)
		case saveReplacement(ReplaceTextConfig)
		case cancelEditing
		
		case startEditingPrefix(UUID?)
		case savePrefix(UUID?, String)
		
		case startEditingSuffix(UUID?)
		case saveSuffix(UUID?, String)
		
		// Preview
		case updatePreview
		case previewUpdated(String)
	}
	
	var body: some ReducerOf<Self> {
		BindingReducer()
		
		Reduce { state, action in
			switch action {
			case .binding:
				return .none
				
			case .togglePipeline:
				state.$hexSettings.withLock { settings in
					settings.textTransformationPipeline.isEnabled.toggle()
				}
				return .send(.updatePreview)
				
			case let .addTransformation(type):
				state.$hexSettings.withLock { settings in
					settings.textTransformationPipeline.transformations.append(
						Transformation(type: type)
					)
				}
				return .send(.updatePreview)
				
			case let .deleteTransformation(id):
				state.$hexSettings.withLock { settings in
					settings.textTransformationPipeline.transformations.removeAll { $0.id == id }
				}
				return .send(.updatePreview)
				
			case let .toggleTransformation(id):
				state.$hexSettings.withLock { settings in
					if let index = settings.textTransformationPipeline.transformations.firstIndex(where: { $0.id == id }) {
						settings.textTransformationPipeline.transformations[index].isEnabled.toggle()
					}
				}
				return .send(.updatePreview)
				
			case let .moveTransformation(from, to):
				state.$hexSettings.withLock { settings in
					settings.textTransformationPipeline.move(from: from, to: to)
				}
				return .send(.updatePreview)
				
			case let .startEditingReplacement(id):
				if let id = id,
				   let transformation = state.hexSettings.textTransformationPipeline.transformations.first(where: { $0.id == id }),
				   case .replaceText(let config) = transformation.type {
					state.editingReplacement = config
				} else {
					state.editingReplacement = ReplaceTextConfig(pattern: "", replacement: "")
				}
				return .none
				
			case let .saveReplacement(config):
				state.$hexSettings.withLock { settings in
					if let index = settings.textTransformationPipeline.transformations.firstIndex(where: { $0.id == config.id }) {
						settings.textTransformationPipeline.transformations[index].type = .replaceText(config)
					} else {
						settings.textTransformationPipeline.transformations.append(
							Transformation(type: .replaceText(config))
						)
					}
				}
				state.editingReplacement = nil
				return .send(.updatePreview)
				
			case .cancelEditing:
				state.editingReplacement = nil
				state.editingPrefix = nil
				state.editingSuffix = nil
				return .none
				
			case let .startEditingPrefix(id):
				if let id = id,
				   let transformation = state.hexSettings.textTransformationPipeline.transformations.first(where: { $0.id == id }),
				   case .addPrefix(let prefix) = transformation.type {
					state.editingPrefix = prefix
				} else {
					state.editingPrefix = ""
				}
				return .none
				
			case let .savePrefix(id, prefix):
				state.$hexSettings.withLock { settings in
					if let id = id,
					   let index = settings.textTransformationPipeline.transformations.firstIndex(where: { $0.id == id }) {
						settings.textTransformationPipeline.transformations[index].type = .addPrefix(prefix)
					} else {
						settings.textTransformationPipeline.transformations.append(
							Transformation(type: .addPrefix(prefix))
						)
					}
				}
				state.editingPrefix = nil
				return .send(.updatePreview)
				
			case let .startEditingSuffix(id):
				if let id = id,
				   let transformation = state.hexSettings.textTransformationPipeline.transformations.first(where: { $0.id == id }),
				   case .addSuffix(let suffix) = transformation.type {
					state.editingSuffix = suffix
				} else {
					state.editingSuffix = ""
				}
				return .none
				
			case let .saveSuffix(id, suffix):
				state.$hexSettings.withLock { settings in
					if let id = id,
					   let index = settings.textTransformationPipeline.transformations.firstIndex(where: { $0.id == id }) {
						settings.textTransformationPipeline.transformations[index].type = .addSuffix(suffix)
					} else {
						settings.textTransformationPipeline.transformations.append(
							Transformation(type: .addSuffix(suffix))
						)
					}
				}
				state.editingSuffix = nil
				return .send(.updatePreview)
				
			case .updatePreview:
				state.isPreviewLoading = true
				let text = state.previewText
				let pipeline = state.hexSettings.textTransformationPipeline
				
				return .run { send in
					let result = await pipeline.process(text)
					await send(.previewUpdated(result))
				}
				
			case let .previewUpdated(result):
				state.isPreviewLoading = false
				state.previewResult = result
				return .none
			}
		}
	}
}
