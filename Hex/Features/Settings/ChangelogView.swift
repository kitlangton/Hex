import SwiftUI
import Inject
import MarkdownUI

struct ChangelogView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Changelog")
                    .font(.title)
                    .padding(.bottom, 10)

                if let changelogPath = Bundle.main.path(forResource: "changelog", ofType: "md"),
                    let changelogContent = try? String(
                        contentsOfFile: changelogPath, encoding: .utf8)
                {
                    Markdown(changelogContent)
                } else {
                    Text("Changelog could not be loaded.")
                        .foregroundColor(.red)
                }
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .enableInjection()
    }
}
