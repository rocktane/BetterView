import CryptoKit
import Foundation

// Validate the actual published bytes against the public key shipped inside the app.
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "BetterView.Release", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func verify() throws {
    try require(CommandLine.arguments.count == 4, "Usage: verify-release.swift appcast.xml archive.zip Info.plist")
    let feedURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let plistURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
    let version = plist["CFBundleVersion"] as! String
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as! String)!)
    let document = try XMLDocument(contentsOf: feedURL)
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected exactly one release in the appcast")
    let item = items[0] as! XMLElement
    let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    try require(item.elements(forLocalName: "version", uri: sparkle).first?.stringValue == version, "Appcast version differs from the app")
    try require(item.elements(forLocalName: "minimumSystemVersion", uri: sparkle).first?.stringValue == plist["LSMinimumSystemVersion"] as? String, "Wrong minimum macOS version")
    guard let enclosure = item.elements(forName: "enclosure").first,
          let signatureString = enclosure.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue,
          let signature = Data(base64Encoded: signatureString) else {
        throw NSError(domain: "BetterView.Release", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing Sparkle signature"])
    }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Wrong archive length")
    let expectedURL = "https://github.com/rocktane/BetterView/releases/download/v\(version)/\(archiveURL.lastPathComponent)"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "Wrong download URL")
    try require(publicKey.isValidSignature(signature, for: archive), "The archive does not match the app's Sparkle public key")
    print("Verified appcast, version, macOS requirement, URL and Ed25519 archive signature.")
}

do {
    try verify()
} catch {
    FileHandle.standardError.write(Data("Release verification failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
