import Foundation

/// Which PinMAME ROM a table needs, and whether it's installed.
///
/// The ROM's name comes from the table's script (`cGameName = "afm_113b"`), read when the table
/// is imported and kept in table-roms.json in the preferences folder, by the table's path in the
/// tables folder. PinMAME looks for ROMs in a `pinmame/roms` folder next to the table and, when the
/// table has none, in the shared `pinmame/roms` folder in the preferences folder (PinMAMEPlugin.cpp).
enum RomCheck {
    private static var namesURL: URL {
        URL(fileURLWithPath: VPinballManager.shared.getPath(.preferences))
            .appendingPathComponent("table-roms.json")
    }

    /// The shared ROMs folder, used by every table without a `pinmame/roms` folder of its own.
    static var sharedRomsURL: URL {
        URL(fileURLWithPath: VPinballManager.shared.getPath(.preferences))
            .appendingPathComponent("pinmame")
            .appendingPathComponent("roms")
    }

    /// The ROM names a script may run, in the order they appear. Scripts usually set `cGameName`
    /// once; some pick between versions, and any of those will do.
    static func romNames(inScript data: Data) -> [String] {
        guard let script = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        let patterns = [
            #"(?im)^\s*(?:const\s+|dim\s+|private\s+|public\s+)?cGameName\s*=\s*"([^"]+)""#,
            #"(?i)\.GameName\s*=\s*"([^"]+)""#,
        ]

        var names: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(script.startIndex..., in: script)
            for match in regex.matches(in: script, range: range) {
                if let r = Range(match.range(at: 1), in: script) {
                    let name = String(script[r]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        names.append(name)
                    }
                }
            }
            if !names.isEmpty {
                break
            }
        }
        return names
    }

    static func remember(tablePath: String, romNames: [String]) {
        var all = load()
        if romNames.isEmpty {
            all.removeValue(forKey: tablePath)
        } else {
            all[tablePath] = romNames
        }
        save(all)
    }

    static func forget(tablePath: String) {
        var all = load()
        if all.removeValue(forKey: tablePath) != nil {
            save(all)
        }
    }

    /// The ROM names a table needs when none of them is installed; empty when one is, or when the
    /// table needs none or its ROM isn't known. Tables imported before ROM names were kept are
    /// read from their sidecar script, if they have one.
    static func missingRoms(for table: Table) -> [String] {
        var names = load()[table.path] ?? []
        if names.isEmpty, let data = try? Data(contentsOf: table.scriptURL) {
            names = romNames(inScript: data)
        }
        if names.isEmpty {
            return []
        }

        let roms = romsFolder(forTableDirectory: table.baseURL)
        let installed = Set(((try? FileManager.default.contentsOfDirectory(atPath: roms.path)) ?? []).map { $0.lowercased() })
        if names.contains(where: { installed.contains($0.lowercased() + ".zip") }) {
            return []
        }
        return names
    }

    /// Where PinMAME will look for a table's ROMs: its own `pinmame/roms` folder (in any letter
    /// case) if it has one, else the shared one.
    static func romsFolder(forTableDirectory dir: URL) -> URL {
        if let pinmame = childDirectory(dir, named: "pinmame"),
           let roms = childDirectory(pinmame, named: "roms")
        {
            return roms
        }
        return sharedRomsURL
    }

    /// A file name a browser gave a second download ("afm_113b (1).zip"), back to the name PinMAME
    /// looks for ("afm_113b.zip").
    static func cleanRomFileName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*-\s*Copy$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return stem + "." + url.pathExtension.lowercased()
    }

    private static func childDirectory(_ dir: URL, named name: String) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.first {
            $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: namesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private static func save(_ all: [String: [String]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(all) {
            try? data.write(to: namesURL, options: .atomic)
        }
    }
}
