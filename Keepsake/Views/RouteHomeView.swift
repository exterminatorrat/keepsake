import CoreLocation
import MapKit
import SwiftUI
import UIKit

@MainActor
struct RouteHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDay = Calendar(identifier: .gregorian).startOfDay(for: .now)
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var confirmEraseHistory = false

    let recorder: RecorderModel

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private var daySamples: [RouteSample] {
        RouteHistory.samples(on: selectedDay, in: calendar, from: recorder.samples)
    }

    private var route: SegmentedRoute {
        RouteHistory.segments(from: daySamples)
    }

    private var availableDays: [Date] {
        let today = calendar.startOfDay(for: .now)
        return Array(Set(RouteHistory.availableDays(in: calendar, from: recorder.samples) + [today])).sorted(by: >)
    }

    private var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dayPicker
                    routeMap
                    recorderStatus
                    recordingButton
                    privacyControls
                }
                .padding()
            }
            .navigationTitle("Keepsake")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    recorder.refreshPermissions()
                    recorder.expireHistory()
                }
            }
            .onChange(of: daySamples.map(\.id)) { _, _ in
                centerMap()
            }
            .confirmationDialog(
                "Erase all local route history?",
                isPresented: $confirmEraseHistory,
                titleVisibility: .visible
            ) {
                Button("Erase History", role: .destructive) {
                    recorder.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes route samples stored on this device.")
            }
        }
    }

    private var dayPicker: some View {
        Menu {
            ForEach(availableDays, id: \.self) { day in
                Button(formattedDay(day)) {
                    selectedDay = day
                }
            }
        } label: {
            Label(formattedDay(selectedDay), systemImage: "calendar")
                .font(.headline)
        }
        .accessibilityLabel("Choose route day")
    }

    private var routeMap: some View {
        Map(position: $cameraPosition) {
            ForEach(route.segments) { segment in
                if segment.samples.count > 1 {
                    MapPolyline(coordinates: segment.samples.map(coordinate(for:)))
                        .stroke(.blue, lineWidth: 4)
                }

                if let first = segment.samples.first {
                    Marker("Start", coordinate: coordinate(for: first))
                }

                if let last = segment.samples.last, last.id != segment.samples.first?.id {
                    Marker("Latest", coordinate: coordinate(for: last))
                }
            }
        }
        .mapStyle(.standard)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if route.segments.isEmpty {
                ContentUnavailableView(
                    daySamples.isEmpty ? "No route points" : "No reliable route points",
                    systemImage: "map",
                    description: Text(daySamples.isEmpty ? "Start a local recording to build this route." : "Low-accuracy fixes are kept locally but omitted from the map.")
                )
                .padding()
            }
        }
        .onAppear(perform: centerMap)
    }

    private var recorderStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(recorder.phase.title, systemImage: recorder.phase.symbol)
                .font(.headline)

            if let locationMessage = recorder.locationMessage {
                Text(locationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Text(recorder.backgroundDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LabeledContent("Permission", value: recorder.capabilities.authorization.title)
            LabeledContent("Accuracy", value: recorder.capabilities.fullAccuracy ? "Precise" : "Reduced")
            LabeledContent("Capture", value: recorder.isStationary ? "Stationary" : "Moving or waiting")

            if let latest = recorder.samples.last {
                LabeledContent("Latest observation", value: latest.observedAt.formatted(date: .omitted, time: .standard))
                LabeledContent("Horizontal accuracy", value: "±\(Int(latest.horizontalAccuracy.rounded())) m")
            } else {
                LabeledContent("Latest observation", value: "None yet")
            }

            if !route.gaps.isEmpty {
                LabeledContent("Coverage gaps", value: "\(route.gaps.count)")
                if let gap = route.gaps.last {
                    Text(gapDescription(gap))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Coverage gaps", value: "None on this day")
            }

            if recorder.rejectedSampleCount > 0 {
                Text("Rejected duplicate, invalid, or out-of-order fixes: \(recorder.rejectedSampleCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recorder.didRecoverIncompleteTail {
                Text("Local history recovered after an interrupted final write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let storageMessage = recorder.storageMessage {
                Text(storageMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recordingButton: some View {
        Button {
            if recorder.isRecordingRequested {
                recorder.stopRecording()
            } else {
                recorder.startRecording()
            }
        } label: {
            Label(
                recorder.isRecordingRequested ? "Stop recording" : "Start local recording",
                systemImage: recorder.isRecordingRequested ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!recorder.isRecordingRequested && (!recorder.isStorageReady || recorder.isClearingHistory || recorder.storageMessage != nil))
    }

    private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.capabilities.authorization == .whileInUse && recorder.isRecordingRequested {
                if recorder.alwaysAuthorizationDenied {
                    settingsLink("Open Settings to allow Always access")
                } else if !recorder.isRequestingAlwaysAccess {
                    Button("Request Always access") {
                        recorder.requestAlwaysAccess()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if recorder.capabilities.authorization == .denied
                || recorder.capabilities.authorization == .restricted
                || !recorder.capabilities.servicesEnabled {
                settingsLink("Open Settings")
            }

            Text("Route samples stay on this device for 90 days and are excluded from device backups. No location is sent to a service or written to diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Erase local route history", role: .destructive) {
                confirmEraseHistory = true
            }
            .font(.caption)
            .disabled(recorder.isRecordingRequested || recorder.isClearingHistory)
        }
    }

    private func settingsLink(_ title: String) -> some View {
        Group {
            if let settingsURL {
                Link(title, destination: settingsURL)
            }
        }
    }

    private func coordinate(for sample: RouteSample) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude)
    }

    private func formattedDay(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    private func centerMap() {
        let coordinates = route.segments.flatMap(\.samples).map(coordinate(for:))
        guard !coordinates.isEmpty else {
            cameraPosition = .automatic
            return
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let latitudeDelta = max(0.01, (latitudes.max()! - latitudes.min()!) * 1.5)
        let longitudeDelta = max(0.01, (longitudes.max()! - longitudes.min()!) * 1.5)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudes.min()! + latitudes.max()!) / 2,
                longitude: (longitudes.min()! + longitudes.max()!) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
        cameraPosition = .region(region)
    }

    private func gapDescription(_ gap: CoverageGap) -> String {
        switch gap.reason {
        case .missingFix:
            "No reliable fix for about \(Int((gap.duration / 60).rounded())) minutes; the map does not connect across it."
        case .lowAccuracy:
            "A low-accuracy fix was omitted and the map route was split."
        }
    }
}
