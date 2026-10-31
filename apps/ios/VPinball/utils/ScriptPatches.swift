import CryptoKit
import Foundation

/// Fixed table scripts from the community's vpx-standalone-scripts repository.
///
/// Some tables' scripts need small changes to run on the VBScript engine used outside Windows.
/// The repository keeps, for each such table, its original script and a fixed one, and an index
/// (hashes.json) of their SHA-256 hashes. A table whose script matches an original gets the fixed
/// script next to it as a sidecar `.vbs`, which VPX uses in place of the table's own script.
///
/// Hashes are taken with Windows line endings, as the repository checks its scripts out
/// (.gitattributes: *.vbs eol=crlf), while raw downloads come with the line endings stored in git,
/// so both sides are normalized to CRLF before hashing.
enum ScriptPatches {
    struct Entry: Decodable {
        struct Patched: Decodable {
            let file: String
            let sha256: String
            let url: String
        }

        let file: String
        let sha256: String
        let url: String
        let patched: Patched
    }

    enum Result {
        case applied(String)
        case alreadyPatched
        case notNeeded
        case unavailable
    }

    /// What was done, and the script the table will run (the fixed one when one was applied).
    struct Outcome {
        let result: Result
        let script: Data?
    }

    static let indexURL = URL(string: "https://raw.githubusercontent.com/jsm174/vpx-standalone-scripts/refs/heads/master/hashes.json")!

    private static let indexMaxAge: TimeInterval = 24 * 60 * 60

    private static var cachedIndexURL: URL {
        URL(fileURLWithPath: VPinballManager.shared.getPath(.preferences))
            .appendingPathComponent("vpx-standalone-scripts.json")
    }

    /// Checks a table's script against the index and, when a fix exists, writes it next to the
    /// table. A sidecar script already next to the table is checked rather than the table's own,
    /// and is kept unless it is itself a known original.
    static func apply(tableURL: URL) async -> Outcome {
        guard tableURL.pathExtension.lowercased() == "vpx" else {
            return Outcome(result: .notNeeded, script: nil)
        }

        let scriptURL = tableURL.deletingPathExtension().appendingPathExtension("vbs")
        let hadSidecar = TableFileOperations.exists(scriptURL)

        let script: Data? = await Task.detached(priority: .userInitiated) {
            if !hadSidecar {
                if VPinballStatus(rawValue: VPinballExtractTableScript(tableURL.path.cstring)) != .success {
                    return nil
                }
            }
            let data = try? Data(contentsOf: scriptURL)
            if !hadSidecar {
                // only the fixed script, if any, stays next to the table
                _ = TableFileOperations.delete(scriptURL)
            }
            return data
        }.value

        guard let script else {
            VPinballManager.log(.warn, "Unable to read the script of \(tableURL.lastPathComponent) to check for a fix")
            return Outcome(result: .unavailable, script: nil)
        }

        guard let index = await loadIndex() else {
            return Outcome(result: .unavailable, script: script)
        }

        let hash = sha256(crlf(script))

        if index.contains(where: { $0.patched.sha256 == hash }) {
            return Outcome(result: .alreadyPatched, script: script)
        }

        guard let entry = index.first(where: { $0.sha256 == hash }),
              let patchURL = URL(string: entry.patched.url)
        else {
            return Outcome(result: .notNeeded, script: script)
        }

        guard let download = try? await URLSession.shared.data(from: patchURL),
              (download.1 as? HTTPURLResponse)?.statusCode == 200
        else {
            VPinballManager.log(.warn, "Unable to download the fixed script \(entry.patched.file)")
            return Outcome(result: .unavailable, script: script)
        }

        let fixed = crlf(download.0)
        if sha256(fixed) != entry.patched.sha256 {
            VPinballManager.log(.warn, "The fixed script \(entry.patched.file) doesn't match its hash; not used")
            return Outcome(result: .unavailable, script: script)
        }

        do {
            try fixed.write(to: scriptURL, options: .atomic)
        } catch {
            VPinballManager.log(.error, "Unable to save the fixed script \(scriptURL.path): \(error)")
            return Outcome(result: .unavailable, script: script)
        }

        VPinballManager.log(.info, "Applied the fixed script \(entry.patched.file) to \(tableURL.lastPathComponent)")
        return Outcome(result: .applied(entry.patched.file), script: fixed)
    }

    /// The index, downloaded at most once a day; the last one saved when offline.
    private static func loadIndex() async -> [Entry]? {
        let cacheURL = cachedIndexURL
        let decoder = JSONDecoder()

        let modified = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let modified, Date().timeIntervalSince(modified) < indexMaxAge,
           let data = try? Data(contentsOf: cacheURL),
           let index = try? decoder.decode([Entry].self, from: data)
        {
            return index
        }

        if let download = try? await URLSession.shared.data(from: indexURL),
           (download.1 as? HTTPURLResponse)?.statusCode == 200,
           let index = try? decoder.decode([Entry].self, from: download.0)
        {
            try? download.0.write(to: cacheURL, options: .atomic)
            return index
        }

        VPinballManager.log(.warn, "Unable to download the fixed scripts index; using the saved one if any")
        if let data = try? Data(contentsOf: cacheURL) {
            return try? decoder.decode([Entry].self, from: data)
        }
        return nil
    }

    /// `data` with every line ending as CRLF.
    static func crlf(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + data.count / 32)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A && previous != 0x0D {
                out.append(0x0D)
            }
            out.append(byte)
            previous = byte
        }
        return out
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
