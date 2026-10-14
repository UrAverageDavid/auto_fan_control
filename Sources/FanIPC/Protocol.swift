import Foundation
import Security
import FanCore

public enum HelperConstants {
    public static let service = "local.autofancontrol.helper"
    public static let appID = "local.autofancontrol.app"
    public static let plist = "local.autofancontrol.helper.plist"
    public static func teamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let data = information as? [String: Any] else { return nil }
        return data[kSecCodeInfoTeamIdentifier as String] as? String
    }
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
@objc public protocol FanHelperProtocol {
    func capabilities(reply: @escaping (Data?, String?) -> Void)
    func startOrUpdate(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    func status(reply: @escaping (Data?, String?) -> Void)
    func restoreAutomatic(reply: @escaping (Data?, String?) -> Void)
}
public struct Capabilities: Codable {
    public var identity: HardwareIdentity
    public var validated: Bool
    public var message: String
    public init(identity: HardwareIdentity, validated: Bool, message: String) {
        self.identity = identity; self.validated = validated; self.message = message
    }
}
public struct SessionRequest: Codable {
    public var identity: HardwareIdentity
    public var presets: [Preset]
    public init(identity: HardwareIdentity, presets: [Preset]) { self.identity = identity; self.presets = presets }
}
