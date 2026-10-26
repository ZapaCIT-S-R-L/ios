#if canImport(DeclaredAgeRange)
    import DeclaredAgeRange
#endif
import UIKit
import ZapaKidKit

/// Asks the system whether the person signing in is 18 or older.
@MainActor
protocol AgeRangeProviding {
    /// `nil` when the age can't be known (iOS before 26, or an error); the API then decides.
    func ageRange() async -> AgeRange?
}

/// Apple's Declared Age Range (iOS 26+, needs the `com.apple.developer.declared-age-range` entitlement).
struct DeclaredAgeRangeCheck: AgeRangeProviding {
    func ageRange() async -> AgeRange? {
        #if canImport(DeclaredAgeRange)
            if #available(iOS 26.0, *) {
                let controller = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                    .first
                guard let controller else { return nil }
                do {
                    switch try await AgeRangeService.shared.requestAgeRange(ageGates: 18, in: controller) {
                    case .declinedSharing:
                        return AgeRange(lower: nil, upper: nil, declined: true)
                    case let .sharing(range):
                        return AgeRange(lower: range.lowerBound, upper: range.upperBound, declined: false)
                    @unknown default:
                        return nil
                    }
                } catch {
                    return nil
                }
            }
        #endif
        return nil
    }
}
