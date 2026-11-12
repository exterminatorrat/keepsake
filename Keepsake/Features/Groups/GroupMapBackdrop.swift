import MapKit
import SwiftUI

@MainActor
struct GroupMapBackdrop: View {
    var isDimmed = false

    private static let neutralRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.20, longitude: 121.43),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
    )

    var body: some View {
        Map(initialPosition: .region(Self.neutralRegion), interactionModes: [])
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {}
            .grayscale(isDimmed ? 0.85 : 0)
            .overlay {
                KeepsakeStyle.ink
                    .opacity(isDimmed ? 0.22 : 0)
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
