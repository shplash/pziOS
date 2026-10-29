// Where the game's own files live, and the in-app importer that puts them there.
// The jar goes to Documents/projectzomboid.jar and the data to Documents/game/ (media, stdlib.*, license). The importer reads either a folder or a
// .zip of the Mac game (right-click > Compress on the Mac, then AirDrop it). Only what the game needs is written; Mac libraries, the bundled
// Java, the launcher and finder clutter are never extracted. The iOS builds of the native libraries come with the app.
import Foundation
import os
import Compression
import SwiftUI

enum GameFiles {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var jar: URL { documents.appendingPathComponent("projectzomboid.jar") }
    static var gameDir: URL { documents.appendingPathComponent("game", isDirectory: true) }

    static var installed: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: jar.path)
            && FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("media").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The 2x (high definition) texture packs are only needed for the High Definition Textures option.
    static var has2xPacks: Bool { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("media/texturepacks/Tiles2x.pack").path) }

    /// The game files and saves are large and can be re-imported, so they stay out of iCloud backups. Cheap; safe to call on every launch.
    static func excludeFromBackup() {
        for var url in [jar, gameDir] where FileManager.default.fileExists(atPath: url.path) {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// What is taken from a Project Zomboid install (relative to the folder that holds media/).
    static let dataItems = ["media", "stdlib.lbc", "stdlib.lua", "license", "terms and conditions.txt", "terms"]

    /// Files that are never needed on iOS: Mac libraries and Finder clutter. Everything else the game needs is imported.
    static func skip(_ rel: String) -> Bool {
        let parts = rel.lowercased().split(separator: "/").map(String.init)
        let file = parts.last ?? ""
        return parts.contains("__macosx") || file == ".ds_store" || file.hasPrefix("._") || file.hasSuffix(".dylib")
    }
}

@objc(ZomGameFiles)
public final class ZomGameFiles: NSObject {
    @objc public static var installed: Bool { GameFiles.installed }
    @objc public static var has2xPacks: Bool { GameFiles.has2xPacks }
    @objc public static func excludeFromBackup() { GameFiles.excludeFromBackup() }
}

// MARK: - ZIP reading (no dependencies; zip64 and deflate; the game has about 47,000 files and is larger than 4 GB)

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: UInt64
    let size: UInt64
    let localOffset: UInt64
    var isDirectory: Bool { name.hasSuffix("/") }
}

final class ZipArchive {
    let entries: [ZipEntry]
    private let handle: FileHandle
    private var wrapOffsets = false
    private var archiveSize: UInt64 = 0

    struct ZipError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(u16(b, o)) | UInt32(u16(b, o + 2)) << 16 }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    init(url: URL) throws {
        let h = try FileHandle(forReadingFrom: url)
        handle = h
        let end = try h.seekToEnd()
        guard end > 22 else { throw ZipError(message: "That file is too small to be a zip archive.") }
        let tailLength = min(end, 70_000)
        try h.seek(toOffset: end - tailLength)
        let tail = [UInt8](try h.read(upToCount: Int(tailLength)) ?? Data())

        var eocd = -1
        var i = tail.count - 22
        while i >= 0 { if Self.u32(tail, i) == 0x0605_4b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw ZipError(message: "That doesn't look like a zip archive (no end-of-archive record).") }

        var total = UInt64(Self.u16(tail, eocd + 10))
        var cdSize = UInt64(Self.u32(tail, eocd + 12))
        var cdOffset = UInt64(Self.u32(tail, eocd + 16))
        var isZip64 = false
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {              // zip64
            guard eocd >= 20, Self.u32(tail, eocd - 20) == 0x0706_4b50 else { throw ZipError(message: "Unsupported zip64 layout.") }
            let z64 = Self.u64(tail, eocd - 20 + 8)
            try h.seek(toOffset: z64)
            let rec = [UInt8](try h.read(upToCount: 56) ?? Data())
            guard rec.count >= 56, Self.u32(rec, 0) == 0x0606_4b50 else { throw ZipError(message: "Couldn't read the zip64 directory.") }
            total = Self.u64(rec, 32); cdSize = Self.u64(rec, 40); cdOffset = Self.u64(rec, 48)
            isZip64 = true
        }
        guard cdSize < 1 << 31 else { throw ZipError(message: "The archive's directory is too large.") }

        // Finder's Compress writes archives over 4 GB without zip64 records, so every stored position wraps at 4 GB. The directory is found by
        // working back from the end of the file, and file positions are repaired below by counting the wraps.
        let eocdAbsolute = end - tailLength + UInt64(eocd)
        func hasDirectory(at offset: UInt64) -> Bool {
            guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
            return [UInt8](d) == [0x50, 0x4b, 0x01, 0x02]
        }
        if !hasDirectory(at: cdOffset) {
            guard eocdAbsolute >= cdSize, hasDirectory(at: eocdAbsolute - cdSize) else { throw ZipError(message: "Couldn't find the archive's file directory.") }
            cdOffset = eocdAbsolute - cdSize
        }
        wrapOffsets = !isZip64 && end > 0xFFFF_FFFF
        try h.seek(toOffset: cdOffset)
        let cd = [UInt8](try h.read(upToCount: Int(cdSize)) ?? Data())
        archiveSize = end

        var list: [ZipEntry] = []
        list.reserveCapacity(Int(min(total, 400_000)))
        var p = 0
        var previousStored: UInt64 = 0, wraps: UInt64 = 0
        while p + 46 <= cd.count, Self.u32(cd, p) == 0x0201_4b50 {
            let flags = Self.u16(cd, p + 8)
            let method = Self.u16(cd, p + 10)
            var comp = UInt64(Self.u32(cd, p + 20)), size = UInt64(Self.u32(cd, p + 24))
            let nameLen = Int(Self.u16(cd, p + 28)), extraLen = Int(Self.u16(cd, p + 30)), commentLen = Int(Self.u16(cd, p + 32))
            var offset = UInt64(Self.u32(cd, p + 42))
            let storedOffset = offset
            let wasZip64Offset = offset == 0xFFFF_FFFF
            guard p + 46 + nameLen + extraLen <= cd.count else { break }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            _ = flags
            if comp == 0xFFFF_FFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {              // zip64 extra field
                var q = p + 46 + nameLen, stop = q + extraLen
                while q + 4 <= stop {
                    let id = Self.u16(cd, q), len = Int(Self.u16(cd, q + 2))
                    if id == 0x0001 {
                        var r = q + 4
                        if size == 0xFFFF_FFFF, r + 8 <= stop { size = Self.u64(cd, r); r += 8 }
                        if comp == 0xFFFF_FFFF, r + 8 <= stop { comp = Self.u64(cd, r); r += 8 }
                        if offset == 0xFFFF_FFFF, r + 8 <= stop { offset = Self.u64(cd, r); r += 8 }
                    }
                    q += 4 + len
                    if q > stop { stop = q }
                }
            }
            if wrapOffsets && !wasZip64Offset {                                        // entries are listed in archive order, so a drop means the 32-bit value wrapped
                if storedOffset < previousStored { wraps += 1 }
                previousStored = storedOffset
                offset = storedOffset + (wraps << 32)
            }
            list.append(ZipEntry(name: name, method: method, compressedSize: comp, size: size, localOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !list.isEmpty else { throw ZipError(message: "The zip archive is empty or couldn't be read.") }
        entries = list
    }

    deinit { try? handle.close() }

    /// Writes one entry to `dest` (stored or deflated). Throws if the result isn't the size the archive promises.
    func extract(_ e: ZipEntry, to dest: URL, progress: (Int64) -> Void, isCancelled: () -> Bool = { false }) throws {
        var localOffset = e.localOffset
        var header: [UInt8] = []
        var candidates: [UInt64] = [localOffset]
        for k in 1...Int(max(archiveSize >> 32, 1)) { candidates.append(localOffset &+ UInt64(k) << 32); if localOffset >= UInt64(k) << 32 { candidates.append(localOffset - UInt64(k) << 32) } }
        for c in candidates where c + 30 <= archiveSize {
            try handle.seek(toOffset: c)
            let h = [UInt8](try handle.read(upToCount: 30) ?? Data())
            if h.count == 30, Self.u32(h, 0) == 0x0403_4b50 { header = h; localOffset = c; break }
        }
        guard header.count == 30 else { throw ZipError(message: "Damaged zip entry: \(e.name)") }
        let dataStart = localOffset + 30 + UInt64(Self.u16(header, 26)) + UInt64(Self.u16(header, 28))

        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        if e.size == 0 { return }

        try handle.seek(toOffset: dataStart)
        var written: UInt64 = 0
        var remaining = e.compressedSize

        if e.method == 0 {
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                // one pool per chunk: the import runs inside a single dispatch block, so without it every chunk read stays allocated until the whole import ends
                try autoreleasepool {
                    guard let d = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !d.isEmpty else { throw ZipError(message: "Unexpected end of archive in \(e.name)") }
                    try out.write(contentsOf: d)
                    remaining -= UInt64(d.count); written += UInt64(d.count); progress(Int64(d.count))
                }
            }
        } else if e.method == 8 {
            let srcSize = 1 << 16, dstSize = 1 << 18
            let src = UnsafeMutablePointer<UInt8>.allocate(capacity: srcSize), dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { src.deallocate(); dst.deallocate() }
            var stream = compression_stream(dst_ptr: dst, dst_size: dstSize, src_ptr: UnsafePointer(src), src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError(message: "Couldn't start decompression.") }
            defer { compression_stream_destroy(&stream) }
            stream.dst_ptr = dst; stream.dst_size = dstSize                     // init clears the buffer fields, so they are set after it
            var status = COMPRESSION_STATUS_OK
            repeat {
                try autoreleasepool {
                    if isCancelled() { throw CancellationError() }
                    if stream.src_size == 0 && remaining > 0 {
                        guard let d = try handle.read(upToCount: Int(min(UInt64(srcSize), remaining))), !d.isEmpty else { throw ZipError(message: "Unexpected end of archive in \(e.name)") }
                        d.copyBytes(to: src, count: d.count)
                        stream.src_ptr = UnsafePointer(src); stream.src_size = d.count; remaining -= UInt64(d.count)
                    }
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    status = compression_stream_process(&stream, flags)
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { throw ZipError(message: "Damaged compressed data in \(e.name)") }
                    let produced = dstSize - stream.dst_size
                    if produced > 0 {
                        try out.write(contentsOf: Data(bytes: dst, count: produced))
                        written += UInt64(produced); progress(Int64(produced))
                        stream.dst_ptr = dst; stream.dst_size = dstSize
                    }
                }
            } while status == COMPRESSION_STATUS_OK
        } else {
            throw ZipError(message: "Unsupported compression method \(e.method) in \(e.name)")
        }
        guard written == e.size else { throw ZipError(message: "\(e.name) came out the wrong size (\(written) of \(e.size) bytes).") }
    }
}

// MARK: - Importer

final class GameImporter: ObservableObject {
    enum State: Equatable { case idle, scanning, copying, done(String), failed(String) }
    @Published var state: State = .idle
    @Published var progress = 0.0
    @Published var detail = ""
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)      // set on the main thread, read by the import thread
    private var cancelled: Bool { get { cancelFlag.withLock { $0 } } set { cancelFlag.withLock { $0 = newValue } } }
    private var nativeSources: [String: () throws -> URL] = [:]          // the game's own native libraries (not imported), for NativeCheck

    var busy: Bool { state == .scanning || state == .copying }
    func cancel() { cancelled = true; detail = "Cancelling..." }

    func start(from picked: URL) {
        guard !busy else { return }
        cancelled = false
        state = .scanning; progress = 0; detail = "Looking for the game files..."
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            do { try run(picked) }
            catch is CancellationError { finish(.failed("Import cancelled. Starting it again continues where it stopped.")) }
            catch { finish(.failed(error.localizedDescription)) }
        }
    }

    /// One file to put in place. `write` produces it at the given path (copy or extract); `modified` is known for folder sources only.
    struct Job { let relative: String; let size: Int64; let modified: Date?; let write: (URL, @escaping (Int64) -> Void, @escaping () -> Bool) throws -> Void }

    private func finish(_ s: State) { DispatchQueue.main.async { self.state = s } }
    private func update(_ p: Double, _ text: String) { DispatchQueue.main.async { self.progress = p; self.detail = text } }

    private func run(_ picked: URL) throws {
        let isZip = picked.pathExtension.lowercased() == "zip" && !((try? picked.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        let (jarJob, jobs) = isZip ? try planZip(picked) : try planFolder(picked)
        try execute(jarJob: jarJob, jobs: jobs)
    }

    /// Copies in 1 MB pieces so a cancel takes effect within a moment, even in the middle of a very large file.
    static func copyFile(_ src: URL, to dest: URL, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        fm.createFile(atPath: dest.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src), output = try FileHandle(forWritingTo: dest)
        defer { try? input.close(); try? output.close() }
        var finished = false
        while !finished {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { finished = true; return }
                try output.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
        }
    }

    // MARK: planning

    func planZip(_ url: URL) throws -> (Job, [Job]) {
        update(0, "Reading the zip...")
        let zip = try ZipArchive(url: url)
        let files = zip.entries.filter { !$0.isDirectory && !$0.name.lowercased().contains("__macosx") }

        // projectzomboid.jar, shallowest first; then the folder at or above it that has a media/ folder
        let jars = files.filter { $0.name.lowercased() == "projectzomboid.jar" || $0.name.lowercased().hasSuffix("/projectzomboid.jar") }
            .sorted { $0.name.split(separator: "/").count < $1.name.split(separator: "/").count }
        guard !jars.isEmpty else {
            throw NSError(domain: "GameImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't find projectzomboid.jar inside that zip. Compress the Project Zomboid app or folder on your Mac and choose that zip."])
        }
        var chosen: (ZipEntry, String)? = nil
        for jar in jars {
            var parts = jar.name.split(separator: "/").map(String.init); parts.removeLast()
            for _ in 0..<3 {
                let prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
                if files.contains(where: { $0.name.hasPrefix(prefix + "media/") }) { chosen = (jar, prefix); break }
                if parts.isEmpty { break }
                parts.removeLast()
            }
            if chosen != nil { break }
        }
        guard let (jarEntry, prefix) = chosen else {
            throw NSError(domain: "GameImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "The zip has projectzomboid.jar but no media folder next to it, so the game data is missing."])
        }
        update(0, "Found " + jarEntry.name)
        nativeSources = [:]
        if let m = NativeCheck.manifest {
            let dir = (jarEntry.name as NSString).deletingLastPathComponent
            for name in m.java.keys {
                guard let e = files.first(where: { $0.name == (dir.isEmpty ? name : dir + "/" + name) }) else { continue }
                nativeSources[name] = {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pznative-" + name)
                    try zip.extract(e, to: dest, progress: { _ in }); return dest
                }
            }
        }

        // candidates under the data prefix, whitelisted
        var candidates: [(ZipEntry, String)] = []
        for e in files where e.name.hasPrefix(prefix) {
            let rel = String(e.name.dropFirst(prefix.count))
            guard let first = rel.split(separator: "/").first, GameFiles.dataItems.contains(String(first)) else { continue }
            candidates.append((e, rel))
        }
        var jobs: [Job] = []
        for (e, rel) in candidates.sorted(by: { $0.0.localOffset < $1.0.localOffset }) {      // archive order = sequential reads
            if GameFiles.skip(rel) { continue }
            jobs.append(Job(relative: rel, size: Int64(e.size), modified: nil, write: { dest, progress, isCancelled in try zip.extract(e, to: dest, progress: progress, isCancelled: isCancelled) }))
        }
        let jarJob = Job(relative: "projectzomboid.jar", size: Int64(jarEntry.size), modified: nil, write: { dest, progress, isCancelled in try zip.extract(jarEntry, to: dest, progress: progress, isCancelled: isCancelled) })
        return (jarJob, jobs)
    }

    /// The folder holding projectzomboid.jar, found by searching level by level (any layout: a Mac app bundle, a Steam folder, a plain copy), then
    /// the data folder: the nearest folder at or above the jar that contains "media". Big folders that can't hold either are skipped.
    func locate(_ top: URL) throws -> (jar: URL, data: URL)? {
        let fm = FileManager.default
        let skip: Set<String> = ["media", "saves", "mods", "workshop", "plugins", "jre", "jre-aarch64", "jre-x86_64", "lib", "natives", ".git", "backups"]
        var queue: [(url: URL, depth: Int)] = [(top, 0)]
        var searched = 0, index = 0
        while index < queue.count {
            let (dir, depth) = queue[index]; index += 1
            if cancelled { throw CancellationError() }
            searched += 1
            if searched % 20 == 0 { update(0, "Searching for projectzomboid.jar... (\(searched) folders)") }
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            if let jar = kids.first(where: { $0.lastPathComponent.lowercased() == "projectzomboid.jar" }) {
                var folder = dir
                for _ in 0..<3 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: folder.appendingPathComponent("media").path, isDirectory: &isDir), isDir.boolValue { return (jar, folder) }
                    let parent = folder.deletingLastPathComponent()
                    if parent.path == folder.path || folder.path == top.path { break }
                    folder = parent
                }
            }
            if depth >= 6 { continue }
            for kid in kids {
                let isDir = (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir && !skip.contains(kid.lastPathComponent.lowercased()) { queue.append((kid, depth + 1)) }
            }
        }
        return nil
    }

    private func planFolder(_ picked: URL) throws -> (Job, [Job]) {
        let fm = FileManager.default
        guard let found = try locate(picked) else {
            throw NSError(domain: "GameImporter", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Couldn't find projectzomboid.jar, with a media folder beside it, anywhere inside that folder. Choose the Project Zomboid folder itself (or a folder that contains it), or a zip of it."])
        }
        let root = found.data
        update(0, "Found " + found.jar.pathComponents.dropFirst(picked.pathComponents.count).joined(separator: "/"))
        nativeSources = [:]
        if let m = NativeCheck.manifest {
            let dir = found.jar.deletingLastPathComponent()
            for name in m.java.keys where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { nativeSources[name] = { dir.appendingPathComponent(name) } }
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var all: [(URL, String, Int64, Date)] = []
        for name in GameFiles.dataItems {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            func record(_ file: URL, _ rel: String) {
                let v = try? file.resourceValues(forKeys: Set(keys))
                all.append((file, rel, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
            }
            if isDir.boolValue {
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
                for case let file as URL in walker {
                    if cancelled { throw CancellationError() }
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                    record(file, name + "/" + file.pathComponents.dropFirst(url.pathComponents.count).joined(separator: "/"))
                }
            } else { record(url, name) }
            update(0, "Found \(all.count) files...")
        }
        var jobs: [Job] = []
        for (src, rel, size, mod) in all where !GameFiles.skip(rel) {
            jobs.append(Job(relative: rel, size: size, modified: mod, write: { dest, progress, isCancelled in
                try Self.copyFile(src, to: dest, progress: progress, isCancelled: isCancelled)
            }))
        }
        let jarSize = Int64((try? found.jar.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let jarJob = Job(relative: "projectzomboid.jar", size: jarSize, modified: nil, write: { dest, progress, isCancelled in try Self.copyFile(found.jar, to: dest, progress: progress, isCancelled: isCancelled) })
        return (jarJob, jobs)
    }

    // MARK: running

    private func execute(jarJob: Job, jobs: [Job]) throws {
        let fm = FileManager.default
        let total = jobs.reduce(Int64(0)) { $0 + $1.size } + jarJob.size

        // enough room? (existing identical files are skipped, so this is a worst case)
        if let free = (try? GameFiles.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, free < total + 200_000_000 {
            let f = ByteCountFormatter.string(fromByteCount: total + 200_000_000, countStyle: .file), a = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            throw NSError(domain: "GameImporter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Not enough free space: about \(f) is needed and \(a) is available. Free some space and start again; files already copied are kept."])
        }
        DispatchQueue.main.async { self.state = .copying }

        var done: Int64 = 0
        var lastUpdate = Date.distantPast
        func tick(_ name: String) {
            if Date().timeIntervalSince(lastUpdate) > 0.2 {
                lastUpdate = Date()
                update(total > 0 ? Double(done) / Double(total) : 0, "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))  ·  \(name)")
            }
        }
        func unchanged(_ dest: URL, _ job: Job) -> Bool {
            guard let a = try? fm.attributesOfItem(atPath: dest.path) else { return false }
            guard ((a[.size] as? NSNumber)?.int64Value ?? -1) == job.size else { return false }
            if let m = job.modified { return abs(((a[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince(m)) < 2 }
            return true
        }
        /// Writes to "<name>.part" and moves it into place, so an interrupted import never leaves a half-written file that looks finished.
        func place(_ job: Job, at dest: URL) throws {
            let part = dest.appendingPathExtension("part")
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: part)
            let before = done
            do {
                try job.write(part, { n in done += n; tick(job.relative) }, { self.cancelled })
            } catch {
                try? fm.removeItem(at: part)
                if cancelled { throw CancellationError() }
                done = before
                throw NSError(domain: "GameImporter", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't import \(job.relative): \(error.localizedDescription) If the source is in iCloud Drive, make sure it is fully downloaded first."])
            }
            if cancelled { try? fm.removeItem(at: part); throw CancellationError() }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            if let m = job.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest.path) }
        }

        try fm.createDirectory(at: GameFiles.gameDir, withIntermediateDirectories: true)
        for job in jobs {
            if cancelled { throw CancellationError() }
            let dest = GameFiles.gameDir.appendingPathComponent(job.relative)
            if unchanged(dest, job) { done += job.size; tick(job.relative); continue }
            try place(job, at: dest)
        }
        if cancelled { throw CancellationError() }
        update(Double(done) / Double(max(total, 1)), "projectzomboid.jar")
        if !(fm.fileExists(atPath: GameFiles.jar.path) && unchanged(GameFiles.jar, jarJob)) { try place(jarJob, at: GameFiles.jar) }

        update(1, "Checking the game's native libraries...")
        NativeCheck.store(NativeCheck.check(java: nativeSources, jar: GameFiles.jar))
        for name in nativeSources.keys { try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("pznative-" + name)) }
        nativeSources = [:]
        GameFiles.excludeFromBackup()
        finish(.done("\(jobs.count + 1) files imported (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))."))
    }
}
