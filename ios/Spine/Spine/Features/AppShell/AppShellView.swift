import SwiftUI

struct AppShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab
    @State private var searchFocusRequest = 0
    @State private var requestedLibraryShelf: LibraryShelf?
    @State private var mediaLensStore = MediaLensStore()

    let session: AppSession

    @MainActor
    init(session: AppSession) {
        self.session = session
        _selectedTab = State(initialValue: session.signedInEntryPoint == .search ? .search : .home)
    }

    private var currentUserId: Int? {
        if case let .signedIn(user) = session.state {
            return user?.id
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                profileRepository: session.repositories.profile,
                mediaRepository: session.repositories.media,
                trackingRepository: session.repositories.tracking,
                diaryRepository: session.repositories.diary,
                activityRepository: session.repositories.activity,
                listRepository: session.repositories.lists,
                currentUserId: currentUserId,
                selectedTab: selectedTab,
                onSelectTab: { selectedTab = $0 },
                onUnauthorized: unauthorized
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .tabItem {
                Image(systemName: "house")
                    .accessibilityLabel("Home")
            }
            .tag(AppTab.home)

            LazyTab(isSelected: selectedTab == .search) {
                SearchView(
                    mediaRepository: session.repositories.media,
                    trackingRepository: session.repositories.tracking,
                    diaryRepository: session.repositories.diary,
                    listRepository: session.repositories.lists,
                    mediaLensStore: mediaLensStore,
                    currentUserId: currentUserId,
                    selectedTab: selectedTab,
                    focusRequest: searchFocusRequest,
                    onSelectTab: { selectedTab = $0 },
                    onUnauthorized: unauthorized
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .tabItem {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Search")
            }
            .tag(AppTab.search)

            LazyTab(isSelected: selectedTab == .library) {
                LibraryView(
                    mediaRepository: session.repositories.media,
                    trackingRepository: session.repositories.tracking,
                    diaryRepository: session.repositories.diary,
                    listRepository: session.repositories.lists,
                    mediaLensStore: mediaLensStore,
                    currentUserId: currentUserId,
                    requestedShelf: $requestedLibraryShelf,
                    selectedTab: selectedTab,
                    onSelectTab: { selectedTab = $0 },
                    onUnauthorized: unauthorized
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .tabItem {
                Image(systemName: "books.vertical")
                    .accessibilityLabel("Library")
            }
            .tag(AppTab.library)

            LazyTab(isSelected: selectedTab == .diary) {
                DiaryView(
                    diaryRepository: session.repositories.diary,
                    mediaRepository: session.repositories.media,
                    trackingRepository: session.repositories.tracking,
                    currentUserId: currentUserId,
                    selectedTab: selectedTab,
                    onSelectTab: { selectedTab = $0 },
                    onUnauthorized: unauthorized
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .tabItem {
                Image(systemName: "calendar")
                    .accessibilityLabel("Diary")
            }
            .tag(AppTab.diary)

            LazyTab(isSelected: selectedTab == .profile) {
                ProfileView(
                    profileRepository: session.repositories.profile,
                    diaryRepository: session.repositories.diary,
                    mediaRepository: session.repositories.media,
                    trackingRepository: session.repositories.tracking,
                    activityRepository: session.repositories.activity,
                    listRepository: session.repositories.lists,
                    importCoordinator: session.letterboxdImportCoordinator,
                    storygraphImportCoordinator: session.storygraphImportCoordinator,
                    goodreadsImportCoordinator: session.goodreadsImportCoordinator,
                    currentUserId: currentUserId,
                    onLogout: {
                        Task { await session.logout() }
                    },
                    onOpenDiary: {
                        selectedTab = .diary
                    },
                    onOpenLibrary: { shelf in
                        requestedLibraryShelf = shelf
                        selectedTab = .library
                    },
                    selectedTab: selectedTab,
                    onSelectTab: { selectedTab = $0 },
                    onUnauthorized: unauthorized
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .tabItem {
                Image(systemName: "person.crop.circle")
                    .accessibilityLabel("Profile")
            }
            .tag(AppTab.profile)
        }
        .tint(.white)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .tabBarMinimizeBehavior(.never)
        .background {
            TabBarSelectionObserver { index in
                guard AppTab(tabBarIndex: index) == .search,
                      selectedTab == .search else { return }
                searchFocusRequest += 1
            }
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            session.letterboxdImportCoordinator.resumeIfNeeded()
            session.storygraphImportCoordinator.resumeIfNeeded()
            session.goodreadsImportCoordinator.resumeIfNeeded()
        }
        .task {
            guard session.signedInEntryPoint == .search else { return }
            session.markSignedInEntryPointHandled()
            await Task.yield()
            searchFocusRequest += 1
        }
    }

    private func unauthorized() {
        Task { await session.logout() }
    }
}

enum AppTab: Hashable {
    case home
    case search
    case library
    case diary
    case profile

    init?(tabBarIndex: Int) {
        switch tabBarIndex {
        case 0: self = .home
        case 1: self = .search
        case 2: self = .library
        case 3: self = .diary
        case 4: self = .profile
        default: return nil
        }
    }
}

private struct TabBarSelectionObserver: UIViewControllerRepresentable {
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.onAttach = { [weak controller] in
            guard let tabBarController = controller?.tabBarController else { return }
            context.coordinator.observe(tabBarController)
        }
        return controller
    }

    func updateUIViewController(_ controller: ObserverViewController, context: Context) {
        context.coordinator.onSelect = onSelect
        controller.onAttach = { [weak controller] in
            guard let tabBarController = controller?.tabBarController else { return }
            context.coordinator.observe(tabBarController)
        }

        DispatchQueue.main.async {
            guard let tabBarController = controller.tabBarController else { return }
            context.coordinator.observe(tabBarController)
        }
    }

    static func dismantleUIViewController(_ controller: ObserverViewController, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var onSelect: (Int) -> Void
        weak var tabBarController: UITabBarController?
        weak var previousDelegate: UITabBarControllerDelegate?

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        func observe(_ tabBarController: UITabBarController) {
            if self.tabBarController === tabBarController {
                if tabBarController.delegate !== self {
                    previousDelegate = tabBarController.delegate
                    tabBarController.delegate = self
                }
                return
            }

            self.tabBarController = tabBarController
            previousDelegate = tabBarController.delegate
            tabBarController.delegate = self
        }

        func stopObserving() {
            guard let tabBarController,
                  tabBarController.delegate === self else { return }
            tabBarController.delegate = previousDelegate
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)

            guard let index = tabBarController.viewControllers?.firstIndex(of: viewController) else { return }
            onSelect(index)
        }
    }

    final class ObserverViewController: UIViewController {
        var onAttach: (() -> Void)?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil {
                onAttach?()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAttach?()
        }
    }
}

private struct LazyTab<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content

    @State private var hasLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                content()
            } else {
                Color.clear
            }
        }
        .onChange(of: isSelected, initial: true) {
            if isSelected {
                hasLoaded = true
            }
        }
    }

    private var isLoaded: Bool {
        isSelected || hasLoaded
    }
}

#Preview {
    AppShellView(session: AppSession(repositories: .live()))
}
