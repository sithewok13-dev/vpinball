import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(\.dismissSearch) var dismissSearch

    @Namespace private var playNamespace

    @ObservedObject var vpinballModel = VPinballModel.shared
    @ObservedObject var mainViewModel = MainViewModel.shared

    let settingsModel = SettingsModel()

    var body: some View {
        ZStack {
            tableBrowser

            if vpinballModel.showHUD && vpinballModel.activeTable == nil {
                HUDOverlayView()
            }
        }
        .ignoresSafeArea()
        .tint(Color.vpxAccent)
        .sensoryFeedback(.impact(weight: .medium), trigger: vpinballModel.activeTable)
        .tableLaunchPresentation(in: playNamespace)
        .mainSheets(settingsModel: settingsModel)
        .mainAlerts()
        .onAppear {
            mainViewModel.handleAppear()
        }
        .onChange(of: vpinballModel.tables) {
            if vpinballModel.tables.isEmpty {
                mainViewModel.tableListSearchText = ""
                dismissSearch()
            }
        }
        .onChange(of: mainViewModel.tableImagePhotoItem) {
            mainViewModel.handleTableImagePhotoItem()
        }
    }

    private var tableBrowser: some View {
        NavigationStack {
            ZStack {
                AmbientBackgroundView()

                if vpinballModel.tables.isEmpty {
                    EmptyStateView()
                } else {
                    TableGridView(tables: vpinballModel.tables,
                                  gridSize: mainViewModel.tableGridSize,
                                  sortOrder: mainViewModel.tableListSortOrder,
                                  searchText: mainViewModel.tableListSearchText,
                                  searchPresented: mainViewModel.tableListSearchPresented,
                                  namespace: playNamespace,
                                  scrollToTable: $mainViewModel.scrollToTable)
                }
            }
            .tint(Color.vpxAccent)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .mainToolbar(hasTables: !vpinballModel.tables.isEmpty,
                         viewOptions: { viewOptionsMenu },
                         importMenu: { importMenu })
            .tableSearch(enabled: !vpinballModel.tables.isEmpty,
                         text: $mainViewModel.tableListSearchText,
                         isPresented: $mainViewModel.tableListSearchPresented)
        }
        .tint(.primary)
    }

    private var viewOptionsMenu: some View {
        Menu {
            Section("Grid Size") {
                Toggle(isOn: selection($mainViewModel.tableGridSize, .small, animated: true)) {
                    Label("Small", systemImage: "square.grid.4x3.fill")
                }
                Toggle(isOn: selection($mainViewModel.tableGridSize, .medium, animated: true)) {
                    Label("Medium", systemImage: "square.grid.3x3.fill")
                }
                Toggle(isOn: selection($mainViewModel.tableGridSize, .large, animated: true)) {
                    Label("Large", systemImage: "square.grid.2x2.fill")
                }
            }

            Section("Sort By") {
                Toggle("Name A-Z", isOn: selection($mainViewModel.tableListSortOrder, .forward))
                Toggle("Name Z-A", isOn: selection($mainViewModel.tableListSortOrder, .reverse))
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("View Options")
    }

    private var importMenu: some View {
        Menu {
            Section("Import From...") {
                Button {
                    mainViewModel.importingFolder = false
                    mainViewModel.showImportTable = true
                } label: {
                    Label("Files", systemImage: "doc")
                }
                Button {
                    mainViewModel.importingFolder = true
                    mainViewModel.showImportTable = true
                } label: {
                    Label("Folder", systemImage: "folder")
                }
            }

            Section("Built in...") {
                Button {
                    mainViewModel.handleShowConfirmImportTable(url: Bundle.main.url(forResource: "assets/blankTable", withExtension: "vpz"))
                } label: {
                    Label("blankTable.vpz", systemImage: "doc.text")
                }
                Button {
                    mainViewModel.handleShowConfirmImportTable(url: Bundle.main.url(forResource: "assets/exampleTable", withExtension: "vpz"))
                } label: {
                    Label("exampleTable.vpz", systemImage: "doc.text")
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Import Table")
    }

    private func selection<T: Equatable>(_ binding: Binding<T>, _ value: T, animated: Bool = false) -> Binding<Bool> {
        Binding {
            binding.wrappedValue == value
        } set: { isOn in
            guard isOn else { return }
            withAnimation(animated ? .snappy : nil) {
                binding.wrappedValue = value
            }
        }
    }
}

private struct TableLaunchPresentation: ViewModifier {
    let namespace: Namespace.ID

    @State private var launchTable: Table?

    @ObservedObject var vpinballModel = VPinballModel.shared
    @ObservedObject var mainViewModel = MainViewModel.shared

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $launchTable) { table in
                TableLaunchView(table: table)
                    .navigationTransition(.zoom(sourceID: mainViewModel.playSourceID, in: namespace))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if vpinballModel.activeTable == nil {
                    MainViewModel.shared.handleBecameActive()
                }
            }
            .onChange(of: vpinballModel.activeTable) { _, table in
                if let table, !vpinballModel.isPlaying {
                    launchTable = table
                } else if table == nil {
                    launchTable = nil
                }
            }
            .onChange(of: vpinballModel.isPlaying) { _, isPlaying in
                if isPlaying {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        launchTable = nil
                    }
                }
            }
    }
}

private struct MainSheets: ViewModifier {
    let settingsModel: SettingsModel

    @ObservedObject var mainViewModel = MainViewModel.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $mainViewModel.showSettings,
                   content: {
                       SettingsView(settingsModel: settingsModel)
                           .presentationDetents([.custom(CustomDetent.self)])
                           .presentationDragIndicator(.hidden)
                           .ignoresSafeArea()
                   })
            .fileImporter(isPresented: $mainViewModel.showImportTable,
                          allowedContentTypes: mainViewModel.importingFolder ? [.folder] : [.vpx, .vpxz, .vpz, .zip, .directb2s, .vbscript])
            { result in
                if case let .success(url) = result {
                    mainViewModel.importTableURL = url
                }
            }
            .sheet(isPresented: $mainViewModel.showShare,
                   content: {
                       ActivityViewControllerView(activityItems: $mainViewModel.shareItems,
                                                  excludedActivityTypes: [.mail,
                                                                          .message,
                                                                          .postToFacebook])
                           .presentationDetents([.medium])
                           .presentationDragIndicator(.hidden)
                           .ignoresSafeArea()
                   })
            .sheet(isPresented: $mainViewModel.showChooseTableForExtras,
                   onDismiss: {
                       mainViewModel.handleCancelAttachExtras()
                   },
                   content: {
                       ChooseTableView(title: mainViewModel.pendingExtrasFolder?.lastPathComponent ?? "") { table in
                           mainViewModel.handleAttachExtras(to: table)
                       }
                       .presentationDetents([.medium, .large])
                   })
    }
}

/// The tables to pick from for files whose table couldn't be told from their names.
private struct ChooseTableView: View {
    let title: String
    let onChoose: (Table) -> Void

    @ObservedObject var vpinballModel = VPinballModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(vpinballModel.tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { table in
                Button(table.name) {
                    onChoose(table)
                    dismiss()
                }
                .tint(.primary)
            }
            .navigationTitle("Which table is \"\(title)\" for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MainAlerts: ViewModifier {
    @ObservedObject var mainViewModel = MainViewModel.shared

    func body(content: Content) -> some View {
        content
            .alert("Reset Settings?", isPresented: $mainViewModel.showResetSettings, presenting: mainViewModel.selectedTable) { _ in
                Button("Reset", role: .destructive) {
                    mainViewModel.handleResetTable()
                }
                Button("Cancel", role: .cancel) {}
            } message: { table in
                Text("The saved settings for \"\(table.name)\" will be removed.")
            }
            .alert("Reset Image?", isPresented: $mainViewModel.showResetImage, presenting: mainViewModel.selectedTable) { _ in
                Button("Reset", role: .destructive) {
                    mainViewModel.handleTableImageReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: { table in
                Text("The image for \"\(table.name)\" will be removed.")
            }
            .alert("Delete Table?", isPresented: $mainViewModel.showDelete, presenting: mainViewModel.selectedTable) { _ in
                Button("Delete", role: .destructive) {
                    mainViewModel.handleDeleteTable()
                }
                Button("Cancel", role: .cancel) {}
            } message: { table in
                Text("\"\(table.name)\" and its files will be permanently deleted.")
            }
            .photosPicker(isPresented: $mainViewModel.showTableImagePhotoPicker,
                          selection: $mainViewModel.tableImagePhotoItem,
                          matching: .any(of: [.images,
                                              .screenshots,
                                              .livePhotos]))
            .fullScreenCover(isPresented: $mainViewModel.showScript, content: {
                if let table = mainViewModel.selectedTable {
                    CodeView(url: table.scriptURL,
                             language: .vbscript)
                }
            })
            .alert("Confirm Import Table", isPresented: $mainViewModel.showConfirmImportTable) {
                Button("OK") {
                    mainViewModel.handleConfirmImportTable()
                }
                Button("Cancel", role: .cancel) {
                    mainViewModel.confirmImportTableURL = nil
                }
            }
            message: {
                if let filename = mainViewModel.confirmImportTableURL?.lastPathComponent.removingPercentEncoding {
                    Text("\nImport \"\(filename)\"?")
                }
            }
            .alert("Rename Table", isPresented: $mainViewModel.showRenameTable) {
                TextField("", text: $mainViewModel.renameTableName)
                    .textInputAutocapitalization(.never)
                Button("Rename") {
                    mainViewModel.handleRenameTable()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Imported", isPresented: $mainViewModel.showImportSummary) {
                Button("OK") {}
            }
            message: {
                Text("\n\(mainViewModel.importSummary)")
            }
            .alert("ROM Missing", isPresented: $mainViewModel.showMissingRom) {
                Button("Play Anyway") {
                    mainViewModel.handlePlayTableAnyway()
                }
                Button("Learn More") {
                    Link.troubleshooting.open()
                }
                Button("Cancel", role: .cancel) {}
            }
            message: {
                Text("\nThis table needs the ROM \(mainViewModel.missingRoms.first ?? "").zip. Import it with the + button or open it in the Files app; ROMs are shared by all your tables.")
            }
            .alert("TILT!",
                   isPresented: $mainViewModel.showError)
            {
                Button("Learn More") {
                    Link.troubleshooting.open()
                }
                Button("OK") {}
            }
            message: {
                Text("\n\(mainViewModel.errorMessage)")
            }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 40) {
            TableImagePlaceholderView()
                .frame(maxHeight: 540)

            VStack(spacing: 16) {
                Text("Free Play")
                    .font(.title)
                    .bold()
                    .blinkEffect()

                Text("Tap \(Image(systemName: "plus")) below to add your first table.")
                    .font(.body)
                    .foregroundStyle(Color.subtitle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button("Learn More...") {
                    Link.docs.open()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .tint(.primary)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TableLaunchView: View {
    let table: Table

    @State private var image: UIImage?

    init(table: Table) {
        self.table = table
        _image = State(initialValue: table.cachedThumbnail(maxPixelSize: TableImageView.thumbnailMaxPixelSize))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)

            if let image {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 40)
                            .overlay(Color.black.opacity(0.35))
                    }
                    .clipped()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                TableImagePlaceholderView(contentMode: .fit)
                    .padding(.vertical, 40)
            }

            HUDOverlayView()
        }
        .ignoresSafeArea()
        .task(id: "\(table.uuid)_\(table.modifiedAt)") {
            if let fullImage = await table.uiImageAsync() {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    image = fullImage
                }
            }
        }
    }
}

struct CustomDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        return context.maxDetentValue - 1
    }
}

private struct SettingsToolbarButton: View {
    var body: some View {
        Button {
            MainViewModel.shared.showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }
}

private struct LogoToolbarImage: View {
    var body: some View {
        Image("vpinball-logo")
            .resizable()
            .scaledToFit()
            .frame(height: 30)
    }
}

extension View {
    func mainToolbar<Options: View, Import: View>(hasTables: Bool,
                                                  @ViewBuilder viewOptions: () -> Options,
                                                  @ViewBuilder importMenu: () -> Import) -> some View
    {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SettingsToolbarButton()
            }

            ToolbarItem(placement: .principal) {
                LogoToolbarImage()
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .topBarTrailing) {
                viewOptions()
            }

            if hasTables {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                importMenu()
            }
        }
    }

    @ViewBuilder
    func tableSearch(enabled: Bool, text: Binding<String>, isPresented: Binding<Bool>) -> some View {
        if enabled {
            searchable(text: text, isPresented: isPresented, prompt: "Search Tables")
                .searchToolbarBehavior(.minimize)
        } else {
            self
        }
    }

    func tableLaunchPresentation(in namespace: Namespace.ID) -> some View {
        modifier(TableLaunchPresentation(namespace: namespace))
    }

    func mainSheets(settingsModel: SettingsModel) -> some View {
        modifier(MainSheets(settingsModel: settingsModel))
    }

    func mainAlerts() -> some View {
        modifier(MainAlerts())
    }
}

#Preview {
    MainView()
}
