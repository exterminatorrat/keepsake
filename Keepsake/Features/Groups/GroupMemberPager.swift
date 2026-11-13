import SwiftUI
#if DEBUG
import UIKit
#endif

@MainActor
struct GroupMemberPager: View {
    let members: [GroupMemberPresentation]
    let group: SoloGroup
    let availableWidth: CGFloat
    @Binding var selection: AccountID?
    let onExpand: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edgeSwipe: GroupMemberEdgeSwipe? = nil

    var body: some View {
        VStack(spacing: 0) {
            if members.count == 1, let member = members.first {
                card(member)
                    .padding(.horizontal, GroupMemberLayout.sideInset)
            } else if !members.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: GroupMemberLayout.spacing) {
                            ForEach(members) { member in
                                card(member)
                                    .frame(width: GroupMemberLayout.cardWidth(in: availableWidth))
                                    .id(member.id)
                                    #if DEBUG
                                    .background { GroupMemberLayoutProbe(memberID: member.id) }
                                    #endif
                                    .accessibilityHidden(member.id != selection)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, GroupMemberLayout.sideInset, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $selection, anchor: .center)
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .fixedSize(horizontal: false, vertical: true)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        GroupMemberEdgeSwipe.isOutside(
                            offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                            viewportWidth: geometry.containerSize.width,
                            leadingInset: geometry.contentInsets.leading, trailingInset: geometry.contentInsets.trailing
                        )
                    } action: { _, outside in
                        edgeSwipe?.recordOutside(outside)
                    }
                    .onScrollPhaseChange { _, phase, context in
                        let outside = GroupMemberEdgeSwipe.isOutside(
                            offset: context.geometry.contentOffset.x, contentWidth: context.geometry.contentSize.width,
                            viewportWidth: context.geometry.containerSize.width,
                            leadingInset: context.geometry.contentInsets.leading, trailingInset: context.geometry.contentInsets.trailing
                        )
                        if phase == .interacting {
                            edgeSwipe = GroupMemberEdgeSwipe(selection: selection, groupID: group.id, members: members.map(\.id))
                            edgeSwipe?.recordOutside(outside)
                        } else if phase == .tracking {
                            edgeSwipe = nil
                        } else {
                            edgeSwipe?.recordOutside(outside)
                            edgeSwipe?.isInteracting = false
                            if phase == .idle {
                                let completed = edgeSwipe
                                edgeSwipe = nil
                                if let target = completed?.target(selection: selection, groupID: group.id, members: members.map(\.id)) {
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                                        selection = target
                                    }
                                }
                            }
                        }
                    }
                    #if DEBUG
                    .background { GroupMemberLayoutProbe(memberID: nil) }
                    #endif
                    .onAppear {
                        if let target = GroupMemberSelection.initialViewportTarget(selection, available: members.map(\.id)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                pagination
            }
        }
        .padding(.bottom, 8)
        .onChange(of: members.map(\.id), initial: true) { _, ids in
            edgeSwipe = nil
            selection = GroupMemberSelection.reconciled(selection, available: ids)
        }
        .onChange(of: selection) { _, selected in
            if selected != edgeSwipe?.memberID { edgeSwipe = nil }
        }
        .onChange(of: group.id) { _, _ in edgeSwipe = nil }
        .onChange(of: availableWidth) { _, _ in edgeSwipe = nil }
        .onDisappear { edgeSwipe = nil }
    }

    private func card(_ member: GroupMemberPresentation) -> some View {
        GroupMemberCardView(
            group: group,
            member: member,
            memberCount: members.count,
            onExpand: {
                selection = member.id
                onExpand()
            },
            onDismiss: onDismiss
        )
    }

    private var pagination: some View {
        HStack(spacing: 16) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous member")
            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next member")
        }
        .accessibilityLabel("Members")
        .accessibilityValue(members.first(where: { $0.id == selection })?.displayName ?? "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(KeepsakeStyle.ink)
        .frame(maxWidth: .infinity)
        .background(KeepsakeStyle.surface)
    }

    private func move(_ offset: Int) {
        let next = GroupMemberSelection.moved(selection, by: offset, available: members.map(\.id))
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            selection = next
        }
    }
}

#if DEBUG
@MainActor
final class GroupMemberLayoutProbeView: UIView {
    var memberID: AccountID? = nil
}

@MainActor
private struct GroupMemberLayoutProbe: UIViewRepresentable {
    let memberID: AccountID?

    func makeUIView(context: Context) -> GroupMemberLayoutProbeView {
        let view = GroupMemberLayoutProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: GroupMemberLayoutProbeView, context: Context) {
        uiView.memberID = memberID
    }
}

@MainActor
struct GroupMemberPagerPreview: View {
    private static let account = AccountIdentity(
        id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        email: "fixture@example.com"
    )
    private static let group = SoloGroup(
        id: GroupID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        ownerID: account.id,
        name: "Sample group",
        createdAt: Date(timeIntervalSince1970: 100)
    )
    private static let members = [
        GroupMemberPresentation.selfMember(account: account),
        GroupMemberPresentation(id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!), displayName: "Maya", role: "Sample member", isSelf: false),
        GroupMemberPresentation(id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!), displayName: "Jin", role: "Sample member", isSelf: false)
    ]

    @State private var selection: AccountID?
    @State private var showsDetails = false
    private let onSelectionAvailable: (@MainActor (Binding<AccountID?>) -> Void)?

    init(index: Int = 0, onSelectionAvailable: (@MainActor (Binding<AccountID?>) -> Void)? = nil) {
        _selection = State(initialValue: Self.members[min(max(0, index), Self.members.count - 1)].id)
        self.onSelectionAvailable = onSelectionAvailable
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Preview · sample members · no live membership or location")
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if showsDetails, let member = Self.members.first(where: { $0.id == selection }) {
                GroupMemberDetailView(group: Self.group, member: member, onBack: { showsDetails = false }, onUnavailable: { _ in })
            } else {
                HStack {
                    ForEach(Self.members) { member in
                        Button(member.displayName) { selection = member.id }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityAddTraits(member.id == selection ? .isSelected : [])
                    }
                }
                GeometryReader { geometry in
                    VStack {
                        Spacer(minLength: 0)
                        GroupMemberPager(
                            members: Self.members, group: Self.group, availableWidth: geometry.size.width,
                            selection: $selection, onExpand: { showsDetails = true }, onDismiss: { showsDetails = false }
                        )
                    }
                }
            }
        }
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
        .onAppear { onSelectionAvailable?($selection) }
    }
}

#Preview("Member pager - first sample") { GroupMemberPagerPreview(index: 0) }
#Preview("Member pager - middle sample") { GroupMemberPagerPreview(index: 1) }
#Preview("Member pager - last sample") { GroupMemberPagerPreview(index: 2) }
#endif
