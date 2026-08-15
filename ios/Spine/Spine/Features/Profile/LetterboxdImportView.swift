import SwiftUI
import UniformTypeIdentifiers

struct LetterboxdImportView: View {
    @State private var mode: ImportMode = .new
    @State private var isFileImporterPresented = false
    @State private var isOverwriteConfirmationPresented = false
    @State private var isUploadScreenPresented = false

    let coordinator: LetterboxdImportCoordinator

    private var isBusy: Bool {
        switch coordinator.phase {
        case .uploading, .processing:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    var body: some View {
        SettingsImportLandingPage(
            source: "Letterboxd",
            headline: "Bring your film life with you.",
            instructions: "Export your data from Letterboxd settings, then upload the ZIP file here.",
            linkTitle: "Open Letterboxd Data Settings",
            linkURL: URL(string: "https://letterboxd.com/settings/data/")!,
            systemName: "film.stack.fill",
            tint: Color(red: 0.96, green: 0.47, blue: 0.20),
            mode: $mode,
            modeDetail: mode.detail,
            fileTitle: "Choose Letterboxd Export",
            fileSystemName: "doc.zipper",
            isBusy: isBusy,
            chooseFile: chooseFile
        )
        .navigationTitle("Letterboxd Import")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "This will remove your current movie tracking and Letterboxd-imported lists before importing. This can't be undone.",
            isPresented: $isOverwriteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Replace Existing", role: .destructive) {
                isOverwriteConfirmationPresented = false
                isFileImporterPresented = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false,
            onCompletion: handleFileImporterResult
        )
        .fullScreenCover(isPresented: $isUploadScreenPresented) {
            LetterboxdImportUploadView(
                coordinator: coordinator,
                onDone: { isUploadScreenPresented = false }
            )
        }
    }

    private func chooseFile() {
        if mode == .overwrite {
            isOverwriteConfirmationPresented = true
        } else {
            isFileImporterPresented = true
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            isUploadScreenPresented = true
            coordinator.startImport(fileURL: url, mode: mode)
        case let .failure(error):
            isUploadScreenPresented = true
            coordinator.phase = .failed(message: error.localizedDescription)
        }
    }
}

struct SettingsImportLandingPage: View {
    let source: String
    let headline: String
    let instructions: String
    let linkTitle: String
    let linkURL: URL
    let systemName: String
    let tint: Color
    @Binding var mode: ImportMode
    let modeDetail: String
    let fileTitle: String
    let fileSystemName: String
    let isBusy: Bool
    let chooseFile: () -> Void

    var body: some View {
        ZStack {
            SpinePageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    instructionsCard
                    modeCard

                    Button(action: chooseFile) {
                        Label(fileTitle, systemImage: fileSystemName)
                            .font(.headline)
                            .foregroundStyle(isBusy ? .white.opacity(0.38) : .black)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .tint(isBusy ? .white.opacity(0.08) : .white)
                    .buttonStyle(.glassProminent)
                    .disabled(isBusy)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .shadow(color: tint.opacity(0.28), radius: 12, y: 7)

            Text(headline)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .tracking(-0.55)
                .foregroundStyle(.white)

            Text("Move your \(source) history into Spine without starting over.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    private var instructionsCard: some View {
        importGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(instructions)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: linkURL) {
                    HStack {
                        Text(linkTitle)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
            }
            .padding(16)
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("IMPORT MODE")
                .font(.system(size: 12, weight: .black))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.46))
                .padding(.leading, 3)

            importGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Import Mode", selection: $mode) {
                        ForEach(ImportMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)

                    Label(modeDetail, systemImage: mode == .new ? "plus.circle.fill" : "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
    }

    private func importGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.025), in: shape)
            .glassEffect(.regular.tint(.white.opacity(0.035)), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.09), lineWidth: 1) }
    }
}

extension ImportMode {
    var title: String {
        switch self {
        case .new:
            "Add new only"
        case .overwrite:
            "Replace existing"
        }
    }

    var detail: String {
        switch self {
        case .new:
            "Import movies, diary entries, lists, and likes that aren't already in Spine."
        case .overwrite:
            "Delete your existing imported movies, diary entries, and Letterboxd lists, then import everything from this file."
        }
    }
}

private struct MockImportRepository: ImportRepository {
    func queueLetterboxdImport(
        fileData: Data,
        fileName: String,
        mode: ImportMode,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> ImportQueueResponse {
        progressHandler?(1)
        return ImportQueueResponse(taskId: "preview-task", status: "queued")
    }

    func queueStoryGraphImport(
        fileData: Data,
        fileName: String,
        mode: ImportMode,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> ImportQueueResponse {
        fatalError("Not used")
    }

    func queueGoodreadsImport(
        fileData: Data,
        fileName: String,
        mode: ImportMode,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> ImportQueueResponse {
        fatalError("Not used")
    }

    func importTaskStatus(taskId: String) async throws -> ImportTaskStatus {
        ImportTaskStatus(
            taskId: taskId,
            taskName: "Import from Letterboxd",
            status: "SUCCESS",
            dateCreated: nil,
            dateDone: nil,
            result: "Imported 12 movies."
        )
    }
}

#Preview {
    NavigationStack {
        LetterboxdImportView(
            coordinator: LetterboxdImportCoordinator(importRepository: MockImportRepository())
        )
    }
}
