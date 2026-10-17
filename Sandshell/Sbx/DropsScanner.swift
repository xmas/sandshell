import Foundation
import Darwin

// ATTR_CMNEXT_PRIVATESIZE and ATTR_CMNEXT_EXT_FLAGS, read through the forkattr
// field with FSOPT_ATTR_CMN_EXTENDED. Same approach as the apfs-cow.sh C helper.
private let kBlockAttrs = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
private let kExtendedFlags = UInt32(FSOPT_ATTR_CMN_EXTENDED)

struct ChangedFile {
    let relativePath: String  // relative to dropDir, e.g. "MyFolder/notes.md"
    let dropURL: URL
    let privateBytes: Int64   // unshared bytes owned by this inode
    let totalBytes: Int64     // logical file size
}

enum DropsScanner {
    /// How a dropped file's blocks stand on APFS.
    struct Blocks: Equatable {
        /// Bytes this inode owns rather than shares with a clone.
        var privateBytes: Int64
        /// EF_MAY_SHARE_BLOCKS: made by cloning, so it shares (or once shared)
        /// blocks with the original. A full copy never has it.
        var mayShare: Bool
    }

    /// Walk dropDir and return every regular file the agent has changed since
    /// it was dropped (see `isChanged`).
    static func scan(dropDir: URL) -> [ChangedFile] {
        guard FileManager.default.fileExists(atPath: dropDir.path(percentEncoded: false)) else { return [] }
        var results: [ChangedFile] = []
        let fm = FileManager.default
        let dropTimes = dropTimes(in: dropDir)
        // Relative URLs: the enumerator hands back the real path (/tmp →
        // /private/tmp, a symlinked folder), so trimming dropDir's spelling
        // off the front would cut the wrong number of characters.
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: dropDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .producesRelativePathURLs]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let blocks = blocks(at: fileURL.path(percentEncoded: false))
            else { continue }
            let relativePath = fileURL.relativePath
            // `.provenance` is keyed by the name of what was dropped: the file
            // itself, or the folder it's in.
            let dropped = relativePath.split(separator: "/", maxSplits: 1).first.flatMap { dropTimes[String($0)] }
            guard isChanged(blocks, modified: values.contentModificationDate, droppedAt: dropped) else { continue }
            results.append(ChangedFile(relativePath: relativePath, dropURL: fileURL.absoluteURL,
                                       privateBytes: blocks.privateBytes, totalBytes: Int64(values.fileSize ?? 0)))
        }
        return results
    }

    /// Whether a file in the drops folder has changed since it was dropped.
    ///
    /// A drop is usually an APFS clone, sharing every block with the original
    /// until something writes to it, so it has changed once it owns any.
    /// FileManager falls back to a full copy where it can't clone (a drop from
    /// an external disk, a network share, another APFS volume or container),
    /// and a full copy owns all its blocks from the start, so it's judged by
    /// date instead: the copy keeps the original's modification date, so it's
    /// unchanged while it's no newer than its drop (allowing for `droppedAt`
    /// being written in whole seconds). With no recorded drop, a file of its
    /// own (one the agent made) has changed.
    static func isChanged(_ blocks: Blocks, modified: Date?, droppedAt: Date?) -> Bool {
        guard blocks.privateBytes > 0 else { return false }
        if blocks.mayShare { return true }
        guard let modified, let droppedAt else { return true }
        return modified >= droppedAt.addingTimeInterval(1)
    }

    /// When each top-level item in dropDir was dropped, by name, from the
    /// `.provenance` file the drop handler keeps there
    /// (`TerminalStackController.recordProvenance`):
    /// `{"<name>": {"source": "<path>", "droppedAt": "<ISO 8601>"}, …}`.
    static func dropTimes(in dropDir: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: dropDir.appending(path: ".provenance", directoryHint: .notDirectory)),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return entries.compactMapValues { entry in
            ((entry as? [String: Any])?["droppedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        }
    }

    /// Copy each changed file into stagingDir, preserving its relative path
    /// within dropDir so the folder hierarchy is intact.
    static func export(_ changed: [ChangedFile], from dropDir: URL, to stagingDir: URL) throws {
        let fm = FileManager.default
        for file in changed {
            let dest = stagingDir.appending(path: file.relativePath)
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file.dropURL, to: dest)
        }
    }

    // ATTR_CMNEXT_PRIVATESIZE and ATTR_CMNEXT_EXT_FLAGS via getattrlist. The
    // result buffer is packed in attribute-bit order:
    // { uint32 length; off_t privateSize; uint64 extFlags } = 20 bytes.
    private static func blocks(at path: String) -> Blocks? {
        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.forkattr = kBlockAttrs
        var buf = [UInt8](repeating: 0, count: 20)
        let ret = buf.withUnsafeMutableBytes { ptr in
            path.withCString { cpath in
                getattrlist(cpath, &al, ptr.baseAddress, ptr.count, kExtendedFlags)
            }
        }
        guard ret == 0 else { return nil }
        return buf.withUnsafeBytes {
            Blocks(privateBytes: $0.loadUnaligned(fromByteOffset: 4, as: Int64.self),
                   mayShare: $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) & UInt64(EF_MAY_SHARE_BLOCKS) != 0)
        }
    }
}
