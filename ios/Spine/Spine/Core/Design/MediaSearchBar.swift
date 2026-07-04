import SwiftUI

struct MediaSearchBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @Binding var text: String
    @Binding var selectedMediaType: String
    @Binding var isLensExpanded: Bool
    let availableTypes: [String]
    var placeholderPrefix = "Search"
    var horizontalPadding: CGFloat = 16
    let onLensTap: () -> Void
    let onLensSelect: (String) -> Void
    let onSearch: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack {
            if isLensExpanded {
                MediaSearchLensPicker(
                    selectedType: $selectedMediaType,
                    availableTypes: availableTypes,
                    horizontalPadding: horizontalPadding,
                    onSelect: selectLens
                )
                .transition(.opacity)
            } else {
                searchControls
                    .modifier(MediaSearchChrome(isLensExpanded: false, horizontalPadding: horizontalPadding))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84), value: isLensExpanded)
        .onChange(of: isLensExpanded) {
            if isLensExpanded {
                isFocused = false
            }
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(searchPlaceholder, text: $text)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(performSearch)

            MediaLensChip(selectedType: selectedMediaType, size: 24, symbolSize: 12, onTap: onLensTap)
                .padding(.horizontal, 2)

            Button(action: clearOrDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text.isEmpty ? "Dismiss search" : "Clear search")
        }
    }

    private var searchPlaceholder: String {
        "\(placeholderPrefix) \(MediaTypeTheme.theme(for: selectedMediaType).displayName.lowercased())"
    }

    private func performSearch() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSearch(trimmed)
    }

    private func clearOrDismiss() {
        if text.isEmpty {
            isFocused = false
        } else {
            text = ""
            onClear()
        }
    }

    private func selectLens(_ type: String) {
        selectedMediaType = type
        onLensSelect(type)
        isLensExpanded = false
    }
}

struct MediaSearchLensPicker: View {
    @Binding var selectedType: String
    let availableTypes: [String]
    var horizontalPadding: CGFloat = 16
    var fitsAllTypes = false
    var allowsEmptySelection = false
    var isCompact = false
    let onSelect: (String) -> Void

    var body: some View {
        MediaSearchLensRail(
            selectedType: $selectedType,
            availableTypes: availableTypes,
            fitsAllTypes: fitsAllTypes,
            isCompact: isCompact,
            allowsEmptySelection: allowsEmptySelection,
            onSelect: onSelect
        )
        .modifier(MediaSearchChrome(isLensExpanded: true, horizontalPadding: horizontalPadding, isCompact: isCompact))
    }
}

private struct MediaSearchChrome: ViewModifier {
    let isLensExpanded: Bool
    let horizontalPadding: CGFloat
    var isCompact = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, isCompact ? 5 : (isLensExpanded ? 12 : 3))
            .frame(minHeight: isCompact ? 52 : (isLensExpanded ? 92 : 44))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 2)
            .padding(.bottom, 5)
    }
}

private struct MediaSearchLensRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedType: String
    let availableTypes: [String]
    let fitsAllTypes: Bool
    let isCompact: Bool
    let allowsEmptySelection: Bool
    let onSelect: (String) -> Void

    var body: some View {
        if fitsAllTypes {
            GeometryReader { proxy in
                let spacing: CGFloat = 6
                let width = max(30, (proxy.size.width - spacing * CGFloat(max(availableTypes.count - 1, 0))) / CGFloat(max(availableTypes.count, 1)))
                let diameter = min(isCompact ? 34 : 38, width)

                HStack(spacing: spacing) {
                    ForEach(availableTypes, id: \.self) { type in
                        MediaSearchLensOrb(
                            type: type,
                            isSelected: selectedType == type,
                            diameter: diameter,
                            itemWidth: width,
                            showsSelectionIndicator: !isCompact,
                            onTap: {
                                select(type)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: isCompact ? 42 : 68)
            }
            .frame(height: isCompact ? 42 : 68)
            .accessibilityLabel("Media type picker")
        } else {
            scrollingRail
        }
    }

    private var scrollingRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(availableTypes, id: \.self) { type in
                        MediaSearchLensOrb(
                            type: type,
                            isSelected: selectedType == type,
                            onTap: {
                                select(type)
                            }
                        )
                        .id(type)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
            }
            .frame(height: 68)
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                proxy.scrollTo(selectedType, anchor: .center)
            }
            .onChange(of: selectedType) {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    proxy.scrollTo(selectedType, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Media type picker")
    }

    private func select(_ type: String) {
        if allowsEmptySelection, selectedType == type {
            selectedType = ""
            onSelect("")
        } else {
            selectedType = type
            onSelect(type)
        }
    }
}

private struct MediaSearchLensOrb: View {
    let type: String
    let isSelected: Bool
    var diameter: CGFloat = 48
    var itemWidth: CGFloat = 52
    var showsSelectionIndicator = true
    let onTap: () -> Void

    private var theme: MediaTypeTheme {
        MediaTypeTheme.theme(for: type)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Circle()
                    .fill(.clear)
                    .modifier(MediaLensCircleStyle(isSelected: isSelected))
                    .overlay {
                        MediaTypeGlyph(theme: theme, size: diameter * (isSelected ? 0.44 : 0.38))
                    }
                    .frame(width: diameter, height: diameter)

                if showsSelectionIndicator {
                    Capsule()
                        .fill(.white.opacity(isSelected ? 0.58 : 0))
                        .frame(width: 12, height: 2)
                }
            }
            .frame(width: itemWidth, height: showsSelectionIndicator ? 58 : diameter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
