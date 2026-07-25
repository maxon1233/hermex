import Foundation

enum AppConfig {
    static let privacyPolicyURL = URL(staticString: "https://www.uzairansar.com/hermes-mobile/privacy")
    static let supportURL = URL(staticString: "https://www.uzairansar.com/hermes-mobile")
}

struct AppBuildSource: Equatable {
    private static let sourceSHAKey = "HermexBuildSourceSHA"
    private static let sourceBranchKey = "HermexBuildSourceBranch"
    private static let upstreamSHAKey = "HermexBuildUpstreamSHA"
    private static let sourceDirtyKey = "HermexBuildSourceDirty"

    let sourceSHA: String
    let sourceBranch: String
    let upstreamSHA: String
    let sourceIsDirty: Bool

    static var current: AppBuildSource? {
        guard let infoDictionary = Bundle.main.infoDictionary else { return nil }
        return AppBuildSource(infoDictionary: infoDictionary)
    }

    init?(infoDictionary: [String: Any]) {
        guard
            let sourceSHA = Self.fullSHA(infoDictionary[Self.sourceSHAKey]),
            let upstreamSHA = Self.fullSHA(infoDictionary[Self.upstreamSHAKey]),
            let sourceBranch = infoDictionary[Self.sourceBranchKey] as? String,
            !sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let dirtyValue = infoDictionary[Self.sourceDirtyKey] as? String,
            ["YES", "NO"].contains(dirtyValue.uppercased())
        else {
            return nil
        }

        self.sourceSHA = sourceSHA
        self.sourceBranch = sourceBranch
        self.upstreamSHA = upstreamSHA
        sourceIsDirty = dirtyValue.uppercased() == "YES"
    }

    var displayValue: String {
        "\(sourceBranch) · \(sourceSHA.prefix(8))\(sourceIsDirty ? " dirty" : "")"
    }

    private static func fullSHA(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return normalized
    }
}

extension URL {
    init(staticString string: StaticString) {
        let value = string.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static URL literal: \(value)")
        }
        self = url
    }
}
