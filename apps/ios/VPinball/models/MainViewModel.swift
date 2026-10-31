import PhotosUI
import SwiftUI

@MainActor
class MainViewModel: ObservableObject {
    static let shared = MainViewModel()

    enum ActionType {
        case play
        case stopped
        case toggleFavorite
        case removeFromRecent
        case rename
        case chooseImage
        case viewScript
        case share
        case resetImage
        case resetSettings
        case delete
    }

    @Published var selectedTable: Table?
    @Published var playSourceID = ""

    @Published var showSettings = false

    @Published var confirmImportTableURL: URL?
    @Published var showConfirmImportTable = false

    @Published var importTableURL: URL? {
        didSet { handleImportTableURL() }
    }

    @Published var showImportTable = false
    /// The importer picks a folder of tables, ROMs and tables' files rather than files.
    @Published var importingFolder = false

    @Published var tableListSearchText = ""
    @Published var tableListSearchPresented = false

    @Published var shareItems: [Any] = []
    @Published var showShare = false

    @Published var renameTableName = ""
    @Published var showRenameTable = false

    @Published var tableImagePhotoItem: PhotosPickerItem?
    @Published var showTableImagePhotoPicker = false
    @Published var showResetImage = false
    @Published var showResetSettings = false
    @Published var showDelete = false

    @Published var showScript = false

    @Published var errorMessage = ""
    @Published var showError = false

    @Published var importSummary = ""
    @Published var showImportSummary = false

    @Published var pendingExtrasFolder: URL?
    @Published var showChooseTableForExtras = false

    @Published var missingRoms: [String] = []
    @Published var showMissingRom = false

    @Published var openURL: URL? {
        didSet { handleOpenURL() }
    }

    @Published var scrollToTable: Table?

    @Published var tableGridSize: TableGridSize = .medium {
        didSet { VPinballManager.shared.saveValue(.standalone, "TableGridSize", tableGridSize.rawValue) }
    }

    @Published var tableListSortOrder: SortOrder = .forward {
        didSet { VPinballManager.shared.saveValue(.standalone, "TableListSort", tableListSortOrder == .forward ? 1 : 0) }
    }

    func loadSettings() {
        let manager = VPinballManager.shared
        tableGridSize = TableGridSize(rawValue: manager.loadValue(.standalone,
                                                                  "TableGridSize",
                                                                  TableGridSize.medium.rawValue)) ?? .medium
        tableListSortOrder = manager.loadValue(.standalone, "TableListSort", 1) == 1 ? .forward : .reverse
    }

    func setAction(_ type: ActionType, table: Table? = nil) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil,
                                        from: nil,
                                        for: nil)

        selectedTable = table

        switch type {
        case .play:
            handlePlayTable()
        case .toggleFavorite:
            if let table {
                withAnimation(.snappy) {
                    TableManager.shared.toggleFavorite(table: table)
                }
            }
        case .removeFromRecent:
            if let table {
                withAnimation(.snappy) {
                    TableManager.shared.clearPlayed(table: table)
                }
            }
        case .rename:
            handleShowRenameTable()
        case .chooseImage:
            tableImagePhotoItem = nil
            showTableImagePhotoPicker = true
        case .viewScript:
            handleViewTableScript()
        case .share:
            handleShareTable()
        case .resetImage:
            showResetImage = true
        case .resetSettings:
            showResetSettings = true
        case .delete:
            showDelete = true
        case .stopped:
            break
        }
    }

    func play(_ table: Table, sourceID: String) {
        playSourceID = sourceID
        setAction(.play, table: table)
    }

    func handleAppear() {
        loadSettings()

        Task {
            await TableManager.shared.refresh()
        }

        handleOpenURL()
    }

    func handleOpenURL() {
        if let url = openURL {
            openURL = nil
            handleShowConfirmImportTable(url: url)
        }
    }

    func handleImportTableURL() {
        handleShowConfirmImportTable(url: importTableURL)
    }

    func handleShowConfirmImportTable(url: URL?) {
        if let url = url {
            importTableURL = nil
            confirmImportTableURL = url
            showConfirmImportTable = true
        }
    }

    func handleConfirmImportTable() {
        if let url = confirmImportTableURL {
            handleImportTable(url: url)
        }
        confirmImportTableURL = nil
    }

    func handleImportTable(url: URL?) {
        if let url = url {
            Task {
                _ = await TableManager.shared.importTable(from: url)
            }
        }
    }

    func handleShowRenameTable() {
        if let selectedTable = selectedTable {
            renameTableName = selectedTable.name
            showRenameTable = true
            scrollToTable = nil
        }
    }

    func handleRenameTable() {
        if let selectedTable = selectedTable {
            Task {
                _ = await TableManager.shared.renameTable(table: selectedTable,
                                                          newName: renameTableName)
                scrollToTable = selectedTable
            }
        }
    }

    func handleTableImagePhotoItem() {
        if let selectedTable = selectedTable {
            if let item = tableImagePhotoItem {
                item.loadTransferable(type: Data.self) { result in
                    switch result {
                    case let .success(data?):
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if let image = UIImage(data: data) {
                                Task {
                                    await TableManager.shared.setTableImage(table: selectedTable,
                                                                            image: image)
                                }
                            } else {
                                Task {
                                    await TableManager.shared.setTableImage(table: selectedTable,
                                                                            imagePath: "")
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    func handleTableImageReset() {
        if let selectedTable = selectedTable {
            Task {
                await TableManager.shared.setTableImage(table: selectedTable,
                                                        imagePath: "")
            }
        }
    }

    func handleViewTableScript() {
        if let selectedTable = selectedTable {
            Task {
                let hasScript = await selectedTable.hasScriptFileAsync()
                if hasScript {
                    await MainActor.run {
                        showScript = true
                    }
                    return
                }

                if await TableManager.shared.extractTableScript(table: selectedTable) {
                    await MainActor.run {
                        showScript = true
                    }
                } else {
                    await MainActor.run {
                        handleShowError(message: "Unable to extract script")
                    }
                }
            }
        }
    }

    func handleShareTable() {
        if let selectedTable = selectedTable {
            Task {
                if let path = await TableManager.shared.exportTable(table: selectedTable) {
                    shareItems = [URL(fileURLWithPath: path)]
                    showShare = true
                }
            }
        }
    }

    func handleResetTable() {
        if let selectedTable = selectedTable {
            _ = TableManager.shared.resetTableIni(table: selectedTable)
        }
    }

    func handleDeleteTable() {
        if let selectedTable = selectedTable {
            Task {
                await TableManager.shared.deleteTable(table: selectedTable)
            }
        }
    }

    func handlePlayTable() {
        if let selectedTable = selectedTable {
            let missing = RomCheck.missingRoms(for: selectedTable)
            if !missing.isEmpty {
                missingRoms = missing
                showMissingRom = true
                return
            }
            handlePlayTableAnyway()
        }
    }

    func handlePlayTableAnyway() {
        if let selectedTable = selectedTable {
            Task {
                await VPinballManager.shared.play(table: selectedTable)
            }
        }
    }

    func handleShowImportSummary(_ result: TableManager.ImportResult) {
        var lines: [String] = []
        switch result.tables.count {
        case 0:
            break
        case 1:
            lines.append("Added \"\(result.tables[0].name)\".")
        default:
            lines.append("Added \(result.tables.count) tables.")
        }
        if let table = result.extrasAttachedTo {
            lines.append("Added the files to \"\(table.name)\".")
        }
        if !result.roms.isEmpty {
            lines.append("Installed the ROM\(result.roms.count > 1 ? "s" : "") \(result.roms.joined(separator: ", ")).")
        }
        if !result.scriptFixes.isEmpty {
            lines.append("Applied the community's mobile fix to the script.")
        }
        for table in result.tables {
            let missing = RomCheck.missingRoms(for: table)
            if !missing.isEmpty {
                lines.append("\"\(table.name)\" needs the ROM \(missing[0]).zip: import it the same way.")
            }
        }

        // a plain table with nothing more to say needs no message
        if result.tables.count == 1 && lines.count == 1 && result.roms.isEmpty {
            return
        }
        if lines.isEmpty {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.importSummary = lines.joined(separator: "\n")
            self.showImportSummary = true
        }
    }

    func handleChooseTableForExtras(folder: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.pendingExtrasFolder = folder
            self.showChooseTableForExtras = true
        }
    }

    func handleAttachExtras(to table: Table) {
        guard let folder = pendingExtrasFolder else { return }
        pendingExtrasFolder = nil
        if TableManager.shared.attachPendingExtras(folder, to: table) {
            scrollToTable = table
            var result = TableManager.ImportResult()
            result.extrasAttachedTo = table
            handleShowImportSummary(result)
        } else {
            handleShowError(message: "Unable to add the files to \"\(table.name)\"")
        }
    }

    func handleCancelAttachExtras() {
        if let folder = pendingExtrasFolder {
            _ = TableFileOperations.deleteDirectory(folder.deletingLastPathComponent())
        }
        pendingExtrasFolder = nil
    }

    func handleShowError(message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.errorMessage = message
            self.showError = true
        }
    }
}
