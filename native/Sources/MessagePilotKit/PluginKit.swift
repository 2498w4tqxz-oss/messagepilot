import Foundation

/// Parses `pluginkit -mA -vv` output. Messages on macOS hosts iMessage apps and sticker packs as
/// Mac Catalyst extensions of the `com.apple.message-payload-provider` point, the same point iOS
/// uses, so a line's own iMessage app must be built for Mac Catalyst to appear in its Messages.
public enum PluginKit {
  public static let messagesExtensionPoint = "com.apple.message-payload-provider"

  public static func parse(_ output: String) -> [[String: String]] {
    var records: [[String: String]] = []
    var current: [String: String]?
    for rawLine in output.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if let eq = line.range(of: " = "), rawLine.hasPrefix("\t") {
        let key = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
        current?[key] = String(line[eq.upperBound...])
        continue
      }
      if let current { records.append(current) }
      // Header: "[+-=!]?  bundle.id(version)"; a leading + means the user enabled it, - disabled.
      var header = line
      var election = "default"
      if let first = header.first, "+-=!".contains(first) {
        election = ["+": "enabled", "-": "disabled", "=": "default", "!": "debug"][String(first)]!
        header = header.dropFirst().trimmingCharacters(in: .whitespaces)
      }
      var id = header
      var version = ""
      if let open = header.lastIndex(of: "("), header.hasSuffix(")") {
        id = String(header[..<open])
        version = String(header[header.index(after: open)..<header.index(before: header.endIndex)])
      }
      current = ["id": id, "version": version, "election": election]
    }
    if let current { records.append(current) }
    return records
  }

  public static func messagesExtensions(_ output: String) -> [[String: Any]] {
    parse(output).filter { $0["SDK"] == messagesExtensionPoint }.map { r in
      [
        "id": r["id"] ?? "",
        // Apple's display names can contain non-breaking spaces ("Apple\u{00A0}Cash").
        "name": (r["Display Name"] ?? r["Short Name"] ?? "").replacingOccurrences(
          of: "\u{00A0}", with: " "),
        "path": r["Path"] ?? "", "platform": r["Platform"] ?? "", "parent": r["Parent Name"] ?? "",
        "election": r["election"] ?? "default",
        "system": (r["Path"] ?? "").hasPrefix("/System/"),
      ]
    }
  }
}
