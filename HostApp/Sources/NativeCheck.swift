import Foundation
import CryptoKit

/// Compares the native libraries of the game that was just imported with the ones this app was built with. The app's copies were converted from the game's
/// macOS libraries (scripts/prepare-game-natives.sh), which also wrote native_manifest.json: the SHA-256 of every original. iOS only loads libraries that are
/// inside the app bundle, so when the game ships newer libraries the app has to be rebuilt (scripts/update-game-libs.sh); this tells the user.
enum NativeCheck {
    struct Manifest: Decodable { let java: [String: String]; let jar: [String: String] }
    struct Result: Codable { let date: Date; let matched: Int; let differ: [String]; let missing: [String] }
    private static let key = "zom.nativeCheck"

    /// Read once and kept: this is decoded JSON plus a bundle lookup, and the home screen asks for it on every redraw.
    static let manifest: Manifest? = {
        let b = Bundle.main
        guard let u = b.url(forResource: "native_manifest", withExtension: "json") ?? b.url(forResource: "native_manifest", withExtension: "json", subdirectory: "runtime/natives"),
              let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: d)
    }()
    static var last: Result? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Result.self, from: $0) } }
    static func store(_ r: Result?) {
        if let r = r, let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var finished = false
        while !finished { autoreleasepool { if let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) } else { finished = true } } }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `java` gives, per library file name, a way to get that file from the imported game (copying or extracting it to a temporary file).
    static func check(java: [String: () throws -> URL], jar: URL) -> Result? {
        guard let m = manifest else { return nil }
        var matched = 0, differ: [String] = [], missing: [String] = []
        func judge(_ name: String, _ want: String, _ url: URL?) {
            guard let url = url, let got = sha256(url) else { missing.append(name); return }
            if got == want { matched += 1 } else { differ.append(name) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pznative", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (name, want) in m.java.sorted(by: { $0.key < $1.key }) { judge(name.replacingOccurrences(of: ".dylib", with: ""), want, try? java[name]?()) }
        if let zip = try? ZipArchive(url: jar) {
            for (path, want) in m.jar.sorted(by: { $0.key < $1.key }) {
                let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".dylib", with: "")
                if let e = zip.entries.first(where: { $0.name == path }) {
                    let dest = tmp.appendingPathComponent(UUID().uuidString)
                    try? zip.extract(e, to: dest, progress: { _ in }); judge(name, want, dest); try? FileManager.default.removeItem(at: dest)
                } else { missing.append(name) }
            }
        } else { missing += m.jar.keys.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".dylib", with: "") } }
        return Result(date: Date(), matched: matched, differ: differ, missing: missing)
    }

    /// One line for the Setup guide: nil when there is nothing to say (no manifest in this build, or the game was imported before this check existed).
    static func message(_ r: Result) -> (text: String, warning: Bool) {
        if !r.differ.isEmpty {
            let names = r.differ.prefix(3).joined(separator: ", ") + (r.differ.count > 3 ? " and \(r.differ.count - 3) more" : "")
            return ("This game's native libraries differ from the ones inside the app (\(names)), so it was probably updated. The game may crash or not start. Rebuild the app with that game's libraries: see \"Using a different build of Project Zomboid\" in the README (scripts/update-game-libs.sh).", true)
        }
        if r.matched == 0 { return ("The game's native libraries weren't in what you imported, so they couldn't be compared with the app's.", false) }
        return ("The game's native libraries match the ones inside the app (\(r.matched) checked).", false)
    }
}
