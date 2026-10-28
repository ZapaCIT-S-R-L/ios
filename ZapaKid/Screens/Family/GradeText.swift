import SwiftUI

/// -1 kindergarten, 0 preparatory class, 1–12 school grade (Romanian school system), nil not set.
enum GradeText {
    static let all: [Int?] = [nil, -1, 0] + (1 ... 12).map { Optional($0) }

    static func text(_ grade: Int?) -> Text {
        switch grade {
        case nil: Text("No grade")
        case -1: Text("Kindergarten")
        case 0: Text("Preparatory class")
        case let grade?: Text("Grade \(grade)")
        }
    }
}
