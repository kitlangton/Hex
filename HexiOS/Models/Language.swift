import Dependencies
import Foundation

struct Language: Codable, Identifiable, Hashable, Equatable {
  let code: String?
  let name: String
  var id: String { code ?? "auto" }
}

struct LanguageList: Codable {
  let languages: [Language]
}
