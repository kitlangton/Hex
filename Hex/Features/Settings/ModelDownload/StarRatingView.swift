import Inject
import SwiftUI

struct StarRatingView: View {
	@ObserveInjection var inject
	let filled: Int
	let max: Int

	init(_ filled: Int, max: Int = 5) {
		self.filled = filled
		self.max = max
	}

	var body: some View {
		HStack(spacing: 3) {
			ForEach(0 ..< max, id: \.self) { i in
				Image(systemName: i < filled ? "circle.fill" : "circle")
					.font(.system(size: 7))
					.foregroundColor(i < filled ? .blue : .gray.opacity(0.5))
			}
		}
		.enableInjection()
	}
}

