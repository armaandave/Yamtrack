import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ProfileViewModel {
    var profile: UserProfile?
    var recentActivityItems: [ActivityItem] = []
    var inProgressItems: [LibraryItem] = []
    var isLoading = true
    var isLoadingInProgress = false
    var isLoadingActivity = false
    var errorMessage: String?
    var activityErrorMessage: String?
    var inProgressErrorMessage: String?
    var hofErrorMessage: String?
    var savingHallOfFameSlots: Set<String> = []

    private let profileRepository: ProfileRepository
    private let trackingRepository: TrackingRepository
    private let activityRepository: ActivityRepository
    private let onUnauthorized: () -> Void
    private let username: String?
    private var requestGeneration = 0

    init(
        profileRepository: ProfileRepository,
        trackingRepository: TrackingRepository,
        activityRepository: ActivityRepository,
        username: String? = nil,
        onUnauthorized: @escaping () -> Void
    ) {
        self.profileRepository = profileRepository
        self.trackingRepository = trackingRepository
        self.activityRepository = activityRepository
        self.username = username
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = profile == nil
        errorMessage = nil
        isLoadingInProgress = false
        isLoadingActivity = false
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let loadedProfile: UserProfile
            if let username {
                loadedProfile = try await profileRepository.profile(username: username)
            } else {
                loadedProfile = try await profileRepository.me()
            }
            guard generation == requestGeneration else { return }
            profile = loadedProfile
            if username == nil {
                isLoadingInProgress = inProgressItems.isEmpty
            }
            isLoadingActivity = recentActivityItems.isEmpty
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return
        }

        if username == nil {
            await loadInProgressItems(generation: generation)
        }
        await loadRecentActivity(generation: generation)
    }

    func reload() async {
        await load()
    }

    func isSavingHallOfFameSlot(_ mediaType: String) -> Bool {
        savingHallOfFameSlots.contains(mediaType)
    }

    private func loadRecentActivity(generation: Int) async {
        guard let username = profile?.username else {
            recentActivityItems = []
            activityErrorMessage = nil
            isLoadingActivity = false
            return
        }

        isLoadingActivity = true
        activityErrorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoadingActivity = false
            }
        }

        do {
            let activity = try await activityRepository.userActivity(username: username, limit: 6)
            guard generation == requestGeneration else { return }
            recentActivityItems = activity
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            activityErrorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    private func loadInProgressItems(generation: Int) async {
        let mediaTypes = InProgressLibraryLoader.mediaTypes(from: profile)
        guard !mediaTypes.isEmpty else {
            inProgressItems = []
            inProgressErrorMessage = nil
            isLoadingInProgress = false
            return
        }

        isLoadingInProgress = true
        inProgressErrorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoadingInProgress = false
            }
        }

        do {
            let items = try await InProgressLibraryLoader.load(
                mediaTypes: mediaTypes,
                trackingRepository: trackingRepository,
                limit: 8
            )
            guard generation == requestGeneration else { return }
            inProgressItems = items
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            inProgressErrorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    private func handleUnauthorized(_ error: Error) {
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }

    @discardableResult
    func setHallOfFameItem(mediaType: String, ref: MediaRef) async -> Bool {
        guard !savingHallOfFameSlots.contains(mediaType) else { return false }
        savingHallOfFameSlots.insert(mediaType)
        hofErrorMessage = nil
        defer { savingHallOfFameSlots.remove(mediaType) }

        do {
            let hof = try await profileRepository.setHallOfFameItem(mediaType: mediaType, ref: ref)
            profile = profile?.replacingHallOfFame(hof)
            return true
        } catch {
            hofErrorMessage = error.localizedDescription
            handleUnauthorized(error)
            return false
        }
    }

    @discardableResult
    func clearHallOfFameItem(mediaType: String) async -> Bool {
        guard !savingHallOfFameSlots.contains(mediaType) else { return false }
        savingHallOfFameSlots.insert(mediaType)
        hofErrorMessage = nil
        defer { savingHallOfFameSlots.remove(mediaType) }

        do {
            let hof = try await profileRepository.clearHallOfFameItem(mediaType: mediaType)
            profile = profile?.replacingHallOfFame(hof)
            return true
        } catch {
            hofErrorMessage = error.localizedDescription
            handleUnauthorized(error)
            return false
        }
    }
}

@MainActor
@Observable
final class ProfileSettingsViewModel {
    var profile: UserProfile?
    var settingsOptions = SettingsOptions(dateFormats: [], timeFormats: [], weekStartDays: [], quickWatchDates: [])
    var mediaTypes: [String] = []
    var displayName = ""
    var username = ""
    var bio = ""
    var pronouns = ""
    var location = ""
    var isPrivate = false
    var enabledMediaTypes: Set<String> = []
    var dateFormat = "Y-m-d"
    var timeFormat = "H:i"
    var weekStartDay = "monday"
    var quickWatchDate = "current_date"
    var releaseNotificationsEnabled = true
    var dailyDigestEnabled = true
    var oldPassword = ""
    var newPassword = ""
    var newPasswordConfirm = ""
    var isLoadingOptions = false
    var isSavingProfile = false
    var isSavingAvatar = false
    var isSavingPreferences = false
    var isSavingPassword = false
    var errorMessage: String?
    var successMessage: String?
    var fieldErrors: [String: String] = [:]

    private let profileRepository: ProfileRepository
    private let mediaRepository: MediaRepository
    private let onUnauthorized: () -> Void

    init(profileRepository: ProfileRepository, mediaRepository: MediaRepository, onUnauthorized: @escaping () -> Void) {
        self.profileRepository = profileRepository
        self.mediaRepository = mediaRepository
        self.onUnauthorized = onUnauthorized
    }

    func load(profile: UserProfile?) {
        self.profile = profile
        guard let profile else { return }
        displayName = profile.displayName
        username = profile.username
        bio = profile.bio ?? ""
        pronouns = profile.pronouns ?? ""
        location = profile.location ?? ""
        isPrivate = profile.isPrivate
        enabledMediaTypes = Set(profile.preferences.enabledMediaTypes)
        dateFormat = profile.preferences.dateFormat ?? "Y-m-d"
        timeFormat = profile.preferences.timeFormat ?? "H:i"
        weekStartDay = profile.preferences.weekStartDay ?? "monday"
        quickWatchDate = profile.preferences.quickWatchDate ?? "current_date"
        releaseNotificationsEnabled = profile.preferences.releaseNotificationsEnabled
        dailyDigestEnabled = profile.preferences.dailyDigestEnabled
    }

    func loadOptions() async {
        guard mediaTypes.isEmpty else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }

        do {
            let meta = try await mediaRepository.meta()
            mediaTypes = meta.mediaTypes.filter { $0 != "episode" }
            settingsOptions = meta.settingsOptions ?? settingsOptions
        } catch {
            mediaTypes = Array(Set(APIConstants.fallbackMediaTypes).union(enabledMediaTypes)).sorted()
        }
    }

    var hasProfileChanges: Bool {
        guard let profile else { return false }
        return displayName != profile.displayName
            || username != profile.username
            || bio != (profile.bio ?? "")
            || pronouns != (profile.pronouns ?? "")
            || location != (profile.location ?? "")
            || isPrivate != profile.isPrivate
    }

    var hasPreferenceChanges: Bool {
        guard let profile else { return false }
        let preferences = profile.preferences
        return enabledMediaTypes != Set(preferences.enabledMediaTypes)
            || dateFormat != (preferences.dateFormat ?? "Y-m-d")
            || timeFormat != (preferences.timeFormat ?? "H:i")
            || weekStartDay != (preferences.weekStartDay ?? "monday")
            || quickWatchDate != (preferences.quickWatchDate ?? "current_date")
            || releaseNotificationsEnabled != preferences.releaseNotificationsEnabled
            || dailyDigestEnabled != preferences.dailyDigestEnabled
    }

    @discardableResult
    func saveProfile() async -> UserProfile? {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            fieldErrors = ["username": "Username is required."]
            return nil
        }

        isSavingProfile = true
        clearMessages()
        defer { isSavingProfile = false }

        do {
            let updated = try await profileRepository.updateProfile(ProfileUpdateRequest(
                username: trimmedUsername,
                displayName: displayName,
                bio: bio,
                pronouns: pronouns,
                location: location,
                isPrivate: isPrivate
            ))
            apply(updated, message: "Profile updated.")
            return updated
        } catch {
            handle(error)
            return nil
        }
    }

    @discardableResult
    func saveAvatar(from item: PhotosPickerItem?) async -> UserProfile? {
        guard let item else { return nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
            let type = item.supportedContentTypes.first
            let mimeType = type?.preferredMIMEType ?? "image/jpeg"
            let fileExtension = type?.preferredFilenameExtension ?? "jpg"
            return await uploadAvatar(imageData: data, fileName: "avatar.\(fileExtension)", mimeType: mimeType)
        } catch {
            handle(error)
            return nil
        }
    }

    @discardableResult
    func uploadAvatar(imageData: Data, fileName: String, mimeType: String) async -> UserProfile? {
        isSavingAvatar = true
        clearMessages()
        defer { isSavingAvatar = false }

        do {
            let avatarUrl = try await profileRepository.uploadAvatar(imageData: imageData, fileName: fileName, mimeType: mimeType)
            guard let updated = profile?.replacingAvatarUrl(avatarUrl) else { return nil }
            apply(updated, message: "Photo updated.")
            return updated
        } catch {
            handle(error)
            return nil
        }
    }

    @discardableResult
    func removeAvatar() async -> UserProfile? {
        isSavingAvatar = true
        clearMessages()
        defer { isSavingAvatar = false }

        do {
            let avatarUrl = try await profileRepository.deleteAvatar()
            guard let updated = profile?.replacingAvatarUrl(avatarUrl) else { return nil }
            apply(updated, message: "Photo removed.")
            return updated
        } catch {
            handle(error)
            return nil
        }
    }

    @discardableResult
    func savePreferences() async -> UserProfile? {
        guard !enabledMediaTypes.isEmpty else {
            fieldErrors = ["enabled_media_types": "Enable at least one media type."]
            return nil
        }

        isSavingPreferences = true
        clearMessages()
        defer { isSavingPreferences = false }

        do {
            let preferences = try await profileRepository.updatePreferences(PreferencesUpdateRequest(
                enabledMediaTypes: enabledMediaTypes.sorted(),
                dateFormat: dateFormat,
                timeFormat: timeFormat,
                weekStartDay: weekStartDay,
                quickWatchDate: quickWatchDate,
                releaseNotificationsEnabled: releaseNotificationsEnabled,
                dailyDigestEnabled: dailyDigestEnabled
            ))
            guard let updated = profile?.replacingPreferences(preferences) else { return nil }
            apply(updated, message: "Preferences updated.")
            return updated
        } catch {
            handle(error)
            return nil
        }
    }

    func changePassword() async -> Bool {
        guard newPassword == newPasswordConfirm else {
            fieldErrors = ["new_password_confirm": "Passwords do not match."]
            return false
        }
        guard newPassword.count >= 8 else {
            fieldErrors = ["new_password": "Password must be at least 8 characters."]
            return false
        }

        isSavingPassword = true
        clearMessages()
        defer { isSavingPassword = false }

        do {
            try await profileRepository.changePassword(PasswordChangeRequest(
                oldPassword: oldPassword,
                newPassword: newPassword,
                newPasswordConfirm: newPasswordConfirm
            ))
            oldPassword = ""
            newPassword = ""
            newPasswordConfirm = ""
            successMessage = "Password updated."
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func apply(_ updated: UserProfile, message: String) {
        profile = updated
        load(profile: updated)
        successMessage = message
        NotificationCenter.default.post(name: .profileDidUpdate, object: nil, userInfo: ["profile": updated])
    }

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
        fieldErrors = [:]
    }

    private func handle(_ error: Error) {
        fieldErrors = APIValidationMessages.fieldErrors(from: error)
        errorMessage = fieldErrors.isEmpty ? error.localizedDescription : fieldErrors.values.joined(separator: "\n")
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }
}

enum APIValidationMessages {
    static func fieldErrors(from error: Error) -> [String: String] {
        guard case let APIError.httpStatus(_, body) = error,
              let data = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        if let error = json["error"] as? [String: Any],
           let fields = error["fields"] as? [String: Any] {
            return flatten(fields)
        }
        return flatten(json)
    }

    private static func flatten(_ fields: [String: Any]) -> [String: String] {
        fields.compactMapValues { value in
            if let messages = value as? [String] {
                return messages.first
            }
            if let messages = value as? [Any] {
                return messages.first.map { String(describing: $0) }
            }
            return value as? String
        }
    }
}

private struct ProfileTopSafeAreaInsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: ProfileViewModel
    @State private var selectedRef: MediaRef?
    @State private var isSettingsPresented = false
    @State private var hofPickerSlot: FavoriteSlot?
    @State private var heroCollapseProgress: CGFloat = 0
    @State private var topSafeAreaInset: CGFloat = 0
    @State private var isProfileBackdropSearchPresented = false

    private let profileRepository: ProfileRepository
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let activityRepository: ActivityRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let importCoordinator: LetterboxdImportCoordinator?
    private let storygraphImportCoordinator: StoryGraphImportCoordinator?
    private let goodreadsImportCoordinator: GoodreadsImportCoordinator?
    private let currentUserId: Int?
    private let onLogout: () -> Void
    private let onOpenDiary: () -> Void
    private let onOpenLibrary: (LibraryShelf) -> Void
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void
    private let username: String?
    private let isPushedProfile: Bool

    private var isOwnProfile: Bool {
        username == nil
    }

    init(
        profileRepository: ProfileRepository,
        diaryRepository: DiaryRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        activityRepository: ActivityRepository,
        listRepository: ListRepository,
        importCoordinator: LetterboxdImportCoordinator? = nil,
        storygraphImportCoordinator: StoryGraphImportCoordinator? = nil,
        goodreadsImportCoordinator: GoodreadsImportCoordinator? = nil,
        currentUserId: Int? = nil,
        onLogout: @escaping () -> Void,
        onOpenDiary: @escaping () -> Void,
        onOpenLibrary: @escaping (LibraryShelf) -> Void,
        selectedTab: AppTab = .profile,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        username: String? = nil,
        isPushedProfile: Bool = false,
        onUnauthorized: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: ProfileViewModel(
            profileRepository: profileRepository,
            trackingRepository: trackingRepository,
            activityRepository: activityRepository,
            username: username,
            onUnauthorized: onUnauthorized
        ))
        self.profileRepository = profileRepository
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.activityRepository = activityRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.importCoordinator = importCoordinator
        self.storygraphImportCoordinator = storygraphImportCoordinator
        self.goodreadsImportCoordinator = goodreadsImportCoordinator
        self.currentUserId = currentUserId
        self.onLogout = onLogout
        self.onOpenDiary = onOpenDiary
        self.onOpenLibrary = onOpenLibrary
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        self.username = username
        self.isPushedProfile = isPushedProfile
    }

    var body: some View {
        if isOwnProfile && !isPushedProfile {
            NavigationStack {
                profileScreen
            }
        } else {
            profileScreen
        }
    }

    private var profileScreen: some View {
        profileContent
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                if viewModel.profile == nil {
                    await viewModel.load()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .letterboxdImportDidSucceed)) { _ in
                Swift.Task<Void, Never> { await viewModel.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storygraphImportDidSucceed)) { _ in
                Swift.Task<Void, Never> { await viewModel.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goodreadsImportDidSucceed)) { _ in
                Swift.Task<Void, Never> { await viewModel.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaStateDidChange)) { _ in
                Swift.Task<Void, Never> { await viewModel.reload() }
            }
            .fullScreenCover(item: $selectedRef, onDismiss: { selectedRef = nil }) { ref in
                MediaDetailView(
                    ref: ref,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    diaryRepository: diaryRepository,
                    listRepository: listRepository,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            }
            .sheet(isPresented: $isSettingsPresented) {
                if let importCoordinator, let storygraphImportCoordinator, let goodreadsImportCoordinator {
                    ProfileSettingsSheet(
                        profile: viewModel.profile,
                        profileRepository: profileRepository,
                        mediaRepository: mediaRepository,
                        onProfileUpdated: { updated in
                            viewModel.profile = updated
                            Swift.Task<Void, Never> { await viewModel.reload() }
                        },
                        onUnauthorized: onUnauthorized,
                        importCoordinator: importCoordinator,
                        storygraphImportCoordinator: storygraphImportCoordinator,
                        goodreadsImportCoordinator: goodreadsImportCoordinator,
                        onLogout: onLogout
                    )
                }
            }
            .sheet(item: $hofPickerSlot) { slot in
                HallOfFamePickerSheet(
                    slot: slot,
                    mediaRepository: mediaRepository,
                    isSaving: viewModel.isSavingHallOfFameSlot(slot.id),
                    errorMessage: viewModel.hofErrorMessage,
                    onSelect: { media in
                        await viewModel.setHallOfFameItem(mediaType: slot.id, ref: media.ref)
                    },
                    onClear: clearHallOfFameAction(for: slot),
                    onUnauthorized: onUnauthorized
                )
            }
            .fullScreenCover(isPresented: $isProfileBackdropSearchPresented) {
                ProfileBackdropSearchView(
                    mediaRepository: mediaRepository,
                    profileRepository: profileRepository,
                    currentBackdropURL: viewModel.profile?.profileBackdropUrl,
                    onUnauthorized: onUnauthorized
                ) { response in
                    applyProfileBackdrop(response)
                }
            }
            .alert("Hall of Fame Update Failed", isPresented: hofErrorBinding) {
                Button("OK") {
                    viewModel.hofErrorMessage = nil
                }
            } message: {
                Text(viewModel.hofErrorMessage ?? "")
            }
    }

    private var profileContent: some View {
        ZStack(alignment: .top) {
            SpinePageBackground()

            ScrollView(showsIndicators: false) {
                Group {
                    if viewModel.isLoading, viewModel.profile == nil {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 520)
                    } else if let error = viewModel.errorMessage, viewModel.profile == nil {
                        ContentUnavailableView("Could not load profile", systemImage: "exclamationmark.triangle", description: Text(error))
                            .foregroundStyle(.white)
                            .padding(.top, 120)
                    } else if let profile = viewModel.profile {
                        VStack(alignment: .leading, spacing: 24) {
                            hero(profile, collapseProgress: reduceMotion ? 0 : heroCollapseProgress)
                            if isOwnProfile {
                                inProgressSection
                                    .padding(.horizontal, 16)
                            }
                            activitySection
                                .padding(.horizontal, 16)
                            if isOwnProfile {
                                profileMenuSection(profile.counts)
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.bottom, 100)
                    }
                }
                .spineContentTransition(value: contentPhase)
            }
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable {
                await viewModel.reload()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y)
            } action: { _, offset in
                heroCollapseProgress = ProfileHeroCollapse.progress(for: offset)
            }

            if isPushedProfile {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.34), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .padding(.top, topSafeAreaInset + 6)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if isOwnProfile {
                settingsButton
                    .padding(.top, topSafeAreaInset + 6)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if !isPushedProfile {
                EmptyView()
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ProfileTopSafeAreaInsetKey.self, value: proxy.safeAreaInsets.top)
            }
        }
        .onPreferenceChange(ProfileTopSafeAreaInsetKey.self) { topSafeAreaInset = $0 }
    }

    private func clearHallOfFameAction(for slot: FavoriteSlot) -> (() async -> Bool)? {
        guard slot.item != nil else { return nil }
        return {
            await viewModel.clearHallOfFameItem(mediaType: slot.id)
        }
    }

    private var hofErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.hofErrorMessage != nil && hofPickerSlot == nil },
            set: { if !$0 { viewModel.hofErrorMessage = nil } }
        )
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.34), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private func hero(_ profile: UserProfile, collapseProgress: CGFloat) -> some View {
        let allSlots = favoriteSlots(from: profile)
        let backdropURL = profileBackdropURL(from: profile)
        let musicClearance = HallOfFameCrownLayout.aboveMusicClearance(
            for: allSlots,
            collapseProgress: collapseProgress
        )
        let crownHeight = ProfileHeroBackdropLayout.crownHeight(for: collapseProgress) + musicClearance
        let heroMinHeight = ProfileHeroBackdropLayout.heroMinHeight(for: collapseProgress) + musicClearance
        let crownNameSpacing = ProfileHeroBackdropLayout.crownNameSpacing(for: collapseProgress)
        let backdropContentOffset = backdropURL == nil ? 0 : ProfileHeroBackdropLayout.contentTopOffset

        return ZStack(alignment: .top) {
            if let backdropURL {
                ProfileBackdropArtwork(urlString: backdropURL)
                    .frame(height: topSafeAreaInset + ProfileHeroBackdropLayout.backdropHeight)
                    .onLongPressGesture {
                        guard isOwnProfile else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isProfileBackdropSearchPresented = true
                    }
            }

            VStack(spacing: ProfileHeroBackdropLayout.heroContentSpacing) {
                VStack(spacing: 8) {
                    ZStack(alignment: .top) {
                        HallOfFameCrownView(
                            slots: allSlots,
                            savingSlotIDs: viewModel.savingHallOfFameSlots,
                            collapseProgress: collapseProgress
                        ) { slot in
                            if let item = slot.item {
                                selectedRef = item.ref
                            }
                        } onEmptyTap: { slot in
                            if isOwnProfile {
                                hofPickerSlot = slot
                            }
                        } onFilledLongPress: { slot in
                            if isOwnProfile {
                                hofPickerSlot = slot
                            }
                        }
                        .offset(y: -21 * collapseProgress)
                        .zIndex(0)

                        avatar(profile)
                            .zIndex(1)
                    }
                    .padding(.top, musicClearance)
                    .frame(height: crownHeight)

                    if allSlots.isEmpty {
                        Text("No favorites yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                VStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .shadow(color: .black.opacity(backdropURL == nil ? 0 : 0.32), radius: 12, y: 6)

                    HStack(spacing: 8) {
                        Text("@\(profile.username)")
                        if profile.isPrivate {
                            Label("Private", systemImage: "lock.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .shadow(color: .black.opacity(backdropURL == nil ? 0 : 0.26), radius: 8, y: 4)
                }
                .padding(.top, crownNameSpacing - ProfileHeroBackdropLayout.heroContentSpacing)

                if let bio = profile.bio?.trimmedNonEmpty {
                    Text(bio)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 10)
                        .shadow(color: .black.opacity(backdropURL == nil ? 0 : 0.22), radius: 8, y: 4)
                }

                if let location = profile.location?.trimmedNonEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))
                        .shadow(color: .black.opacity(backdropURL == nil ? 0 : 0.22), radius: 8, y: 4)
                }

                statsGrid(profile.counts)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, backdropURL == nil ? topSafeAreaInset + 28 : topSafeAreaInset + 74 + backdropContentOffset)
            .padding(.bottom, backdropURL == nil ? 12 : 22)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: backdropURL == nil ? nil : topSafeAreaInset + heroMinHeight + backdropContentOffset, alignment: .top)
    }

    private func profileBackdropURL(from profile: UserProfile) -> String? {
        if let profileBackdropUrl = profile.profileBackdropUrl?.trimmedNonEmpty {
            return profileBackdropUrl
        }
        guard let movie = profile.hof["movie"] ?? nil else { return nil }
        return movie.displayBackdropURL
    }

    private func applyProfileBackdrop(_ response: ProfileBackdropSaveResponse) {
        guard let updated = viewModel.profile?.replacingProfileBackdrop(response) else { return }
        viewModel.profile = updated
    }

    private func avatar(_ profile: UserProfile) -> some View {
        SpineAsyncImage(url: URL(string: profile.avatarUrl ?? "")) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.white.opacity(0.36))
                    .padding(10)
            }
        }
        .frame(width: 128, height: 128)
        .background(.white.opacity(0.08), in: Circle())
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.44), radius: 22, y: 12)
        .accessibilityLabel(profile.displayName)
    }

    private struct ProfileBackdropArtwork: View {
        let urlString: String

        var body: some View {
            GeometryReader { proxy in
                ZStack {
                    SpineAsyncImage(url: URL(string: urlString)) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        default:
                            Color.clear
                        }
                    }

                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.42), location: 0),
                            .init(color: .black.opacity(0.18), location: 0.36),
                            .init(color: .clear, location: 0.72),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.52),
                            .init(color: .white.opacity(0.35), location: 0.78),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .clipped()
        }
    }

    private enum ProfileHeroBackdropLayout {
        static let backdropHeight: CGFloat = 352.34375
        static let contentTopOffset: CGFloat = 44
        static let heroContentSpacing: CGFloat = 12

        static func crownHeight(for collapseProgress: CGFloat) -> CGFloat {
            286 - 178 * collapseProgress
        }

        static func crownNameSpacing(for collapseProgress: CGFloat) -> CGFloat {
            14 - 26 * collapseProgress
        }

        static func heroMinHeight(for collapseProgress: CGFloat) -> CGFloat {
            520 - 156 * collapseProgress
        }
    }

    private func statsGrid(_ counts: ProfileCounts) -> some View {
        GlassEffectContainer(spacing: 3.5) {
            HStack(spacing: 7) {
                if isOwnProfile {
                    Button(action: onOpenDiary) {
                        ProfileStatChip(
                            value: counts.diaryEntries,
                            title: "Logs",
                            systemName: "calendar",
                            isInteractive: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.logs")
                    .accessibilityHint("Opens Diary")
                } else {
                    ProfileStatChip(value: counts.diaryEntries, title: "Logs", systemName: "calendar")
                }

                ProfileStatChip(value: counts.followers, title: "Followers", systemName: "person.2")
                ProfileStatChip(value: counts.following, title: "Following", systemName: "person.crop.circle.badge.checkmark")

                if isOwnProfile {
                    NavigationLink {
                        ProfileListsView(
                            profileRepository: profileRepository,
                            listRepository: listRepository,
                            mediaRepository: mediaRepository,
                            trackingRepository: trackingRepository,
                            diaryRepository: diaryRepository,
                            activityRepository: activityRepository,
                            importCoordinator: importCoordinator,
                            storygraphImportCoordinator: storygraphImportCoordinator,
                            goodreadsImportCoordinator: goodreadsImportCoordinator,
                            currentUserId: currentUserId ?? viewModel.profile?.id,
                            onLogout: onLogout,
                            onOpenDiary: onOpenDiary,
                            onOpenLibrary: onOpenLibrary,
                            selectedTab: selectedTab,
                            onSelectTab: onSelectTab,
                            onUnauthorized: onUnauthorized
                        )
                    } label: {
                        ProfileStatChip(
                            value: counts.lists,
                            title: "Lists",
                            systemName: "list.bullet.rectangle",
                            isInteractive: true
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ProfileStatChip(value: counts.lists, title: "Lists", systemName: "list.bullet.rectangle")
                }
            }
        }
    }

    private var activitySection: some View {
        ProfileSection(title: "Recent Activity") {
            Group {
                if viewModel.isLoadingActivity, viewModel.recentActivityItems.isEmpty {
                    ProfileRailLoadingView()
                } else if let activityError = viewModel.activityErrorMessage, viewModel.recentActivityItems.isEmpty {
                    EmptyProfileCard(title: activityError, systemName: "exclamationmark.triangle")
                } else if ProfileRecentActivityRailModel.items(from: viewModel.recentActivityItems).isEmpty {
                    EmptyProfileCard(title: "No activity yet", systemName: "bolt")
                } else {
                    RecentActivityRail(items: viewModel.recentActivityItems) { item in
                        selectedRef = item.media.ref
                    }
                }
            }
            .spineContentTransition(value: activityPhase)
        }
    }

    private func profileMenuSection(_ counts: ProfileCounts) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(ProfileMenuDestination.allCases.enumerated()), id: \.element) { index, destination in
                profileMenuLink(
                    destination,
                    count: destination.count(from: counts),
                    showsDivider: index != ProfileMenuDestination.allCases.count - 1
                )
            }
        }
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func profileMenuLink(_ destination: ProfileMenuDestination, count: Int?, showsDivider: Bool) -> some View {
        switch destination {
        case .library:
            Button {
                onOpenLibrary(.tracked)
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .diary:
            Button {
                onOpenDiary()
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .stats:
            NavigationLink {
                StatsView(
                    profileRepository: profileRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    diaryRepository: diaryRepository,
                    listRepository: listRepository,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            } label: {
                ProfileMenuRow(title: destination.title, count: nil, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .reviews:
            NavigationLink {
                ProfileReviewsView(
                    diaryRepository: diaryRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .lists:
            NavigationLink {
                ProfileListsView(
                    profileRepository: profileRepository,
                    listRepository: listRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    diaryRepository: diaryRepository,
                    activityRepository: activityRepository,
                    importCoordinator: importCoordinator,
                    storygraphImportCoordinator: storygraphImportCoordinator,
                    goodreadsImportCoordinator: goodreadsImportCoordinator,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    onLogout: onLogout,
                    onOpenDiary: onOpenDiary,
                    onOpenLibrary: onOpenLibrary,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .planned:
            Button {
                onOpenLibrary(.planning)
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .likes:
            NavigationLink {
                ProfileLikesView(
                    profileRepository: profileRepository,
                    diaryRepository: diaryRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        case .tags:
            NavigationLink {
                ProfileTagsView(
                    diaryRepository: diaryRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    currentUserId: currentUserId ?? viewModel.profile?.id,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            } label: {
                ProfileMenuRow(title: destination.title, count: count, showsDivider: showsDivider)
            }
            .buttonStyle(.plain)
        }
    }

    private var inProgressSection: some View {
        ProfileSection(title: "In Progress") {
            Group {
                if viewModel.isLoadingInProgress, viewModel.inProgressItems.isEmpty {
                    ProfileRailLoadingView()
                } else if let inProgressError = viewModel.inProgressErrorMessage, viewModel.inProgressItems.isEmpty {
                    EmptyProfileCard(title: inProgressError, systemName: "exclamationmark.triangle")
                } else if viewModel.inProgressItems.isEmpty {
                    EmptyProfileCard(title: "Nothing in progress yet", systemName: "play.circle")
                } else {
                    InProgressRail(items: viewModel.inProgressItems) { item in
                        selectedRef = item.media.ref
                    }
                }
            }
            .spineContentTransition(value: inProgressPhase)
        }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: viewModel.profile != nil,
            hasError: viewModel.errorMessage != nil
        )
    }

    private var activityPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoadingActivity,
            hasContent: !viewModel.recentActivityItems.isEmpty,
            hasError: viewModel.activityErrorMessage != nil
        )
    }

    private var inProgressPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoadingInProgress,
            hasContent: !viewModel.inProgressItems.isEmpty,
            hasError: viewModel.inProgressErrorMessage != nil
        )
    }

    private func favoriteSlots(from profile: UserProfile) -> [FavoriteSlot] {
        ProfileFavorites.slots(from: profile.hof, enabledMediaTypes: profile.preferences.enabledMediaTypes)
    }

    private func favoriteSlotRank(_ key: String) -> Int {
        ProfileFavorites.rank(key)
    }
}

struct ProfileFavorites {
    private static let defaultSlotKeys = ["movie", "tv", "anime", "manga", "game", "book", "comic", "music"]

    static func slots(from hof: [String: MediaSummary?], enabledMediaTypes: [String] = []) -> [FavoriteSlot] {
        let enabled = enabledMediaTypes.filter { defaultSlotKeys.contains($0) }
        let keys = enabled.isEmpty ? defaultSlotKeys : enabled
        return keys.sorted { lhs, rhs in
            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            return leftRank == rightRank ? lhs < rhs : leftRank < rightRank
        }.map { key in
            FavoriteSlot(id: key, title: key.profileSlotTitle, item: hof[key] ?? nil)
        }
    }

    static func rank(_ key: String) -> Int {
        let normalized = key.lowercased()
        let order = ["movie", "tv", "anime", "manga", "game", "book", "comic", "music", "boardgame"]
        return order.firstIndex { normalized.contains($0) } ?? order.count
    }
}

struct FavoriteSlot: Identifiable {
    let id: String
    let title: String
    let item: MediaSummary?
}

enum ProfileHeroCollapse {
    static let scrollDistance: CGFloat = 100

    static func progress(for scrollOffset: CGFloat) -> CGFloat {
        min(1, max(0, scrollOffset / scrollDistance))
    }
}

@MainActor
@Observable
private final class HallOfFamePickerViewModel {
    var query = ""
    var results: [MediaSummary] = []
    var isLoading = false
    var errorMessage: String?
    var resultRevision = 0

    private let mediaRepository: MediaRepository
    private let onUnauthorized: () -> Void
    private var requestGeneration = 0

    init(mediaRepository: MediaRepository, onUnauthorized: @escaping () -> Void) {
        self.mediaRepository = mediaRepository
        self.onUnauthorized = onUnauthorized
    }

    func invalidateSearch() {
        requestGeneration += 1
        isLoading = false
    }

    func search(mediaType: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        requestGeneration += 1
        let generation = requestGeneration
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let found = try await mediaRepository.search(query: trimmed, mediaType: mediaType)
            guard generation == requestGeneration,
                  trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = found
            resultRevision += 1
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            results = []
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }
}

private struct HallOfFamePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: HallOfFamePickerViewModel
    @State private var savingMediaID: String?
    @State private var isClearing = false

    let slot: FavoriteSlot
    let isSaving: Bool
    let errorMessage: String?
    let onSelect: (MediaSummary) async -> Bool
    let onClear: (() async -> Bool)?

    init(
        slot: FavoriteSlot,
        mediaRepository: MediaRepository,
        isSaving: Bool,
        errorMessage: String?,
        onSelect: @escaping (MediaSummary) async -> Bool,
        onClear: (() async -> Bool)?,
        onUnauthorized: @escaping () -> Void
    ) {
        self.slot = slot
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSelect = onSelect
        self.onClear = onClear
        _viewModel = State(initialValue: HallOfFamePickerViewModel(mediaRepository: mediaRepository, onUnauthorized: onUnauthorized))
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if let current = slot.item {
                    Section("Current") {
                        HallOfFamePickerRow(media: current)
                        if onClear != nil {
                            Button(role: .destructive) {
                                Swift.Task<Void, Never> { await clear() }
                            } label: {
                                if isClearing {
                                    Label("Removing", systemImage: "clock")
                                } else {
                                    Label("Remove Favorite", systemImage: "trash")
                                }
                            }
                            .disabled(isSaving || isClearing)
                        }
                    }
                }

                Section("Results") {
                    if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Search \(slot.title)", systemImage: "magnifyingglass")
                            .listRowBackground(Color.clear)
                    } else if !viewModel.results.isEmpty {
                        ForEach(viewModel.results) { media in
                            Button {
                                Swift.Task<Void, Never> { await select(media) }
                            } label: {
                                HStack(spacing: 10) {
                                    HallOfFamePickerRow(media: media)
                                    if savingMediaID == media.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving || savingMediaID != nil)
                        }
                    } else if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else if viewModel.results.isEmpty {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                            .listRowBackground(Color.clear)
                    }
                }
                .spineContentTransition(value: resultsTransitionKey)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("\(slot.title) Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(slot.title)")
            .task(id: viewModel.query) {
                viewModel.invalidateSearch()
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await viewModel.search(mediaType: slot.id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var resultsPhase: SpineContentPhase {
        let hasQuery = !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return .resolve(
            isLoading: hasQuery && viewModel.isLoading,
            hasContent: hasQuery && !viewModel.results.isEmpty,
            hasError: hasQuery && viewModel.errorMessage != nil
        )
    }

    private var resultsTransitionKey: ResultsTransitionKey {
        ResultsTransitionKey(phase: resultsPhase, revision: viewModel.resultRevision)
    }

    private struct ResultsTransitionKey: Hashable {
        let phase: SpineContentPhase
        let revision: Int
    }

    private func select(_ media: MediaSummary) async {
        savingMediaID = media.id
        let didSave = await onSelect(media)
        savingMediaID = nil
        if didSave {
            dismiss()
        }
    }

    private func clear() async {
        guard let onClear else { return }
        isClearing = true
        let didClear = await onClear()
        isClearing = false
        if didClear {
            dismiss()
        }
    }
}

private struct HallOfFamePickerRow: View {
    let media: MediaSummary

    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(
                url: media.displayPosterURL,
                title: media.title,
                slot: .searchRow,
                mediaType: media.ref.mediaType,
                orientation: media.posterOrientation
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle = media.searchResultSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

}

private struct ProfileStatChip: View {
    private static let cornerRadius: CGFloat = 10.5

    let value: Int
    let title: String
    let systemName: String
    var isInteractive = false

    var body: some View {
        glassSurface
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 3.5, y: 1.75)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(value.formatted()) \(title)")
    }

    @ViewBuilder
    private var glassSurface: some View {
        if isInteractive {
            content
                .glassEffect(
                    .regular.tint(.white.opacity(0.06)).interactive(),
                    in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                )
        } else {
            content
                .glassEffect(
                    .regular.tint(.white.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                )
        }
    }

    private var content: some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 3.5) {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.56))

                Text(value.formatted())
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .contentTransition(.numericText())
            }

            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 67, height: 50)
        .background(
            .white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
    }
}

enum ProfileMenuDestination: CaseIterable, Hashable {
    case library
    case diary
    case reviews
    case lists
    case planned
    case likes
    case tags
    case stats

    var title: String {
        switch self {
        case .library: "Library"
        case .diary: "Diary"
        case .stats: "Stats"
        case .reviews: "Reviews"
        case .lists: "Lists"
        case .planned: "Planned"
        case .likes: "Likes"
        case .tags: "Tags"
        }
    }

    func count(from counts: ProfileCounts) -> Int? {
        switch self {
        case .library: counts.libraryItems
        case .diary: counts.diaryEntries
        case .stats: nil
        case .reviews: counts.reviews
        case .lists: counts.lists
        case .planned: counts.plannedItems
        case .likes: counts.likedItems
        case .tags: counts.tags
        }
    }
}

struct ProfileMenuRow: View {
    let title: String
    let count: Int?
    var showsDivider = true

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 12)

            if let count {
                Text(count.formatted())
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.26))
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

private struct ProfileSection<Content: View>: View {
    let title: String
    let action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        action: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let action {
                    Button(action: action) {
                        HStack(spacing: 5) {
                            sectionTitle
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                } else {
                    sectionTitle
                }
                Spacer()
            }

            content()
        }
    }

    private var sectionTitle: some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(.white.opacity(0.58))
            .tracking(0.8)
    }
}

struct ProfileRecentActivityRailItem: Identifiable {
    let activity: ActivityItem
    let media: MediaSummary

    var id: Int { activity.id }
}

enum ProfileRecentActivityRailModel {
    static func items(from activities: [ActivityItem]) -> [ProfileRecentActivityRailItem] {
        activities.compactMap { activity in
            guard let media = activity.media else { return nil }
            return ProfileRecentActivityRailItem(activity: activity, media: media)
        }
    }

    static func progressDeltaText(for activity: ActivityItem, media: MediaSummary) -> String? {
        guard
            activity.type == "progress_updated",
            let previous = activity.object.previous,
            let current = activity.object.current
        else {
            return nil
        }

        return ProgressChangeState(
            id: activity.object.id,
            previous: previous,
            current: current,
            createdAt: activity.createdAt
        )
        .compactDeltaText(preferredMode: ProgressDisplayPreferences.mode(for: media.ref))
    }

    static func rating(for activity: ActivityItem) -> String? {
        clean(activity.object.rating)
    }

    static func isLikedDiary(_ activity: ActivityItem) -> Bool {
        isDiary(activity) && activity.object.liked == true
    }

    static func fallbackLabel(for activity: ActivityItem) -> String? {
        switch activity.type {
        case "list_created":
            clean(activity.object.name)
        case "list_item_added":
            clean(activity.object.name) ?? "List"
        default:
            nil
        }
    }

    static func isDiary(_ activity: ActivityItem) -> Bool {
        activity.type == "diary_created" || activity.type == "diary_updated"
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct RecentActivityRail: View {
    let items: [ActivityItem]
    let action: (ProfileRecentActivityRailItem) -> Void

    private var visibleItems: [ProfileRecentActivityRailItem] {
        ProfileRecentActivityRailModel.items(from: items)
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = PosterSlot.profileRail.size.width
            let minimumSpacing: CGFloat = 4
            let maximumVisibleCount = min(6, visibleItems.count)
            let visibleCount = max(1, min(maximumVisibleCount, Int((proxy.size.width + minimumSpacing) / (itemWidth + minimumSpacing))))
            let spacing = visibleCount > 1
                ? min(10, max(minimumSpacing, (proxy.size.width - itemWidth * CGFloat(visibleCount)) / CGFloat(visibleCount - 1)))
                : 0
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(visibleItems.prefix(visibleCount))) { item in
                    RecentActivityPoster(item: item) {
                        action(item)
                    }
                    .frame(width: itemWidth)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 125)
    }
}

private struct InProgressRail: View {
    let items: [LibraryItem]
    let action: (LibraryItem) -> Void

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let itemWidth = PosterSlot.profileRail.size.width
            let visibleCount = max(3, min(5, Int((proxy.size.width + spacing) / (itemWidth + spacing))))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(items.prefix(visibleCount))) { item in
                    InProgressPoster(item: item) {
                        action(item)
                    }
                    .frame(width: itemWidth)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 125)
    }
}

private struct InProgressPoster: View {
    let item: LibraryItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MediaArtwork(
                url: item.media.displayPosterURL,
                title: item.media.title,
                slot: .profileRail,
                mediaType: item.media.ref.mediaType,
                orientation: item.media.posterOrientation
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(item.media.title)")
    }
}

private struct ProfileRailLoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: PosterSlot.profileRail.size.width, height: PosterSlot.profileRail.size.height)
            }
            Spacer(minLength: 0)
        }
        .redacted(reason: .placeholder)
    }
}

private struct RecentActivityPoster: View {
    let item: ProfileRecentActivityRailItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                MediaArtwork(
                    url: item.media.displayPosterURL,
                    title: item.media.title,
                    slot: .profileRail,
                    mediaType: item.media.ref.mediaType,
                    orientation: item.media.posterOrientation
                )

                metadataLine
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(item.media.title)")
    }

    @ViewBuilder
    private var metadataLine: some View {
        if let progressDeltaText = ProfileRecentActivityRailModel.progressDeltaText(for: item.activity, media: item.media) {
            Text(progressDeltaText)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: PosterSlot.profileRail.size.width, height: 12.5, alignment: .leading)
        } else if ProfileRecentActivityRailModel.isDiary(item.activity),
                  ProfileRecentActivityRailModel.rating(for: item.activity) != nil || ProfileRecentActivityRailModel.isLikedDiary(item.activity) {
            HStack(spacing: 5) {
                if let rating = ProfileRecentActivityRailModel.rating(for: item.activity) {
                    ProfileStarRating(
                        rating: rating,
                        reservesWidth: !ProfileRecentActivityRailModel.isLikedDiary(item.activity),
                        mediaType: item.activity.media?.ref.mediaType
                    )
                }

                if ProfileRecentActivityRailModel.isLikedDiary(item.activity) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11.25, weight: .bold))
                        .foregroundStyle(.pink)
                        .accessibilityLabel("Liked")
                }
            }
            .frame(width: PosterSlot.profileRail.size.width, height: 12.5, alignment: .leading)
        } else if let label = ProfileRecentActivityRailModel.fallbackLabel(for: item.activity) {
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: PosterSlot.profileRail.size.width, height: 12.5, alignment: .leading)
        }
    }
}

private struct ProfileStarRating: View {
    let rating: String?
    var reservesWidth = true
    var mediaType: String?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(symbolNames.enumerated()), id: \.offset) { _, symbolName in
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.92))
            }
        }
        .frame(width: reservesWidth ? PosterSlot.profileRail.size.width : nil, height: 12.5, alignment: .leading)
        .accessibilityHidden(value == nil)
        .accessibilityLabel(value.map { "Rating \($0) out of 5 stars" } ?? "")
    }

    private var value: Double? {
        guard let rating, let raw = Double(rating) else { return nil }
        return ["movie", "music", "book"].contains(mediaType) ? raw : raw / 2
    }

    private var symbolNames: [String] {
        guard let value else { return [] }
        let fullStars = Int(value.rounded(.down))
        let hasHalfStar = value - Double(fullStars) >= 0.5
        return Array(repeating: "star.fill", count: fullStars)
            + (hasHalfStar ? ["star.leadinghalf.filled"] : [])
    }
}

private struct EmptyProfileCard: View {
    let title: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
        }
        .foregroundStyle(.white.opacity(0.48))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum ImportStatusSource: Hashable, Identifiable {
    case letterboxd
    case storygraph
    case goodreads

    var id: Self { self }
}

private struct ProfileSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ProfileSettingsViewModel
    @State private var importStatusSource: ImportStatusSource?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isProfileBackdropSearchPresented = false

    let profile: UserProfile?
    let onProfileUpdated: (UserProfile) -> Void
    let importCoordinator: LetterboxdImportCoordinator
    let storygraphImportCoordinator: StoryGraphImportCoordinator
    let goodreadsImportCoordinator: GoodreadsImportCoordinator
    let onLogout: () -> Void
    private let profileRepository: ProfileRepository
    private let mediaRepository: MediaRepository
    private let onUnauthorized: () -> Void

    init(
        profile: UserProfile?,
        profileRepository: ProfileRepository,
        mediaRepository: MediaRepository,
        onProfileUpdated: @escaping (UserProfile) -> Void,
        onUnauthorized: @escaping () -> Void,
        importCoordinator: LetterboxdImportCoordinator,
        storygraphImportCoordinator: StoryGraphImportCoordinator,
        goodreadsImportCoordinator: GoodreadsImportCoordinator,
        onLogout: @escaping () -> Void
    ) {
        self.profile = profile
        self.onProfileUpdated = onProfileUpdated
        self.importCoordinator = importCoordinator
        self.storygraphImportCoordinator = storygraphImportCoordinator
        self.goodreadsImportCoordinator = goodreadsImportCoordinator
        self.onLogout = onLogout
        self.profileRepository = profileRepository
        self.mediaRepository = mediaRepository
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: ProfileSettingsViewModel(
            profileRepository: profileRepository,
            mediaRepository: mediaRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                if let profile {
                    accountSection(profile)
                    profileSaveSection
                    enabledMediaSection
                }

                Section("Import") {
                    importSectionContent
                }

                Section("App") {
                    LabeledContent("API Base URL", value: AppConfig.apiBaseURL.absoluteString)
                    LabeledContent("API Prefix", value: AppConfig.apiPrefix)
                }

                Section("Data Sources") {
                    Link("Music metadata provided by MusicBrainz", destination: URL(string: "https://musicbrainz.org/")!)
                    Link("Cover art provided by the Cover Art Archive", destination: URL(string: "https://coverartarchive.org/")!)
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        onLogout()
                    } label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.load(profile: profile)
                await viewModel.loadOptions()
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Swift.Task<Void, Never> {
                    if let updated = await viewModel.saveAvatar(from: newItem) {
                        onProfileUpdated(updated)
                    }
                    selectedPhotoItem = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(item: $importStatusSource) { source in
                switch source {
                case .letterboxd:
                    LetterboxdImportUploadView(
                        coordinator: importCoordinator,
                        onDone: { importStatusSource = nil }
                    )
                case .storygraph:
                    StoryGraphImportUploadView(
                        coordinator: storygraphImportCoordinator,
                        onDone: { importStatusSource = nil }
                    )
                case .goodreads:
                    GoodreadsImportUploadView(
                        coordinator: goodreadsImportCoordinator,
                        onDone: { importStatusSource = nil }
                    )
                }
            }
            .fullScreenCover(isPresented: $isProfileBackdropSearchPresented) {
                ProfileBackdropSearchView(
                    mediaRepository: mediaRepository,
                    profileRepository: profileRepository,
                    currentBackdropURL: viewModel.profile?.profileBackdropUrl ?? profile?.profileBackdropUrl,
                    onUnauthorized: onUnauthorized
                ) { response in
                    applyProfileBackdrop(response)
                }
            }
        }
    }

    private func accountSection(_ profile: UserProfile) -> some View {
        let isSavingAvatar = viewModel.isSavingAvatar
        let avatarUrl = viewModel.profile?.avatarUrl ?? profile.avatarUrl

        return Section("Account") {
            HStack(spacing: 14) {
                SpineAsyncImage(url: URL(string: avatarUrl ?? "")) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                            .padding(5)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .background(.secondary.opacity(0.12), in: Circle())

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label(isSavingAvatar ? "Uploading" : "Change Photo", systemImage: "photo")
                }
                .disabled(isSavingAvatar)

                Spacer()

            if avatarUrl != nil {
                Button("Remove", role: .destructive) {
                    Swift.Task<Void, Never> {
                            if let updated = await viewModel.removeAvatar() {
                                onProfileUpdated(updated)
                            }
                        }
                    }
                    .disabled(isSavingAvatar)
                }
            }

            Button {
                isProfileBackdropSearchPresented = true
            } label: {
                Label("Choose Profile Backdrop", systemImage: "photo.on.rectangle")
            }

            if (viewModel.profile?.profileBackdropUrl ?? profile.profileBackdropUrl) != nil {
                Button("Remove Profile Backdrop", role: .destructive) {
                    Swift.Task<Void, Never> {
                        do {
                            let response = try await profileRepository.clearProfileBackdrop()
                            applyProfileBackdrop(response)
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
            }

            editableField("Display Name", text: $viewModel.displayName)
            fieldError("display_name", "displayName")

            editableField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            fieldError("username")

            if let email = profile.email?.trimmedNonEmpty {
                LabeledContent("Email", value: email)
            }

            editableField("Bio", text: $viewModel.bio, axis: .vertical)
                .lineLimit(3...5)
            fieldError("bio")

            Toggle("Private account", isOn: $viewModel.isPrivate)
            fieldError("is_private", "profile_private")
        }
    }

    private func applyProfileBackdrop(_ response: ProfileBackdropSaveResponse) {
        guard let base = viewModel.profile ?? profile else { return }
        let updated = base.replacingProfileBackdrop(response)
        viewModel.load(profile: updated)
        onProfileUpdated(updated)
    }

    private var profileSaveSection: some View {
        Section {
            saveButton("Save Changes", isSaving: viewModel.isSavingProfile, isDisabled: !viewModel.hasProfileChanges) {
                if let updated = await viewModel.saveProfile() {
                    onProfileUpdated(updated)
                    dismiss()
                }
            }

            statusMessages
        }
    }

    private var enabledMediaSection: some View {
        Section("Enabled Media") {
            if viewModel.isLoadingOptions {
                ProgressView()
            } else {
                ForEach(viewModel.mediaTypes, id: \.self) { mediaType in
                    Toggle(
                        MediaTypeTheme.theme(for: mediaType).displayName,
                        isOn: enabledMediaBinding(mediaType)
                    )
                }
            }

            fieldError("enabled_media_types")

            saveButton(
                "Save Enabled Media",
                isSaving: viewModel.isSavingPreferences,
                isDisabled: !viewModel.hasPreferenceChanges
            ) {
                if let updated = await viewModel.savePreferences() {
                    onProfileUpdated(updated)
                }
            }
        }
    }

    private func enabledMediaBinding(_ mediaType: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.enabledMediaTypes.contains(mediaType) },
            set: { isEnabled in
                if isEnabled {
                    viewModel.enabledMediaTypes.insert(mediaType)
                } else {
                    viewModel.enabledMediaTypes.remove(mediaType)
                }
            }
        )
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let error = viewModel.errorMessage?.trimmedNonEmpty {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if let success = viewModel.successMessage?.trimmedNonEmpty {
            Label(success, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        }
    }

    private func saveButton(_ title: String, isSaving: Bool, isDisabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Swift.Task<Void, Never> { await action() }
        } label: {
            HStack {
                Group {
                    if isSaving {
                        Text("Saving...")
                        Spacer()
                        ProgressView()
                    } else {
                        Text(title)
                    }
                }
                .spineContentTransition(value: isSaving)
            }
        }
        .disabled(isDisabled || isSaving)
    }

    private func editableField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis)
        }
    }

    @ViewBuilder
    private func fieldError(_ keys: String...) -> some View {
        if let message = keys.lazy.compactMap({ viewModel.fieldErrors[$0] }).first {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var importSectionContent: some View {
        if importCoordinator.phase == .idle &&
            storygraphImportCoordinator.phase == .idle &&
            goodreadsImportCoordinator.phase == .idle {
            NavigationLink {
                LetterboxdImportView(coordinator: importCoordinator)
            } label: {
                Label("Import from Letterboxd", systemImage: "square.and.arrow.down")
            }
            NavigationLink {
                StoryGraphImportView(coordinator: storygraphImportCoordinator)
            } label: {
                Label("Import from StoryGraph", systemImage: "doc.text")
            }
            NavigationLink {
                GoodreadsImportView(coordinator: goodreadsImportCoordinator)
            } label: {
                Label("Import from Goodreads", systemImage: "doc.text")
            }
        } else if importCoordinator.phase != .idle {
            letterboxdImportStatus
        } else if storygraphImportCoordinator.phase != .idle {
            storygraphImportStatus
        } else {
            goodreadsImportStatus
        }
    }

    @ViewBuilder
    private var letterboxdImportStatus: some View {
        switch importCoordinator.phase {
        case .idle:
            EmptyView()
        case let .uploading(_, progress):
            Button {
                importStatusSource = .letterboxd
            } label: {
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uploading...")
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .processing(_, statusLabel, _):
            Button {
                importStatusSource = .letterboxd
            } label: {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusLabel)
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            letterboxdCheckStatusButton
        case let .succeeded(message):
            importResultRow(systemName: "checkmark.circle.fill", tint: .green, message: message)
            Button("Dismiss") {
                importCoordinator.clearFinishedJob()
            }
        case let .failed(message):
            importResultRow(systemName: "exclamationmark.triangle.fill", tint: .red, message: message)
            if importCoordinator.canCheckStatus {
                letterboxdCheckStatusButton
            }
            NavigationLink {
                LetterboxdImportView(coordinator: importCoordinator)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            Button("Dismiss") {
                importCoordinator.clearFinishedJob()
            }
        }
    }

    @ViewBuilder
    private var storygraphImportStatus: some View {
        switch storygraphImportCoordinator.phase {
        case .idle:
            EmptyView()
        case let .uploading(_, progress):
            Button {
                importStatusSource = .storygraph
            } label: {
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uploading...")
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .processing(_, statusLabel, _):
            Button {
                importStatusSource = .storygraph
            } label: {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusLabel)
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            storygraphCheckStatusButton
        case let .succeeded(message):
            importResultRow(systemName: "checkmark.circle.fill", tint: .green, message: message)
            Button("Dismiss") {
                storygraphImportCoordinator.clearFinishedJob()
            }
        case let .failed(message):
            importResultRow(systemName: "exclamationmark.triangle.fill", tint: .red, message: message)
            if storygraphImportCoordinator.canCheckStatus {
                storygraphCheckStatusButton
            }
            NavigationLink {
                StoryGraphImportView(coordinator: storygraphImportCoordinator)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            Button("Dismiss") {
                storygraphImportCoordinator.clearFinishedJob()
            }
        }
    }

    @ViewBuilder
    private var goodreadsImportStatus: some View {
        switch goodreadsImportCoordinator.phase {
        case .idle:
            EmptyView()
        case let .uploading(_, progress):
            Button {
                importStatusSource = .goodreads
            } label: {
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uploading...")
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .processing(_, statusLabel, _):
            Button {
                importStatusSource = .goodreads
            } label: {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusLabel)
                        Text("Tap for details")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            goodreadsCheckStatusButton
        case let .succeeded(message):
            importResultRow(systemName: "checkmark.circle.fill", tint: .green, message: message)
            Button("Dismiss") {
                goodreadsImportCoordinator.clearFinishedJob()
            }
        case let .failed(message):
            importResultRow(systemName: "exclamationmark.triangle.fill", tint: .red, message: message)
            if goodreadsImportCoordinator.canCheckStatus {
                goodreadsCheckStatusButton
            }
            NavigationLink {
                GoodreadsImportView(coordinator: goodreadsImportCoordinator)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            Button("Dismiss") {
                goodreadsImportCoordinator.clearFinishedJob()
            }
        }
    }

    private var letterboxdCheckStatusButton: some View {
        Button {
            importCoordinator.checkStatusOnce()
        } label: {
            if importCoordinator.isCheckingStatus {
                Label("Checking Status", systemImage: "clock.arrow.circlepath")
            } else {
                Label("Check Status", systemImage: "arrow.clockwise")
            }
        }
        .disabled(importCoordinator.isCheckingStatus)
    }

    private var storygraphCheckStatusButton: some View {
        Button {
            storygraphImportCoordinator.checkStatusOnce()
        } label: {
            if storygraphImportCoordinator.isCheckingStatus {
                Label("Checking Status", systemImage: "clock.arrow.circlepath")
            } else {
                Label("Check Status", systemImage: "arrow.clockwise")
            }
        }
        .disabled(storygraphImportCoordinator.isCheckingStatus)
    }

    private var goodreadsCheckStatusButton: some View {
        Button {
            goodreadsImportCoordinator.checkStatusOnce()
        } label: {
            if goodreadsImportCoordinator.isCheckingStatus {
                Label("Checking Status", systemImage: "clock.arrow.circlepath")
            } else {
                Label("Check Status", systemImage: "arrow.clockwise")
            }
        }
        .disabled(goodreadsImportCoordinator.isCheckingStatus)
    }

    private func importResultRow(systemName: String, tint: Color, message: String) -> some View {
        Label {
            Text(message)
                .lineLimit(2)
        } icon: {
            Image(systemName: systemName)
                .foregroundStyle(tint)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var profileSlotTitle: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
