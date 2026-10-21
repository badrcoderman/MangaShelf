import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Metadata from a converted extension JAR, not publisher authentication or
/// proof that the declared class implements the source ABI.
public struct ExtensionPackageManifest: Codable, Equatable, Sendable {
    public let packageName: String
    public let versionCode: UInt64
    public let versionName: String?
    public let mainClass: String

    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.uppercased().contains("<!DOCTYPE"),
              !text.uppercased().contains("<!ENTITY") else {
            throw JARInspectionError.invalidManifest
        }
        let delegate = ManifestReader()
        let parser = XMLParser(data: data)
        // Keep qualified attribute names so namespace aliases can be resolved
        // against the declarations in scope on each element.
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid,
              let package = delegate.packageName, validJavaName(package),
              let version = delegate.versionCode,
              delegate.applicationSeen, delegate.extensionFeature,
              let declaredClass = delegate.sourceClass else {
            throw JARInspectionError.invalidManifest
        }
        let name = declaredClass.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainClass = name.hasPrefix(".") ? package + name : name
        guard validJavaName(mainClass) else { throw JARInspectionError.invalidManifest }
        return Self(packageName: package, versionCode: version,
                    versionName: delegate.versionName, mainClass: mainClass)
    }

    private static func validJavaName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            guard let first = component.utf8.first else { return false }
            func letter(_ c: UInt8) -> Bool {
                (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 36
            }
            return letter(first) && component.utf8.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
        }
    }
}

private final class ManifestReader: NSObject, XMLParserDelegate {
    private static let androidNamespace = "http://schemas.android.com/apk/res/android"
    private var path: [String] = []
    private var namespaces: [[String: String]] = []
    private var elements = 0
    var invalid = false
    var packageName: String?
    var versionCode: UInt64?
    var versionName: String?
    var sourceClass: String?
    var applicationSeen = false
    var extensionFeature = false

    private func fail(_ parser: XMLParser) {
        invalid = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        elements += 1
        guard path.count < 32, elements <= 4096, attributes.count <= 64 else { fail(parser); return }
        var mapping = namespaces.last ?? [:]
        for (name, value) in attributes {
            if name == "xmlns" { mapping[""] = value }
            else if name.hasPrefix("xmlns:") { mapping[String(name.dropFirst(6))] = value }
        }
        namespaces.append(mapping)
        path.append(elementName)
        guard (mapping[""] ?? "").isEmpty else { fail(parser); return }

        func android(_ name: String) -> String? {
            let matching = attributes.filter { key, _ in
                let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                return parts.count == 2 && parts[1] == name
                    && mapping[String(parts[0])] == Self.androidNamespace
            }
            if matching.count > 1 { fail(parser) }
            return matching.first?.value
        }
        if path.count == 1 {
            guard elementName == "manifest", let package = attributes["package"],
                  let code = android("versionCode"), !code.isEmpty,
                  code.utf8.allSatisfy({ (48...57).contains($0) }),
                  let version = UInt64(code) else { fail(parser); return }
            packageName = package
            versionCode = version
            versionName = android("versionName")
        } else if path == ["manifest", "application"] {
            guard !applicationSeen else { fail(parser); return }
            applicationSeen = true
        } else if path == ["manifest", "uses-feature"] {
            if android("name") == "tachiyomi.extension" { extensionFeature = true }
        } else if path == ["manifest", "application", "meta-data"] {
            if android("name") == "tachiyomi.extension.class" {
                guard sourceClass == nil, let value = android("value") else { fail(parser); return }
                sourceClass = value
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard path.last == elementName else { fail(parser); return }
        path.removeLast()
        namespaces.removeLast()
    }
}
