import SwiftUI
import MapKit

/// The pace-colored route map. Lifted out of `RunDetailView` unchanged so the race recap
/// draws the same map rather than a second one that drifts from it.
struct RunRouteMap: View {
    let detail: RunDetail
    var interactive = false

    var body: some View {
        Map(initialPosition: .region(Self.region(for: detail)), interactionModes: interactive ? .all : []) {
            ForEach(detail.routeSegments) { seg in
                MapPolyline(coordinates: seg.coords)
                    .stroke(Tokens.Zone.all[seg.zone], style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    static func region(for detail: RunDetail) -> MKCoordinateRegion {
        let coords = detail.routeSegments.flatMap(\.coords)
        guard let first = coords.first else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                        longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        )
    }
}
