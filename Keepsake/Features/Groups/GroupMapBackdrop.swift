import MapKit
import SwiftUI

@MainActor
struct GroupMapBackdrop<BottomContent: View>: View {
    let isDimmed: Bool
    private let bottomContent: BottomContent

    init(isDimmed: Bool = false, @ViewBuilder bottomContent: () -> BottomContent) {
        self.isDimmed = isDimmed
        self.bottomContent = bottomContent()
    }

    private let neutralRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.20, longitude: 121.43),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
    )

    var body: some View {
        Map(initialPosition: .region(neutralRegion), interactionModes: [])
            .mapStyle(.standard(
                elevation: .flat,
                emphasis: isDimmed ? .muted : .automatic,
                pointsOfInterest: .excludingAll
            ))
            .mapControls {}
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomContent
            }
    }
}
