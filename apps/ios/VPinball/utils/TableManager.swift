import SwiftUI
import UniformTypeIdentifiers

let tableImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 96 * 1024 * 1024
    return cache
}()

private var zipProgressHandler: ((Int, Int) -> Void)?

private let zipCallback: VPinballZipCallback = { current, total, _ in
    zipProgressHandler?(Int(current), Int(total))
}

@MainActor
class TableManager {
    static let shared = TableManager()

    var tables: [Table] {
        get { VPinballModel.shared.tables }
        set { VPinballModel.shared.tables = newValue }
    }

    private var tablesURL: URL!
    private var tablesJSONURL: URL!
    private var loadedTable: Table?

    init() {
        loadTablesPath()
        Task {
            await loadTables()
        }
    }

    func refresh() async {
        await loadTables()
    }

    func importTable(from url: URL) async -> Bool {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent

        VPinballModel.shared.showHUD(
            title: fileName,
            status: "Copying"
        )

        try? await Task.sleep(nanoseconds: 100_000_000)

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpinball_staging_\(Int(Date().timeIntervalSince1970))")

        defer {
            _ = TableFileOperations.deleteDirectory(stagingDir)
        }

        if !TableFileOperations.createDirectory(stagingDir) {
            VPinballModel.shared.hideHUD()
            return false
        }

        let stagedURL = stagingDir.appendingPathComponent(url.lastPathComponent)

        let isSecurityScoped = url.startAccessingSecurityScopedResource()

        VPinballModel.shared.updateHUD(
            progress: 10,
            status: "Copying"
        )

        let copied = await coordinatedCopy(from: url,
                                           to: stagedURL)

        if isSecurityScoped {
            url.stopAccessingSecurityScopedResource()
        }

        if !copied {
            VPinballModel.shared.hideHUD()
            return false
        }

        let isArchive = ext == "vpxz" || ext == "zip"
        VPinballModel.shared.updateHUD(
            progress: 60,
            status: isArchive ? "Importing archive" : "Importing table"
        )

        try? await Task.sleep(nanoseconds: 100_000_000)

        let imported = await performImport(url: stagedURL) { progress in
            await MainActor.run {
                VPinballModel.shared.updateHUD(
                    progress: progress,
                    status: progress >= 97 ? "Checking script" : (isArchive ? "Importing archive" : "Importing")
                )
            }
        }

        VPinballModel.shared.updateHUD(
            progress: 100,
            status: "Import complete"
        )

        try? await Task.sleep(nanoseconds: 500_000_000)

        VPinballModel.shared.hideHUD()

        guard let imported else {
            return false
        }

        if let table = imported.tables.first ?? imported.extrasAttachedTo {
            MainViewModel.shared.scrollToTable = table
        }

        if let pending = imported.pendingExtras {
            MainViewModel.shared.handleChooseTableForExtras(folder: pending)
        } else {
            MainViewModel.shared.handleShowImportSummary(imported)
        }

        return !imported.isEmpty
    }

    func deleteTable(table: Table) async -> Bool {
        let tablesURL = tablesURL!
        let tableFileURL = tablesURL.appendingPathComponent(table.path)
        let tableDirURL = tableFileURL.deletingLastPathComponent()
        let result = await Task.detached(priority: .userInitiated) {
            let tableDir = tableDirURL

            if tableDir.path.isEmpty || tableDir.path == tablesURL.path || tableDir.path + "/" == tablesURL.path {
                return false
            }

            if TableFileOperations.exists(tableDir) {
                let tableURLs = TableFileOperations.listTableURLs(tableDir)

                if tableURLs.count <= 1 {
                    if !TableFileOperations.deleteDirectory(tableDir) {
                        return false
                    }
                } else {
                    if !TableFileOperations.delete(tableFileURL) {
                        return false
                    }
                }
            }

            return true
        }.value

        if result {
            tables.removeAll { $0.uuid == table.uuid }
            saveTables()
            RomCheck.forget(tablePath: table.path)
        }

        return result
    }

    func renameTable(table: Table, newName: String) async -> Bool {
        return performRename(table: table,
                             newName: newName)
    }

    func setTableImage(table: Table, imagePath: String) async -> Bool {
        let tablesURL = tablesURL!
        let tableFileURL = tablesURL.appendingPathComponent(table.path)
        let workingDir = tableFileURL.deletingLastPathComponent()
        let tableImageURL = tablesURL.appendingPathComponent(table.image)

        let (success, resolvedImage) = await Task.detached(priority: .userInitiated) {
            func relativePath(of url: URL, baseURL: URL) -> String {
                let fullPath = url.resolvingSymlinksInPath().path
                let basePath = baseURL.path

                if fullPath.isEmpty || basePath.isEmpty {
                    return fullPath
                }

                if !fullPath.hasPrefix(basePath) {
                    return fullPath
                }

                var result = String(fullPath.dropFirst(basePath.count))
                if result.hasPrefix("/") {
                    result = String(result.dropFirst())
                }

                return result
            }

            if imagePath.isEmpty {
                if !table.image.isEmpty && TableFileOperations.exists(tableImageURL) {
                    _ = TableFileOperations.delete(tableImageURL)
                }
                return (true, "")
            }

            if imagePath.hasPrefix("/") {
                let sourceURL = URL(fileURLWithPath: imagePath)
                if let sourceImage = UIImage(contentsOfFile: imagePath),
                   let jpegData = sourceImage.jpegData(compressionQuality: 0.8)
                {
                    let destURL = workingDir.appendingPathComponent(table.stem + ".jpg")
                    do {
                        try jpegData.write(to: destURL)
                    } catch {
                        return (false, "")
                    }

                    let existingPath = workingDir.appendingPathComponent(tableFileURL.deletingPathExtension().lastPathComponent + ".jpg").path
                    if imagePath != existingPath
                        && sourceURL.pathExtension.lowercased() == "png"
                    {
                        _ = TableFileOperations.delete(sourceURL)
                    }

                    let rel = relativePath(of: destURL, baseURL: tablesURL)
                    return (true, rel)
                }
                return (false, "")
            }

            return (true, imagePath)
        }.value

        if success, let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
            let now = Int64(Date().timeIntervalSince1970)
            tables[index] = tables[index].with(image: resolvedImage, modifiedAt: now)
            saveTables()
            return true
        }

        return false
    }

    func setTableImage(table: Table, image: UIImage) async -> Bool {
        let tablesURL = tablesURL!
        let tableFileURL = tablesURL.appendingPathComponent(table.path)
        let workingDir = tableFileURL.deletingLastPathComponent()

        if let jpegData = image.jpegData(compressionQuality: 0.8) {
            let (success, resolvedImage) = await Task.detached(priority: .userInitiated) {
                func relativePath(of url: URL, baseURL: URL) -> String {
                    let fullPath = url.resolvingSymlinksInPath().path
                    let basePath = baseURL.path

                    if fullPath.isEmpty || basePath.isEmpty {
                        return fullPath
                    }

                    if !fullPath.hasPrefix(basePath) {
                        return fullPath
                    }

                    var result = String(fullPath.dropFirst(basePath.count))
                    if result.hasPrefix("/") {
                        result = String(result.dropFirst())
                    }

                    return result
                }

                let destURL = workingDir.appendingPathComponent(tableFileURL.deletingPathExtension().lastPathComponent + ".jpg")
                do {
                    try jpegData.write(to: destURL)
                } catch {
                    return (false, "")
                }

                let rel = relativePath(of: destURL, baseURL: tablesURL)
                return (true, rel)
            }.value

            if success, let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
                let now = Int64(Date().timeIntervalSince1970)
                tables[index] = tables[index].with(image: resolvedImage, modifiedAt: now)
                saveTables()
                return true
            }
        }

        return false
    }

    func exportTable(table: Table) async -> String? {
        VPinballModel.shared.showHUD(title: table.name,
                                     status: "Compressing")

        try? await Task.sleep(nanoseconds: 100_000_000)

        let exportPath = await performExport(table: table) { progress, status in
            await MainActor.run {
                VPinballModel.shared.updateHUD(progress: progress,
                                               status: status)
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        VPinballModel.shared.hideHUD()

        return exportPath
    }

    func getLoadedTablePath(table: Table) -> String? {
        if table.path.isEmpty {
            return nil
        }

        loadedTable = table
        return table.fullPath
    }

    func clearLoadedTable(table: Table) {
        if loadedTable?.uuid != table.uuid {
            return
        }

        loadedTable = nil
    }

    func extractTableScript(table: Table) async -> Bool {
        VPinballModel.shared.showHUD(title: table.name,
                                     status: "Extracting Script")

        try? await Task.sleep(nanoseconds: 100_000_000)

        let tablesURL = tablesURL!
        let tableFileURL = tablesURL.appendingPathComponent(table.path)
        let tablePath = tableFileURL.path
        let scriptPath = tableFileURL.deletingPathExtension().appendingPathExtension("vbs").path
        let result = await Task.detached(priority: .userInitiated) {
            if TableFileOperations.exists(URL(fileURLWithPath: scriptPath)) {
                return true
            }

            if VPinballStatus(rawValue: VPinballExtractTableScript(tablePath.cstring)) != .success {
                VPinballManager.log(.error, "Failed to extract script from table: \(tablePath)")
                return false
            }

            if TableFileOperations.exists(URL(fileURLWithPath: scriptPath)) {
                VPinballManager.log(.info, "Successfully extracted script: \(scriptPath)")
                return true
            }

            VPinballManager.log(.warn, "Script file not found after extraction")
            return false
        }.value

        if result, let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
            let now = Int64(Date().timeIntervalSince1970)
            tables[index] = tables[index].with(modifiedAt: now)
            saveTables()
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        VPinballModel.shared.hideHUD()

        return result
    }

    func markPlayed(table: Table) {
        guard let index = tables.firstIndex(where: { $0.uuid == table.uuid }) else { return }
        tables[index] = tables[index].played(at: Int64(Date().timeIntervalSince1970))
        saveTables()
    }

    func clearPlayed(table: Table) {
        guard let index = tables.firstIndex(where: { $0.uuid == table.uuid }) else { return }
        tables[index] = tables[index].played(at: nil)
        saveTables()
    }

    func toggleFavorite(table: Table) {
        guard let index = tables.firstIndex(where: { $0.uuid == table.uuid }) else { return }
        tables[index] = tables[index].favorite(!tables[index].isFavorite)
        saveTables()
    }

    func resetTableIni(table: Table) -> Bool {
        let tablesURL = tablesURL!
        let tableFileURL = tablesURL.appendingPathComponent(table.path)
        let iniURL = tableFileURL.deletingPathExtension().appendingPathExtension("ini")
        let deleted = TableFileOperations.delete(iniURL)
        if deleted, let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
            let now = Int64(Date().timeIntervalSince1970)
            tables[index] = tables[index].with(modifiedAt: now)
            saveTables()
        }
        return deleted
    }

    private func loadTablesPath() {
        tablesURL = URL(fileURLWithPath: VPinballManager.shared.getPath(.tables))
        tablesJSONURL = URL(fileURLWithPath: VPinballManager.shared.getPath(.preferences))
            .appendingPathComponent("tables.json")

        if !TableFileOperations.exists(tablesURL) {
            _ = TableFileOperations.createDirectory(tablesURL)
        }
    }

    func loadTables() async {
        let tablesURL = tablesURL!
        let tablesJSONURL = tablesJSONURL!

        let loadedTables = await Task.detached(priority: .userInitiated) {
            func relativePath(of url: URL, baseURL: URL) -> String {
                let fullPath = url.resolvingSymlinksInPath().path
                let basePath = baseURL.path

                if fullPath.isEmpty || basePath.isEmpty {
                    return fullPath
                }

                if !fullPath.hasPrefix(basePath) {
                    return fullPath
                }

                var result = String(fullPath.dropFirst(basePath.count))
                if result.hasPrefix("/") {
                    result = String(result.dropFirst())
                }

                return result
            }

            func createTable(url: URL, existingUUIDs: inout Set<String>) -> Table {
                var uuid = UUID().uuidString.lowercased()
                while existingUUIDs.contains(uuid) {
                    uuid = UUID().uuidString.lowercased()
                    VPinballManager.log(.warn, "UUID collision detected: \(uuid), regenerating")
                }
                existingUUIDs.insert(uuid)

                let relPath = relativePath(of: url, baseURL: tablesURL)

                var name = url.deletingPathExtension().lastPathComponent
                name = name.replacingOccurrences(of: "_",
                                                 with: " ")

                let now = Int64(Date().timeIntervalSince1970)

                let parentURL = url.deletingLastPathComponent()
                let stem = url.deletingPathExtension().lastPathComponent
                let pngURL = parentURL.appendingPathComponent(stem + ".png")
                let jpgURL = parentURL.appendingPathComponent(stem + ".jpg")

                var image = ""
                if TableFileOperations.exists(pngURL) {
                    image = relativePath(of: pngURL, baseURL: tablesURL)
                } else if TableFileOperations.exists(jpgURL) {
                    image = relativePath(of: jpgURL, baseURL: tablesURL)
                }

                return Table(uuid: uuid,
                             name: name,
                             path: relPath,
                             image: image,
                             createdAt: now,
                             modifiedAt: now)
            }

            var loadedTables: [Table] = []

            if TableFileOperations.exists(tablesJSONURL) {
                if let content = TableFileOperations.read(tablesJSONURL),
                   let jsonData = content.data(using: .utf8)
                {
                    if let response = try? JSONDecoder().decode(TablesResponse.self,
                                                                from: jsonData)
                    {
                        loadedTables = response.tables
                    }
                }
            }

            func fileModifiedAt(_ url: URL) -> Int64? {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let date = attrs[.modificationDate] as? Date
                {
                    return Int64(date.timeIntervalSince1970)
                }
                return nil
            }

            var bumpedMods = 0
            for i in 0 ..< loadedTables.count {
                let table = loadedTables[i]
                let cleanPath = table.path.hasPrefix("/") ? relativePath(of: URL(fileURLWithPath: table.path), baseURL: tablesURL) : table.path
                let cleanImage = table.image.hasPrefix("/") ? relativePath(of: URL(fileURLWithPath: table.image), baseURL: tablesURL) : table.image

                var updated = table
                if cleanPath != table.path || cleanImage != table.image {
                    updated = updated.with(path: cleanPath, image: cleanImage)
                }

                var latestMod = updated.modifiedAt
                let tableFileURL = tablesURL.appendingPathComponent(updated.path)
                if let fileMod = fileModifiedAt(tableFileURL) {
                    latestMod = max(latestMod, fileMod)
                }
                if !updated.image.isEmpty {
                    let imageURL = tablesURL.appendingPathComponent(updated.image)
                    if let imageMod = fileModifiedAt(imageURL) {
                        latestMod = max(latestMod, imageMod)
                    }
                }
                if latestMod != updated.modifiedAt {
                    updated = updated.with(modifiedAt: latestMod)
                    bumpedMods += 1
                }

                loadedTables[i] = updated
            }

            var seen = Set<String>()
            loadedTables.removeAll { table in
                if table.uuid.isEmpty || seen.contains(table.uuid) {
                    return true
                }
                seen.insert(table.uuid)

                let tableFileURL = tablesURL.appendingPathComponent(table.path)
                if !TableFileOperations.exists(tableFileURL) {
                    VPinballManager.log(.info, "Removing table with missing file: \(tableFileURL.path)")
                    return true
                }

                return false
            }

            var autoImages = 0
            for i in 0 ..< loadedTables.count {
                if loadedTables[i].image.isEmpty {
                    let table = loadedTables[i]
                    let tableFileURL = tablesURL.appendingPathComponent(table.path)
                    let parentURL = tableFileURL.deletingLastPathComponent()
                    let stem = tableFileURL.deletingPathExtension().lastPathComponent
                    let pngURL = parentURL.appendingPathComponent(stem + ".png")
                    let jpgURL = parentURL.appendingPathComponent(stem + ".jpg")

                    if TableFileOperations.exists(pngURL) {
                        var updated = table.with(image: relativePath(of: pngURL, baseURL: tablesURL))
                        if let imageMod = fileModifiedAt(pngURL) {
                            updated = updated.with(modifiedAt: max(updated.modifiedAt, imageMod))
                        }
                        loadedTables[i] = updated
                        autoImages += 1
                    } else if TableFileOperations.exists(jpgURL) {
                        var updated = table.with(image: relativePath(of: jpgURL, baseURL: tablesURL))
                        if let imageMod = fileModifiedAt(jpgURL) {
                            updated = updated.with(modifiedAt: max(updated.modifiedAt, imageMod))
                        }
                        loadedTables[i] = updated
                        autoImages += 1
                    }
                }
            }

            var seenPaths = Set<String>()
            loadedTables.removeAll { table in
                if seenPaths.contains(table.path) {
                    return true
                }
                seenPaths.insert(table.path)
                return false
            }

            let tableURLs = TableFileOperations.listTableURLs(tablesURL)
            var existingUUIDs = Set(loadedTables.map { $0.uuid })
            for fileURL in tableURLs {
                let relPath = relativePath(of: fileURL, baseURL: tablesURL)
                if !loadedTables.contains(where: { $0.path == relPath }) {
                    let newTable = createTable(url: fileURL, existingUUIDs: &existingUUIDs)
                    loadedTables.append(newTable)
                }
            }

            return loadedTables
        }.value

        tables = loadedTables
        saveTables()
    }

    private func saveTables() {
        let sorted = tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let response = TablesResponse(tableCount: sorted.count,
                                      tables: sorted)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,
                                    .withoutEscapingSlashes]

        if let jsonData = try? encoder.encode(response),
           let jsonString = String(data: jsonData,
                                   encoding: .utf8)
        {
            _ = TableFileOperations.write(tablesJSONURL,
                                          content: jsonString)
        }
    }

    private func createTable(url: URL) -> Table {
        let uuid = generateUUID()
        let relPath = relativePath(of: url)

        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: "_",
                                         with: " ")

        let now = Int64(Date().timeIntervalSince1970)

        let parentURL = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let pngURL = parentURL.appendingPathComponent(stem + ".png")
        let jpgURL = parentURL.appendingPathComponent(stem + ".jpg")

        var image = ""
        if TableFileOperations.exists(pngURL) {
            image = relativePath(of: pngURL)
        } else if TableFileOperations.exists(jpgURL) {
            image = relativePath(of: jpgURL)
        }

        return Table(uuid: uuid,
                     name: name,
                     path: relPath,
                     image: image,
                     createdAt: now,
                     modifiedAt: now)
    }

    private func generateUUID() -> String {
        var uuid = UUID().uuidString.lowercased()
        while tables.contains(where: { $0.uuid == uuid }) {
            uuid = UUID().uuidString.lowercased()
            VPinballManager.log(.warn, "UUID collision detected: \(uuid), regenerating")
        }
        return uuid
    }

    private func sanitizeName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: " _/\\:*?\"<>|.&'()")
        let sanitized = name.components(separatedBy: invalidChars).joined(separator: "-")

        var result = ""
        var lastWasHyphen = false
        for char in sanitized {
            if char == "-" {
                if !lastWasHyphen {
                    result.append(char)
                    lastWasHyphen = true
                }
            } else {
                result.append(char)
                lastWasHyphen = false
            }
        }

        while result.hasPrefix("-") {
            result.removeFirst()
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }

        return result.isEmpty ? "table" : result
    }

    private func getUniqueFolder(baseName: String) -> String {
        let sanitized = sanitizeName(baseName)
        var candidate = sanitized
        var counter = 2

        while TableFileOperations.exists(tablesURL.appendingPathComponent(candidate)) {
            candidate = "\(sanitized)-\(counter)"
            counter += 1
        }

        return candidate
    }

    private func coordinatedCopy(from sourceURL: URL, to destURL: URL) async -> Bool {
        await Task.detached {
            var coordinatorError: NSError?
            var copySuccess = false

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: coordinatedURL, to: destURL)
                    copySuccess = true
                } catch {}
            }

            return copySuccess
        }.value
    }

    private func relativePath(of url: URL) -> String {
        let fullPath = url.resolvingSymlinksInPath().path
        let basePath = tablesURL.path

        if fullPath.isEmpty || basePath.isEmpty {
            return fullPath
        }

        if !fullPath.hasPrefix(basePath) {
            return fullPath
        }

        var result = String(fullPath.dropFirst(basePath.count))
        if result.hasPrefix("/") {
            result = String(result.dropFirst())
        }

        return result
    }

    /// What an import brought in.
    struct ImportResult {
        var tables: [Table] = []
        var roms: [String] = []
        var extrasAttachedTo: Table?
        var scriptFixes: [String] = []
        /// Extras (a backglass, a script, a table's folders) whose table couldn't be told from
        /// their names, kept in this folder until one is picked.
        var pendingExtras: URL?

        var isEmpty: Bool {
            tables.isEmpty && roms.isEmpty && extrasAttachedTo == nil && pendingExtras == nil
        }
    }

    /// Files a table can have next to it, besides tables and ROMs.
    private nonisolated static let extraExtensions: Set<String> = ["directb2s", "vbs", "ini", "res", "pov", "cfg"]

    /// Files that never belong to a ROM, which holds only chip dumps.
    private nonisolated static let notRomExtensions: Set<String> = extraExtensions.union(["vpx", "vpz", "zip", "vpxz", "png", "jpg", "jpeg", "webp", "mp3", "ogg", "wav", "mp4", "pdf", "txt", "md", "url", "html", "json", "xml", "pal", "vni", "crz", "crom"])

    private func performImport(url: URL, onProgress: ((Int) async -> Void)? = nil) async -> ImportResult? {
        if !TableFileOperations.exists(url) {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        var result = ImportResult()

        switch ext {
        case "vpxz", "zip":
            guard let archiveResult = await importArchive(url: url, onProgress: onProgress) else {
                return nil
            }
            result = archiveResult
        case "vpx", "vpz":
            guard let destFile = await importTableFile(url: url, onProgress: onProgress) else {
                return nil
            }
            let newTable = createTable(url: destFile)
            tables.append(newTable)
            saveTables()
            result.tables = [newTable]
        case "directb2s", "vbs":
            await attachOrHoldExtras(items: [url], label: url.deletingPathExtension().lastPathComponent, result: &result)
        default:
            MainViewModel.shared.handleShowError(message: "\"\(url.lastPathComponent)\" isn't a table, a ROM or a table's file")
            return nil
        }

        for table in result.tables {
            await onProgress?(97)
            await checkScript(table: table, result: &result)
        }

        return result
    }

    /// Fixes the table's script when the community has a fix for it, and keeps the ROM it runs.
    private func checkScript(table: Table, result: inout ImportResult) async {
        let outcome = await ScriptPatches.apply(tableURL: table.fullURL)
        if case let .applied(file) = outcome.result {
            result.scriptFixes.append(file)
        }
        if let script = outcome.script {
            RomCheck.remember(tablePath: table.path, romNames: RomCheck.romNames(inScript: script))
        }
    }

    private func importTableFile(url: URL, onProgress: ((Int) async -> Void)? = nil) async -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        let folderName = getUniqueFolder(baseName: stem.replacingOccurrences(of: "_", with: " "))
        let destFolder = tablesURL.appendingPathComponent(folderName)
        let dest = destFolder.appendingPathComponent(url.lastPathComponent)
        let isPack = url.pathExtension.lowercased() == "vpz"

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        zipProgressHandler = { current, total in
            if total > 0 {
                let extractProgress = 60 + (current * 35 / total)
                Task { @MainActor in
                    await onProgress?(extractProgress)
                }
            }
        }

        let copied = await Task.detached(priority: .userInitiated) {
            if !TableFileOperations.createDirectory(destFolder) {
                return false
            }
            if isDirectory.boolValue {
                return TableFileOperations.copyDirectory(from: url, to: dest)
            }
            if isPack {
                return TableManager.extractPack(from: url, to: dest)
            }
            return TableFileOperations.copy(from: url, to: dest)
        }.value
        zipProgressHandler = nil

        if !copied || (isPack && !TableFileOperations.exists(dest.appendingPathComponent("manifest.json"))) {
            _ = TableFileOperations.deleteDirectory(destFolder)
            MainViewModel.shared.handleShowError(message: isPack
                ? "Not a valid VPZ pack"
                : "Failed to import table")
            return nil
        }

        return dest
    }

    private nonisolated static func extractPack(from url: URL, to dest: URL) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpinball_pack_\(Int(Date().timeIntervalSince1970))")

        defer {
            _ = TableFileOperations.deleteDirectory(tempDir)
        }

        if !TableFileOperations.createDirectory(tempDir) {
            return false
        }
        if VPinballStatus(rawValue: VPinballZipExtract(url.path.cstring, tempDir.path.cstring, zipCallback)) != .success {
            return false
        }
        return TableFileOperations.copyDirectory(from: packRoot(tempDir), to: dest)
    }

    private nonisolated static func packRoot(_ dir: URL) -> URL {
        if TableFileOperations.exists(dir.appendingPathComponent("manifest.json")) {
            return dir
        }

        let children = ((try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }

        if children.count == 1,
           let child = children.first,
           (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
           TableFileOperations.exists(child.appendingPathComponent("manifest.json"))
        {
            return child
        }

        return dir
    }

    /// An archive's tables, each folder holding tables imported as one table folder; its ROMs
    /// into the shared ROMs folder; and its other files next to the table they belong to. An
    /// archive holding only a machine's chip dumps is that machine's ROM.
    private func importArchive(url: URL, onProgress: ((Int) async -> Void)? = nil) async -> ImportResult? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpinball_import_\(Int(Date().timeIntervalSince1970))")

        if !TableFileOperations.createDirectory(tempDir) {
            return nil
        }

        defer {
            _ = TableFileOperations.deleteDirectory(tempDir)
        }

        zipProgressHandler = { current, total in
            if total > 0 {
                let extractProgress = 60 + (current * 35 / total)
                Task { @MainActor in
                    await onProgress?(extractProgress)
                }
            }
        }

        let status = await Task.detached {
            VPinballZipExtract(url.path.cstring, tempDir.path.cstring, zipCallback)
        }.value
        zipProgressHandler = nil

        if VPinballStatus(rawValue: status) != .success {
            MainViewModel.shared.handleShowError(message: "Unable to open the archive")
            return nil
        }

        var result = ImportResult()
        let files = await Task.detached(priority: .userInitiated) {
            TableManager.archiveFiles(tempDir)
        }.value

        let tableURLs = await Task.detached(priority: .userInitiated) {
            TableFileOperations.listTableURLs(tempDir)
        }.value

        if tableURLs.isEmpty {
            // a ROM: the archive holds chip dumps alone, no folders
            let isRom = url.pathExtension.lowercased() == "zip"
                && !files.isEmpty
                && files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == tempDir.standardizedFileURL.path }
                && !files.contains { TableManager.notRomExtensions.contains($0.pathExtension.lowercased()) }
            if isRom {
                if let name = installRom(url) {
                    result.roms.append(name)
                }
                return result
            }

            // ROMs, zipped together
            let nestedZips = files.filter { $0.pathExtension.lowercased() == "zip" }
            if !nestedZips.isEmpty && nestedZips.count == files.count {
                result.roms = nestedZips.compactMap { installRom($0) }
                return result
            }

            // a table's files without the table
            let top = topLevelItems(tempDir)
            if top.isEmpty {
                MainViewModel.shared.handleShowError(message: "The archive is empty")
                return nil
            }
            await attachOrHoldExtras(items: top, label: url.deletingPathExtension().lastPathComponent, result: &result)
            return result
        }

        // each folder holding tables, the outermost first, copied once with all its files
        let folders = Array(Set(tableURLs.map { $0.deletingLastPathComponent().standardizedFileURL }))
            .sorted { $0.path.count < $1.path.count }
        var copiedFolders: [URL] = []

        for folder in folders {
            if copiedFolders.contains(where: { folder.path.hasPrefix($0.path + "/") }) {
                continue
            }

            let folderTables = tableURLs.filter { $0.standardizedFileURL.path.hasPrefix(folder.path + "/") }
            let first = folderTables.map { $0.deletingPathExtension().lastPathComponent }.sorted().first ?? "table"
            let destFolder = tablesURL.appendingPathComponent(getUniqueFolder(baseName: first))

            let copied = await Task.detached(priority: .userInitiated) {
                TableFileOperations.createDirectory(destFolder) && TableFileOperations.copyDirectory(from: folder, to: destFolder)
            }.value
            if !copied {
                _ = TableFileOperations.deleteDirectory(destFolder)
                continue
            }
            copiedFolders.append(folder)

            for tableURL in folderTables {
                let relative = String(tableURL.standardizedFileURL.path.dropFirst(folder.path.count + 1))
                let newTable = createTable(url: destFolder.appendingPathComponent(relative))
                tables.append(newTable)
                result.tables.append(newTable)
            }
        }
        saveTables()

        if result.tables.isEmpty {
            MainViewModel.shared.handleShowError(message: "Failed to import table")
            return nil
        }

        // what lies outside the tables' folders: ROMs, and files for the tables
        let outside = files.filter { file in
            !copiedFolders.contains { file.standardizedFileURL.path.hasPrefix($0.path + "/") }
        }
        for zip in outside where zip.pathExtension.lowercased() == "zip" {
            if let name = installRom(zip) {
                result.roms.append(name)
            }
        }
        for extra in outside where TableManager.extraExtensions.contains(extra.pathExtension.lowercased()) {
            let stem = extra.deletingPathExtension().lastPathComponent
            if let table = result.tables.count == 1 ? result.tables.first : matchTable(named: stem, in: result.tables) {
                _ = attachExtras(items: [extra], to: table)
            }
        }

        return result
    }

    /// Every file in an archive, left out the folders macOS adds.
    private nonisolated static func archiveFiles(_ dir: URL) -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "__MACOSX" {
                    enumerator.skipDescendants()
                    continue
                }
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true,
                   fileURL.lastPathComponent != ".DS_Store"
                {
                    files.append(fileURL)
                }
            }
        }
        return files
    }

    /// An archive's contents, past a single folder holding everything.
    private func topLevelItems(_ dir: URL) -> [URL] {
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        if items.count == 1, let only = items.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
           only.lastPathComponent.lowercased() != "pinmame"
        {
            return topLevelItems(only)
        }
        return items
    }

    /// A ROM into the shared ROMs folder, under the name PinMAME looks for; its name, or nil.
    private func installRom(_ zip: URL) -> String? {
        let romsURL = RomCheck.sharedRomsURL
        let fileName = RomCheck.cleanRomFileName(zip.lastPathComponent)
        if !TableFileOperations.createDirectory(romsURL)
            || !TableFileOperations.copy(from: zip, to: romsURL.appendingPathComponent(fileName))
        {
            VPinballManager.log(.error, "Unable to install the ROM \(fileName)")
            return nil
        }
        VPinballManager.log(.info, "Installed the ROM \(fileName)")
        return URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    /// The one table whose file or name matches `name`, ignoring case, spaces and punctuation.
    private func matchTable(named name: String, in candidates: [Table]? = nil) -> Table? {
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(name)
        if wanted.isEmpty {
            return nil
        }
        let pool = candidates ?? tables

        let exact = pool.filter { key($0.stem) == wanted || key($0.name) == wanted }
        if exact.count == 1 {
            return exact.first
        }
        if !exact.isEmpty {
            return nil
        }

        // "Attack from Mars (Bally 1995) VPW 2.0" for "Attack from Mars (Bally 1995)"
        if wanted.count >= 6 {
            let partial = pool.filter {
                let stem = key($0.stem)
                return stem.count >= 6 && (stem.hasPrefix(wanted) || wanted.hasPrefix(stem))
            }
            if partial.count == 1 {
                return partial.first
            }
        }
        return nil
    }

    /// Extras next to the table their name matches, or held until a table is picked.
    private func attachOrHoldExtras(items: [URL], label: String, result: inout ImportResult) async {
        let names = [label] + items.map { $0.deletingPathExtension().lastPathComponent }
        for name in names {
            if let table = matchTable(named: name) {
                if attachExtras(items: items, to: table) {
                    result.extrasAttachedTo = table
                }
                return
            }
        }

        let pending = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpinball_pending_\(Int(Date().timeIntervalSince1970))")
            .appendingPathComponent(label)
        if !TableFileOperations.createDirectory(pending) {
            return
        }
        for item in items {
            _ = TableFileOperations.copyMerging(from: item, to: pending.appendingPathComponent(item.lastPathComponent))
        }
        result.pendingExtras = pending
    }

    /// Files and folders put next to a table, merged with what's there. A single backglass or
    /// script takes the table's name, as VPX looks for it.
    @discardableResult
    func attachExtras(items: [URL], to table: Table) -> Bool {
        let dir = table.baseURL
        let single = { (ext: String) in items.filter { $0.pathExtension.lowercased() == ext }.count == 1 }

        for item in items {
            let ext = item.pathExtension.lowercased()
            var name = item.lastPathComponent
            if (ext == "directb2s" || ext == "vbs" || ext == "ini") && single(ext) {
                name = table.stem + "." + ext
            }
            if !TableFileOperations.copyMerging(from: item, to: dir.appendingPathComponent(name)) {
                VPinballManager.log(.error, "Unable to put \(item.lastPathComponent) next to \(table.fileName)")
                return false
            }
            if ext == "vbs", let script = try? Data(contentsOf: table.scriptURL) {
                RomCheck.remember(tablePath: table.path, romNames: RomCheck.romNames(inScript: script))
            }
        }

        if let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
            tables[index] = tables[index].with(modifiedAt: Int64(Date().timeIntervalSince1970))
            saveTables()
        }
        return true
    }

    /// Extras held by an import put next to the table picked for them.
    func attachPendingExtras(_ folder: URL, to table: Table) -> Bool {
        defer {
            _ = TableFileOperations.deleteDirectory(folder.deletingLastPathComponent())
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return attachExtras(items: items, to: table)
    }

    private func performRename(table: Table, newName: String) -> Bool {
        if let index = tables.firstIndex(where: { $0.uuid == table.uuid }) {
            let now = Int64(Date().timeIntervalSince1970)
            tables[index] = tables[index].with(name: newName, modifiedAt: now)
            saveTables()
            return true
        }
        return false
    }

    private func performExport(table: Table, onProgress: ((Int, String) async -> Void)? = nil) async -> String? {
        let sanitizedName = sanitizeName(table.name)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName + ".vpxz")
        let tableDirURL = table.baseURL

        await onProgress?(60, "Compressing")

        zipProgressHandler = { current, total in
            let adjustedProgress = 60 + (current * 39 / max(total, 1))
            Task { @MainActor in
                await onProgress?(adjustedProgress, "Compressing")
            }
        }

        let result = await Task.detached {
            if TableFileOperations.exists(tempURL) {
                _ = TableFileOperations.delete(tempURL)
            }

            return VPinballZipCreate(tableDirURL.path.cstring, tempURL.path.cstring, zipCallback)
        }.value

        zipProgressHandler = nil

        if VPinballStatus(rawValue: result) != .success {
            return nil
        }

        await onProgress?(100, "Complete")
        return tempURL.path
    }
}
