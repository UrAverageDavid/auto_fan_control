import Foundation

public protocol ConfigurationStore { func load() throws -> Configuration; func save(_ configuration: Configuration) throws }
public struct JSONConfigurationStore: ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw FanError.invalid("Unsupported configuration version. Your file has been preserved.") }
        guard Set(value.presets.map(\.id)).count == value.presets.count,
              Set(value.rules.map(\.id)).count == value.rules.count,
              Set(value.rules.map(\.bundleID)).count == value.rules.count else { throw FanError.invalid("Duplicate configuration identifiers.") }
        return value
    }
    public func save(_ configuration: Configuration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}
