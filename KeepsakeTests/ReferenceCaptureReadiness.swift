import MapKit
import SwiftUI
import UIKit
@testable import Keepsake

struct ReferenceMemberViewport: Codable, Equatable, Sendable {
    struct Card: Codable, Equatable, Sendable {
        let id: UUID
        let frame: CGRect
    }

    let expectedID: UUID
    let viewport: CGRect
    let cards: [Card]

    var centeredID: UUID? {
        guard Set(cards.map(\.id)).count == cards.count,
              ([viewport] + cards.map(\.frame)).allSatisfy({ frame in
                  frame.width > 0 && frame.height > 0
                      && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
              }) else { return nil }
        let centered = cards.filter {
            $0.frame.intersects(viewport) && abs($0.frame.midX - viewport.midX) <= 1
        }
        return centered.count == 1 ? centered.first?.id : nil
    }

    var isReady: Bool {
        guard centeredID == expectedID, let card = cards.first(where: { $0.id == expectedID }) else { return false }
        let visible = card.frame.intersection(viewport)
        return visible.width >= card.frame.width - 1 && visible.height >= card.frame.height - 1
    }
}

struct ReferenceMemberScroll: Codable, Equatable, Sendable {
    struct Insets: Codable, Equatable, Sendable {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat

        init(_ insets: UIEdgeInsets) {
            top = insets.top
            left = insets.left
            bottom = insets.bottom
            right = insets.right
        }
    }

    var cardProbeCount = 0
    var ownerCount = 0
    var allCardsShareOwner = false
    var ownerToken: String?
    var bounds: CGRect?
    var windowFrame: CGRect?
    var contentSize: CGSize?
    var contentOffset: CGPoint?
    var contentInset: Insets?
    var adjustedContentInset: Insets?
    var isScrollEnabled: Bool?
    var isTracking: Bool?
    var isDragging: Bool?
    var isDecelerating: Bool?

    var isObservable: Bool {
        guard cardProbeCount == 3, ownerCount == 1, allCardsShareOwner,
              let ownerToken, !ownerToken.isEmpty,
              let bounds, let windowFrame, let contentSize, let contentOffset,
              let contentInset, let adjustedContentInset,
              isScrollEnabled != nil, isTracking != nil, isDragging != nil, isDecelerating != nil else { return false }
        return [bounds.minX, bounds.minY, bounds.width, bounds.height,
                windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height,
                contentSize.width, contentSize.height, contentOffset.x, contentOffset.y,
                contentInset.top, contentInset.left, contentInset.bottom, contentInset.right,
                adjustedContentInset.top, adjustedContentInset.left, adjustedContentInset.bottom, adjustedContentInset.right]
            .allSatisfy(\.isFinite)
    }
}

struct ReferenceReadiness: Codable, Equatable, Sendable {
    enum MapState: String, Codable, Sendable {
        case notRequired, pending, fullyRendered, unavailable, unobservable
    }

    var appeared = false
    var stableLayoutFrames = 0
    var map: MapState
    var deadlineExpired = false
    var detail: String?
    var memberViewport: ReferenceMemberViewport? = nil
    var memberScroll: ReferenceMemberScroll? = nil

    var isReady: Bool {
        appeared && stableLayoutFrames >= 2 && !deadlineExpired
            && (map == .notRequired || map == .fullyRendered)
            && (memberViewport?.isReady ?? true)
            && (memberScroll?.isObservable ?? true)
    }

    mutating func recordLayout(stable: Bool, memberViewport: ReferenceMemberViewport? = nil, memberScroll: ReferenceMemberScroll? = nil) {
        let observed = memberViewport ?? self.memberViewport.map {
            ReferenceMemberViewport(expectedID: $0.expectedID, viewport: .zero, cards: [])
        }
        let memberStable = self.memberViewport == observed
        self.memberViewport = observed
        let observedScroll = memberScroll ?? self.memberScroll.map { _ in ReferenceMemberScroll() }
        let scrollStable = self.memberScroll == observedScroll
        self.memberScroll = observedScroll
        stableLayoutFrames = stable && memberStable && scrollStable ? stableLayoutFrames + 1 : 0
    }

    mutating func renderingStarted() {
        guard map != .unavailable, map != .unobservable else { return }
        map = .pending
        stableLayoutFrames = 0
    }

    mutating func renderingFinished(fullyRendered: Bool) {
        guard map != .unavailable, map != .unobservable else { return }
        map = fullyRendered ? .fullyRendered : .pending
        stableLayoutFrames = 0
    }
}

@MainActor
final class ReferenceHostController: UIViewController {
    private(set) var appeared = false

    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }

    func show(_ child: UIViewController) {
        addChild(child)
        child.beginAppearanceTransition(true, animated: false)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        view.layoutIfNeeded()
        child.endAppearanceTransition()
    }

    func removeFixture() {
        for child in children {
            child.willMove(toParent: nil)
            child.beginAppearanceTransition(false, animated: false)
            child.view.removeFromSuperview()
            child.endAppearanceTransition()
            child.removeFromParent()
        }
    }
}

@MainActor
final class ReferenceFixtureController: UIHostingController<AnyView> {
    private(set) var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
}

@MainActor
final class ReferenceCaptureReadiness: NSObject {
    private let window: UIWindow
    private let host: ReferenceHostController?
    private let content: ReferenceFixtureController
    private let expectedMemberID: UUID?
    private let observesMemberScroll: Bool
    private var state: ReferenceReadiness
    private var previousGeometry: [CGFloat]?
    private var mapView: MKMapView?
    private var mapObserver: ReferenceMapObserver?
    private var displayLink: CADisplayLink?
    private var deadline: Timer?
    private var continuation: CheckedContinuation<ReferenceReadiness, Never>?

    init(window: UIWindow, host: ReferenceHostController?, content: ReferenceFixtureController, needsMap: Bool, expectedMemberID: UUID? = nil, observesMemberScroll: Bool = false) {
        self.window = window
        self.host = host
        self.content = content
        self.expectedMemberID = expectedMemberID
        self.observesMemberScroll = observesMemberScroll
        state = ReferenceReadiness(map: needsMap ? .pending : .notRequired)
        state.memberViewport = expectedMemberID.map { ReferenceMemberViewport(expectedID: $0, viewport: .zero, cards: []) }
        state.memberScroll = observesMemberScroll ? ReferenceMemberScroll() : nil
    }

    func wait(timeout: TimeInterval) async -> ReferenceReadiness {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(frame))
            displayLink = link
            link.add(to: .main, forMode: .common)
            deadline = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.expire() }
            }
            frame()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        deadline?.invalidate()
        deadline = nil
        if let mapView, let mapObserver, mapView.delegate === mapObserver {
            mapView.delegate = mapObserver.downstream
        }
        mapObserver = nil
        mapView = nil
    }

    @objc private func frame() {
        guard continuation != nil else { return }
        window.layoutIfNeeded()
        content.view.layoutIfNeeded()
        let ownsContent: Bool
        if let host {
            ownsContent = window.rootViewController === host && content.parent === host && host.appeared
        } else {
            ownsContent = window.rootViewController === content && content.parent == nil
        }
        state.appeared = ownsContent && content.appeared && content.view.window === window && window.isKeyWindow

        if state.map != .notRequired, mapObserver == nil {
            let maps = mapViews(in: content.view)
            if maps.count == 1, let map = maps.first {
                let observer = ReferenceMapObserver(downstream: map.delegate) { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .started: state.renderingStarted()
                    case .finished(let fullyRendered): state.renderingFinished(fullyRendered: fullyRendered)
                    case .failed(let detail):
                        state.map = .unavailable
                        state.detail = detail
                    }
                }
                mapView = map
                mapObserver = observer
                map.delegate = observer
            } else if maps.count > 1 {
                state.map = .unobservable
                state.detail = "Expected one public MKMapView, found \(maps.count)"
            }
        }
        if let mapView, let mapObserver, mapView.delegate !== mapObserver {
            state.map = .unobservable
            state.detail = "Map delegate changed during capture"
        }

        let bounds = content.view.bounds
        let insets = content.view.safeAreaInsets
        let geometry = [bounds.width, bounds.height, insets.top, insets.bottom,
                        mapView?.bounds.width ?? 0, mapView?.bounds.height ?? 0]
        let mapHasBounds = state.map == .notRequired
            || (mapView?.bounds.width ?? 0) > 0 && (mapView?.bounds.height ?? 0) > 0
        let valid = state.appeared && bounds.width > 0 && bounds.height > 0 && mapHasBounds
        var memberViewport = state.memberViewport
        var memberScroll = state.memberScroll
        #if DEBUG
        if let expectedID = expectedMemberID {
            let probes = memberProbes(in: content.view).filter { $0.window === window }
            let viewports = probes.filter { $0.memberID == nil }
            let viewport = viewports.count == 1 ? viewports[0].convert(viewports[0].bounds, to: window) : .zero
            let cards = probes.compactMap { probe -> ReferenceMemberViewport.Card? in
                guard let id = probe.memberID else { return nil }
                return .init(id: id.rawValue, frame: probe.convert(probe.bounds, to: window))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            memberViewport = ReferenceMemberViewport(expectedID: expectedID, viewport: viewport, cards: cards)
            if observesMemberScroll {
                memberScroll = scrollSnapshot(probes: probes)
            }
        }
        #endif
        state.recordLayout(stable: valid && previousGeometry == geometry, memberViewport: memberViewport, memberScroll: memberScroll)
        previousGeometry = valid ? geometry : nil
        if state.isReady || state.map == .unavailable || state.map == .unobservable {
            finish()
        }
    }

    private func expire() {
        guard continuation != nil else { return }
        state.deadlineExpired = true
        if state.map == .pending, mapView == nil {
            state.map = .unobservable
            state.detail = "No public MKMapView available before capture deadline"
        }
        finish()
    }

    private func finish() {
        let pending = continuation
        continuation = nil
        stop()
        pending?.resume(returning: state)
    }

    private func mapViews(in view: UIView) -> [MKMapView] {
        if let map = view as? MKMapView { return [map] }
        return view.subviews.flatMap { mapViews(in: $0) }
    }

    #if DEBUG
    private func memberProbes(in view: UIView) -> [GroupMemberLayoutProbeView] {
        if let probe = view as? GroupMemberLayoutProbeView { return [probe] }
        return view.subviews.flatMap { memberProbes(in: $0) }
    }

    private func scrollSnapshot(probes: [GroupMemberLayoutProbeView]) -> ReferenceMemberScroll {
        let cards = probes.filter { $0.memberID != nil }
        var owners: [UIScrollView] = []
        for card in cards {
            var ancestor = card.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    owners.append(scroll)
                    break
                }
                ancestor = view.superview
            }
        }
        var snapshot = ReferenceMemberScroll()
        snapshot.cardProbeCount = cards.count
        snapshot.ownerCount = Set(owners.map { ObjectIdentifier($0) }).count
        snapshot.allCardsShareOwner = cards.count == 3 && owners.count == cards.count && snapshot.ownerCount == 1
        guard snapshot.allCardsShareOwner, let scroll = owners.first else { return snapshot }
        snapshot.ownerToken = String(describing: ObjectIdentifier(scroll))
        snapshot.bounds = scroll.bounds
        snapshot.windowFrame = scroll.convert(scroll.bounds, to: window)
        snapshot.contentSize = scroll.contentSize
        snapshot.contentOffset = scroll.contentOffset
        snapshot.contentInset = ReferenceMemberScroll.Insets(scroll.contentInset)
        snapshot.adjustedContentInset = ReferenceMemberScroll.Insets(scroll.adjustedContentInset)
        snapshot.isScrollEnabled = scroll.isScrollEnabled
        snapshot.isTracking = scroll.isTracking
        snapshot.isDragging = scroll.isDragging
        snapshot.isDecelerating = scroll.isDecelerating
        return snapshot
    }
    #endif
}

@MainActor
private final class ReferenceMapObserver: NSObject, MKMapViewDelegate {
    enum Event {
        case started
        case finished(Bool)
        case failed(String)
    }

    nonisolated(unsafe) let downstream: (any MKMapViewDelegate)?
    private let receive: @MainActor (Event) -> Void

    init(downstream: (any MKMapViewDelegate)?, receive: @escaping @MainActor (Event) -> Void) {
        self.downstream = downstream
        self.receive = receive
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || downstream?.responds(to: selector) == true
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        if downstream?.responds(to: selector) == true { return downstream }
        return super.forwardingTarget(for: selector)
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        receive(.started)
        downstream?.mapViewWillStartLoadingMap?(mapView)
    }

    func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        receive(.started)
        downstream?.mapViewWillStartRenderingMap?(mapView)
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        receive(.finished(fullyRendered))
        downstream?.mapViewDidFinishRenderingMap?(mapView, fullyRendered: fullyRendered)
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
        let failure = error as NSError
        receive(.failed("\(failure.domain):\(failure.code)"))
        downstream?.mapViewDidFailLoadingMap?(mapView, withError: error)
    }
}
