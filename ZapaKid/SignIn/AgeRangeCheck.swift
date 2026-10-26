#if canImport(DeclaredAgeRange)
    import DeclaredAgeRange
#endif
import UIKit
import ZapaKidKit

/// Asks the system whether the person signing in is 18 or older.
@MainActor
protocol AgeRangeProviding {
    func ageRange() async -> AgeRange
}

/// Apple's Declared Age Range (iOS 26+, needs the `com.apple.developer.declared-age-range` entitlement), mapped as
/// openapi.yaml says: `.sharing(range)` → shared, `.declinedSharing` → declined, not offered → unavailable.
struct DeclaredAgeRangeCheck: AgeRangeProviding {
    func ageRange() async -> AgeRange {
        #if canImport(DeclaredAgeRange)
            if #available(iOS 26.0, *) {
                let controller = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                    .first
                guard let controller else { return .unavailable }
                do {
                    switch try await AgeRangeService.shared.requestAgeRange(ageGates: 18, in: controller) {
                    case .declinedSharing:
                        return .declined(platformStatus: "declinedSharing")
                    case let .sharing(range):
                        return .shared(lower: range.lowerBound, upper: range.upperBound, platformStatus: "sharing")
                    @unknown default:
                        return .unavailable
                    }
                } catch {
                    // Not offered here (region, account type) or not available right now.
                    return .unavailable
                }
            }
        #endif
        return .unavailable
    }
}
