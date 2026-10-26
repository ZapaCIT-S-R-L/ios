import Foundation

/// The parental agreement a parent accepts on first launch, before signing in.
public enum ParentalAgreement {
    /// TODO: placeholder (version 0) until the reviewed legal text exists. When the real text ships, raise this to 1
    /// so every parent accepts it again, and send the accepted version to the API (the consent record).
    public static let currentVersion = 0
}

/// Remembers which agreement version this phone accepted.
@MainActor
public protocol AgreementStore: AnyObject {
    var acceptedVersion: Int? { get }
    func accept(version: Int)
}

public final class UserDefaultsAgreementStore: AgreementStore {
    private let defaults: UserDefaults
    private let key = "parentalAgreement.acceptedVersion"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var acceptedVersion: Int? {
        defaults.object(forKey: key) as? Int
    }

    public func accept(version: Int) {
        defaults.set(version, forKey: key)
    }
}

public final class InMemoryAgreementStore: AgreementStore {
    public private(set) var acceptedVersion: Int?

    public init(acceptedVersion: Int? = nil) {
        self.acceptedVersion = acceptedVersion
    }

    public func accept(version: Int) {
        acceptedVersion = version
    }
}
