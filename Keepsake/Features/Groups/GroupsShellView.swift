import SwiftUI

@MainActor
struct GroupsShellView: View {
    private let account: AccountIdentity
    private let state: GroupScreenState
    private let onCreate: (String) -> Void
    private let onRetry: () -> Void
    private let onSignOut: () -> Void

    @State private var navigation: GroupsNavigation
    @State private var draftName = ""
    @State private var notice: UnavailableFeature?
    @State private var isConfirmingSignOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var pillWidth: CGFloat = 182
    @ScaledMetric(relativeTo: .body) private var headerClearance: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isGroupPillFocused: Bool

    init(
        account: AccountIdentity,
        state: GroupScreenState,
        onCreate: @escaping (String) -> Void,
        onRetry: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        initialPresentation: GroupPresentation = .groupCollapsed,
        initialSelectorOpen: Bool = false
    ) {
        self.account = account
        self.state = state
        self.onCreate = onCreate
        self.onRetry = onRetry
        self.onSignOut = onSignOut
        _navigation = State(
            initialValue: GroupsNavigation(
                accountID: account.id,
                presentation: initialPresentation,
                isSelectorOpen: initialSelectorOpen
            )
        )
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { KeepsakeStyle.canvas.ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GroupTabBar(selection: navigation.tab) { tab in
                    navigation.select(tab: tab)
                }
            }
            .animation(animation, value: navigation)
            .alert("Not available yet", isPresented: isShowingNotice, presenting: notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { feature in
                Text(feature.message)
            }
            .confirmationDialog(
                "Sign out on this device?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive, action: onSignOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account will be signed out on this device.")
            }
            .onChange(of: account.id) { _, newAccountID in
                navigation.reset(for: newAccountID)
                draftName = ""
                notice = nil
            }
            .onChange(of: state) { _, newState in
                navigation.sync(with: newState)
            }
            .onChange(of: navigation.isSelectorOpen) { _, isOpen in
                if !isOpen { isGroupPillFocused = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        if navigation.tab == .groups {
            stateContent
        } else {
            GroupTabUnavailableView(tab: navigation.tab) {
                navigation.select(tab: .groups)
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if case .ready(let group, let offline) = state {
            groupSurface(group: group, offline: offline)
        } else if navigation.presentation == .account {
            AccountView(
                account: account,
                onBack: { navigation = GroupsNavigation(accountID: account.id) },
                onSignOut: { isConfirmingSignOut = true },
                onUnavailable: present
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Account") {
                        navigation.showSettings()
                        navigation.showAccount()
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: KeepsakeStyle.minimumHitTarget)
                    .padding(.horizontal, 20)
                }
                unreadyContent
            }
        }
    }

    @ViewBuilder
    private var unreadyContent: some View {
        switch state {
        case .loading:
            GroupLoadingView()
        case .noGroup:
            GroupCreateFormView(name: $draftName, isSubmitting: false, onSubmit: onCreate)
        case .creating(let name):
            GroupCreateFormView(name: .constant(name), isSubmitting: true) { _ in }
        case .reconciling(let name):
            GroupReconcilingView(name: name, onRetry: onRetry)
        case .failed(let message, let offline):
            GroupFailureView(message: message, isOffline: offline, onRetry: onRetry)
        case .ready:
            EmptyView()
        }
    }

    private func groupSurface(group: SoloGroup, offline: Bool) -> some View {
        ZStack {
            GroupMapBackdrop(isDimmed: offline || navigation.presentation == .groupExpanded)
                .ignoresSafeArea()

            switch navigation.presentation {
            case .groupCollapsed, .groupExpanded:
                sheetScene(group: group, offline: offline)
            case .memberCollapsed, .memberExpanded:
                memberScene(group: group)
            case .settings:
                SettingsView(
                    account: account,
                    group: group,
                    onShowGroup: { navigation.showGroupSummary() },
                    onShowAccount: { navigation.showAccount() },
                    onBack: { navigation.goBack() },
                    onUnavailable: present
                )
            case .account:
                AccountView(
                    account: account,
                    onBack: { navigation.goBack() },
                    onSignOut: { isConfirmingSignOut = true },
                    onUnavailable: present
                )
            case .groupSummary:
                GroupSummaryView(
                    group: group,
                    onBack: { navigation.goBack() },
                    onUnavailable: present
                )
            }
        }
    }

    private func sheetScene(group: SoloGroup, offline: Bool) -> some View {
        GeometryReader { geometry in
            let pose: GroupSheetLayout.Pose = navigation.isSelectorOpen ? .selector
                : navigation.detent == .expanded ? .expanded : .collapsed
            let height = GroupSheetLayout.height(
                in: geometry.size.height,
                pose: pose,
                accessibility: dynamicTypeSize.isAccessibilitySize,
                headerClearance: headerClearance
            )
            let width = GroupSheetLayout.selectorWidth(
                in: max(0, geometry.size.width - 2 * KeepsakeStyle.margin),
                preferred: pillWidth,
                accessibility: dynamicTypeSize.isAccessibilitySize
            )
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if navigation.isSelectorOpen {
                        GroupMemberStrip(
                            height: height,
                            onShowMember: { navigation.showMemberCard() },
                            onUnavailable: present
                        )
                        .accessibilityHidden(true)
                        .overlay(alignment: .topTrailing) {
                            mapControl("Center on your location, not available yet", symbol: "location", feature: .recenterMap)
                                .padding(.trailing, 16)
                                .offset(y: -60)
                                .accessibilityHidden(true)
                        }
                    } else {
                        GroupSheetView(
                            group: group,
                            isExpanded: navigation.detent == .expanded,
                            isOffline: offline,
                            height: height,
                            onToggleExpanded: { navigation.toggleSheetDetent() },
                            onShowMember: { navigation.showMemberCard() },
                            onRetry: onRetry,
                            onUnavailable: present
                        )
                        .overlay(alignment: .topTrailing) {
                            if navigation.detent == .collapsed {
                                VStack(spacing: 10) {
                                    mapControl("Center on your location, not available yet", symbol: "location", feature: .recenterMap)
                                    mapControl("Map layers, not available yet", symbol: "square.3.layers.3d", feature: .mapLayers)
                                }
                                .padding(.trailing, 16)
                                .offset(y: -116)
                            }
                        }
                    }
                }

                if navigation.isSelectorOpen {
                    Color.black.opacity(0.0001)
                        .contentShape(Rectangle())
                        .onTapGesture { navigation.closeSelector() }
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }

                VStack(spacing: 8) {
                    groupHeader(group: group, width: width)

                    if navigation.isSelectorOpen {
                        GroupSelectorView(
                            group: group,
                            onSelectGroup: { navigation.closeSelector() },
                            onCreateGroup: { present(.createAnotherGroup) },
                            onJoinGroup: { present(.joinGroup) },
                            width: width,
                            maximumHeight: max(0, geometry.size.height - headerClearance - 16)
                        )
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KeepsakeStyle.margin)
                .padding(.top, 10)
            }
        }
    }

    private func memberScene(group: SoloGroup) -> some View {
        ZStack(alignment: .top) {
            if navigation.presentation == .memberExpanded {
                GroupMemberDetailView(
                    group: group,
                    onBack: { navigation.collapseMemberCard() },
                    onUnavailable: present
                )
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    GroupMemberCardView(
                        group: group,
                        onExpand: { navigation.expandMemberCard() },
                        onDismiss: { navigation.goBack() }
                    )
                }

                VStack(spacing: 8) {
                    groupHeader(group: group)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KeepsakeStyle.margin)
                .padding(.top, 10)
            }
        }
    }

    private func groupHeader(group: SoloGroup, width: CGFloat? = nil) -> some View {
        let settings = Button {
            navigation.showSettings()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(KeepsakeStyle.ink)
                .frame(width: 48, height: 48)
                .background(KeepsakeStyle.surface, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")

        let pill = Button {
            navigation.toggleSelector()
        } label: {
            HStack(spacing: 6) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: navigation.isSelectorOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(KeepsakeStyle.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .frame(maxWidth: width ?? pillWidth)
            .background(KeepsakeStyle.surface, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name), group")
        .accessibilityHint("Shows group choices")
        .accessibilityValue(navigation.isSelectorOpen ? "Open" : "Closed")
        .accessibilityFocused($isGroupPillFocused)

        let notifications = Button {
            present(.notifications)
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(KeepsakeStyle.ink)
                .frame(width: 48, height: 48)
                .background(KeepsakeStyle.surface, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications, not available yet")

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    HStack {
                        settings
                        Spacer(minLength: 8)
                        notifications
                    }
                    pill
                }
            } else {
                HStack(spacing: 10) {
                    settings
                    Spacer(minLength: 8)
                    pill
                    Spacer(minLength: 8)
                    notifications
                }
            }
        }
    }

    private var animation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.28)
    }

    private func mapControl(_ label: String, symbol: String, feature: UnavailableFeature) -> some View {
        Button { present(feature) } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(KeepsakeStyle.ink)
                .frame(width: 48, height: 48)
                .background(KeepsakeStyle.surface, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { isPresented in
                if !isPresented {
                    notice = nil
                }
            }
        )
    }

    private func present(_ feature: UnavailableFeature) {
        notice = feature
    }
}
