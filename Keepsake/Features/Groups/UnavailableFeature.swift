import Foundation

enum UnavailableFeature: String, Identifiable, Sendable {
    case chat = "Chat"
    case savedPlaces = "Saved places"
    case manageGroup = "Group management"
    case invitePeople = "Inviting people"
    case joinGroup = "Joining a group"
    case createAnotherGroup = "Creating another group"
    case notifications = "Notifications"
    case locationSharing = "Location sharing"
    case activitySharing = "Activity sharing"
    case manageMembers = "Member management"
    case privacyCenter = "Privacy Center"
    case helpSupport = "Help & Support"
    case memories = "Memories"
    case trips = "Trips"
    case explore = "Explore"
    case camera = "Camera"
    case friends = "Friends"
    case recenterMap = "Centering on your location"
    case mapLayers = "Map layers"

    var id: String { rawValue }

    var message: String {
        switch self {
        case .joinGroup:
            "Joining someone else’s group isn’t part of this build. Your account keeps one private group."
        case .createAnotherGroup:
            "This build keeps one group per account, so a second group can’t be created here."
        case .locationSharing, .activitySharing, .recenterMap:
            "\(rawValue) isn’t part of this build. Keepsake doesn’t share your location or activity."
        default:
            "\(rawValue) isn’t part of this build yet."
        }
    }
}
