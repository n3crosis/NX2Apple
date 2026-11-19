import Foundation

/// An app-opening wrapper around the existing authenticated sharing invitation.
/// Parsing never starts a transfer or grants permission for an internet transfer.
public enum GamePackageReceiveLink {
    public static func appURL(for invitation: URL) throws -> URL {
        _ = try GamePackageShareInvitation(url: invitation, remote: invitation.scheme == "https")
        var parts = URLComponents()
        parts.scheme = "nx2apple"
        parts.host = "receive"
        parts.queryItems = [URLQueryItem(name: "url", value: invitation.absoluteString)]
        guard let url = parts.url else { throw GamePackageError.invalid("invalid receive link") }
        return url
    }

    public static func invitation(from url: URL) throws -> URL {
        guard url.absoluteString.hasPrefix("nx2apple://receive?"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "nx2apple", parts.host == "receive",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1,
              items[0].name == "url", let value = items[0].value,
              let invitation = URL(string: value) else {
            throw GamePackageError.invalid("invalid receive link")
        }
        _ = try GamePackageShareInvitation(url: invitation, remote: invitation.scheme == "https")
        return invitation
    }
}
