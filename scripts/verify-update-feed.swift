import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("Update feed verification failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: swift verify-update-feed.swift <appcast.xml> <Info.plist>")
}

let feedURL = URL(fileURLWithPath: CommandLine.arguments[1])
let plistURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let feed = try? Data(contentsOf: feedURL),
      let text = String(data: feed, encoding: .utf8) else {
    fail("Cannot read the UTF-8 appcast")
}
guard let properties = try? PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil
) as? [String: Any],
      properties["SURequireSignedFeed"] as? Bool == true,
      properties["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      let encodedKey = properties["SUPublicEDKey"] as? String,
      let keyData = Data(base64Encoded: encodedKey),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("The app must require signed feeds and pre-extraction checks with a valid public key")
}

let marker = "<!-- sparkle-signatures:\n"
guard let range = text.range(of: marker, options: .backwards) else {
    fail("Missing Sparkle signature footer")
}
let signed = String(text[..<range.lowerBound])
let signedData = Data(signed.utf8)
let footer = String(text[range.lowerBound...])
let lines = footer.split(separator: "\n", omittingEmptySubsequences: false)
guard lines.count == 5,
      lines[0] == "<!-- sparkle-signatures:",
      lines[1].hasPrefix("edSignature: "),
      lines[2].hasPrefix("length: "),
      lines[3] == "-->", lines[4].isEmpty,
      let expectedLength = Int(lines[2].dropFirst("length: ".count)),
      expectedLength == signedData.count,
      let signature = Data(base64Encoded: String(lines[1].dropFirst("edSignature: ".count))),
      key.isValidSignature(signature, for: signedData) else {
    fail("The feed signature, signed length, or footer is invalid")
}

print("Verified the signed appcast with the app's public key and update settings.")
