import CoreLocation
import MapKit
import SwiftUI

@MainActor
struct LocalCaptureExperimentHost: View {
    @State private var model: LocalCaptureConsumerModel?
    @State private var store: LocalCaptureExperimentStore?
    @State private var isOpening = false
    @State private var openError: String?

    var body: some View {
        Group {
            if let model, let store {
                LocalCaptureExperimentView(
                    model: model,
                    prune: { try await store.pruneHistory(now: .now, limit: 64, operationID: UUID()) },
                    closeFailedMaintenanceSession: {
                        model.dispose()
                        await store.close()
                        self.model = nil
                        self.store = nil
                    }
                )
            } else {
                NavigationStack {
                    Form {
                        Section("Disabled-by-default experiment") {
                            Text("This build uses an isolated foundation store. Legacy routes are never opened, imported or erased here.")
                            Text("Opening verifies saved intent only. Recording and persisted-intent resume require separate explicit actions.")
                            Button("Create empty isolated store") {
                                open(.createEmpty)
                            }
                            Button("Open existing isolated store") {
                                open(.openExisting)
                            }
                        }
                        .disabled(isOpening)
                        if isOpening {
                            ProgressView("Verifying isolated store")
                        }
                        if let openError {
                            Text(openError).foregroundStyle(.red)
                        }
                    }
                    .navigationTitle("Local capture experiment")
                }
            }
        }
    }

    private func open(_ mode: LocalCaptureExperimentOpenMode) {
        guard !isOpening else { return }
        isOpening = true
        openError = nil
        Task { @MainActor in
            defer { isOpening = false }
            var opened: LocalCaptureExperimentStore?
            do {
                let support = try await Task.detached(priority: .utility) {
                    try FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    )
                }.value
                let session = try await LocalCaptureExperimentStore.open(in: support, mode: mode)
                opened = session
                let lifecycle = try await LocalCaptureLifecycle.open(
                    persistence: session,
                    reopenVerifiedStore: { try await session.reopenVerified() },
                    locationUpdateSource: LiveRecorderLocationUpdateSource(),
                    authorization: LocationAuthorizationObserver(),
                    runtimePlatform: CoreLocationRecorderRuntimePlatform(),
                    writeAdmissionMode: .boundedMovementStationary
                )
                store = session
                model = LocalCaptureConsumerModel(lifecycle: lifecycle, historyReader: session)
            } catch {
                await opened?.close()
                openError = String(describing: error)
            }
        }
    }
}

@MainActor
private struct LocalCaptureExperimentView: View {
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var confirmClear = false
    @State private var maintenanceMessage: String?

    let model: LocalCaptureConsumerModel
    let prune: @MainActor () async throws -> CapturePruneReceipt
    let closeFailedMaintenanceSession: @MainActor () async -> Void

    private var isStopped: Bool {
        if case .stopped = model.captureState { return true }
        return false
    }

    private var canReadHistory: Bool {
        switch model.captureState {
        case .unready, .uncertain: false
        default: !model.isClearingHistory && !model.isMaintainingHistory && !model.historyMaintenanceRequiresReopen
        }
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<90).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Isolated foundation capture") {
                    Text("Legacy history is untouched. No automatic resume, migration or backend sync.")
                        .font(.caption)
                    captureControls
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let interruption = model.lastInterruption {
                        Text("Runtime interruption: \(String(describing: interruption)). Resume remains explicit.")
                            .font(.caption)
                    }
                    Text("The experimental admission policy bounds redundant downstream writes. Location updates remain OS-managed; battery and accuracy improvements are not yet measured.")
                        .font(.caption)
                }

                Section("One bounded history page") {
                    Picker("Day", selection: $selectedDay) {
                        ForEach(days, id: \.self) { day in
                            Text(day, format: .dateTime.year().month().day()).tag(day)
                        }
                    }
                    .disabled(!canReadHistory)
                    if model.isHistoryLoading {
                        ProgressView("Reading page")
                    }
                    if let page = model.historyPage, !model.isMaintainingHistory {
                        LocalCapturePageMap(page: page)
                            .frame(height: 300)
                        Text("\(page.items.count) points on this page. Only this page is shown; Next replaces it rather than accumulating a complete route.")
                            .font(.caption)
                        Text(page.nextCursor == nil ? "End of this query. Earlier pages are not shown." : "More points are available in this query.")
                            .font(.caption)
                    } else {
                        Text("No history page displayed.")
                    }
                    if let error = model.historyError {
                        Text(error).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Refresh first page") {
                            Task { await selectDay() }
                        }
                        .disabled(!canReadHistory)
                        Button("Next page") {
                            Task { await model.loadNextHistoryPage() }
                        }
                        .disabled(!canReadHistory || !model.canLoadNextHistoryPage)
                    }
                }

                Section("Isolated history maintenance") {
                    Button("Clear isolated history", role: .destructive) { confirmClear = true }
                        .disabled(!isStopped || model.isClearingHistory || model.isMaintainingHistory || model.historyMaintenanceRequiresReopen)
                    Button("Prune one bounded chunk") { pruneChunk() }
                        .disabled(!isStopped || model.isClearingHistory || model.isMaintainingHistory || model.historyMaintenanceRequiresReopen)
                    if model.isClearingHistory || model.isMaintainingHistory { ProgressView() }
                    if model.historyMaintenanceRequiresReopen {
                        Text("Maintenance did not return a confirmed result. No retry or recording is allowed in this session. Close it, then explicitly open the existing store to verify saved intent before continuing.")
                            .font(.caption)
                        Button("Close failed maintenance session") {
                            Task { await closeFailedMaintenanceSession() }
                        }
                    }
                    if let maintenanceMessage { Text(maintenanceMessage).font(.caption) }
                    Text("Clear is logical deletion, not a promise of physical erasure. Pruning removes one bounded chunk of hidden or expired rows without changing recording intent.")
                        .font(.caption)
                }
            }
            .navigationTitle("Capture experiment")
            .onChange(of: selectedDay) { _, _ in
                Task { await selectDay() }
            }
            .confirmationDialog("Clear this isolated store's history?", isPresented: $confirmClear) {
                Button("Clear isolated history", role: .destructive) {
                    Task {
                        do {
                            _ = try await model.clearHistory()
                            maintenanceMessage = "Logical clear confirmed. Refresh explicitly to read again."
                        } catch {
                            maintenanceMessage = String(describing: error)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Legacy routes are untouched. Start remains vetoed while clear is pending or uncertain.")
            }
        }
    }

    @ViewBuilder
    private var captureControls: some View {
        switch model.captureState {
        case .unready:
            Text("Verified storage is unavailable.")
        case .stopped:
            Text("Stopped: no location runtime is active.")
            Button("Start new isolated recording") {
                perform { _ = try await model.startNewRecording(recordingID: UUID()) }
            }
            .disabled(model.isClearingHistory || model.isMaintainingHistory || model.historyMaintenanceRequiresReopen)
        case .beginning:
            Text("Committing recording intent. Stop remains available.")
            stopButton
        case .active:
            Text("Recording: durable intent and runtime are active.")
            stopButton
        case .resumeRequired:
            Text("Saved active intent; runtime is not running.")
            Button("Explicitly resume saved recording") { perform { _ = try await model.resume() } }
            stopButton
        case .stopping:
            Text("Runtime admission is closed; waiting for durable Stop.")
            stopButton
        case .stopUnconfirmed:
            Text("Stop is unconfirmed. Start and clear remain unavailable.")
            Button("Verify reopen and retry Stop") { perform { _ = try await model.retryStop() } }
        case .uncertain:
            Text("Persistence outcome is uncertain. No automatic replay or Start.")
            Button("Explicitly reconcile") { perform { _ = try await model.reconcileUncertain() } }
        }
    }

    private var stopButton: some View {
        Button("Stop recording") { perform { _ = try await model.stop() } }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { maintenanceMessage = String(describing: error) }
        }
    }

    private func selectDay() async {
        guard canReadHistory, let interval = Calendar.current.dateInterval(of: .day, for: selectedDay) else { return }
        await model.selectHistoryQuery(interval: CapturePageInterval(start: interval.start, end: interval.end))
    }

    private func pruneChunk() {
        guard !model.isMaintainingHistory, isStopped else { return }
        Task { @MainActor in
            do {
                let receipt = try await model.pruneHistory(using: prune)
                maintenanceMessage = "Pruned \(receipt.deletedRows) rows / \(receipt.deletedPayloadBytes) payload bytes. \(receipt.hasMore ? "More maintenance remains; run another explicit chunk." : "This maintenance pass is complete.")"
            } catch {
                maintenanceMessage = String(describing: error)
            }
        }
    }
}

@MainActor
private struct LocalCapturePageMap: View {
    let page: CapturePage

    var body: some View {
        let route = RouteHistory.segments(from: page.items.map(\.sample))
        if route.segments.isEmpty {
            ContentUnavailableView("No reliable points on this page", systemImage: "map")
        } else {
            Map {
                ForEach(route.segments) { segment in
                    if segment.samples.count > 1 {
                        MapPolyline(coordinates: segment.samples.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.blue, lineWidth: 4)
                    }
                    if let first = segment.samples.first {
                        Marker("Page start", coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                    }
                    if let last = segment.samples.last, last.id != segment.samples.first?.id {
                        Marker("Page end", coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                    }
                }
            }
            .mapStyle(.standard)
            .accessibilityLabel("Route points on the displayed page only")
        }
    }
}
