import Foundation
import Darwin

// ATTR_CMNEXT_PRIVATESIZE accessed via the forkattr field with
// FSOPT_ATTR_CMN_EXTENDED. Same approach as the apfs-cow.sh C helper.
private let kPrivateSizeAttr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
private let kExtendedFlags = UInt32(FSOPT_ATTR_CMN_EXTENDED)

struct ChangedFile {
    let relativePath: String  // relative to dropDir, e.g. "MyFolder/notes.md"
    let dropURL: URL
    let privateBytes: Int64   // unshared bytes owned by this inode
    let totalBytes: Int64     // logical file size
}

enum DropsScanner {
    /// Walk dropDir and return every regular file whose private (unshared) byte
    /// count is > 0, meaning the agent wrote to it after the COW clone was made.
    static func scan(dropDir: URL) -> [ChangedFile] {
        guard FileManager.default.fileExists(atPath: dropDir.path(percentEncoded: false)) else { return [] }
        var results: [ChangedFile] = []
        let fm = FileManager.default
        // Relative URLs: the enumerator hands back the real path (/tmp →
        // /private/tmp, a symlinked folder), so trimming dropDir's spelling
        // off the front would cut the wrong number of characters.
        guard let enumerator = fm.enumerator(
            at: dropDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .producesRelativePathURLs]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let priv = privateBytes(at: fileURL.path(percentEncoded: false))
            guard priv > 0 else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            results.append(ChangedFile(relativePath: fileURL.relativePath, dropURL: fileURL.absoluteURL,
                                       privateBytes: priv, totalBytes: Int64(size ?? 0)))
        }
        return results
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

    // ATTR_CMNEXT_PRIVATESIZE via getattrlist. The result buffer is a packed
    // { uint32 length; off_t value } = 12 bytes; value sits at byte offset 4.
    private static func privateBytes(at path: String) -> Int64 {
        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.forkattr = kPrivateSizeAttr
        var buf = [UInt8](repeating: 0, count: 12)
        let ret = buf.withUnsafeMutableBytes { ptr in
            path.withCString { cpath in
                getattrlist(cpath, &al, ptr.baseAddress, ptr.count, kExtendedFlags)
            }
        }
        guard ret == 0 else { return -1 }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}
