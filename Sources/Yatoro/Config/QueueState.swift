import Foundation

struct QueueState: Codable, Sendable {
    let songIDs: [String]
    let currentIndex: Int?
    let playbackTime: Double
    let shuffleMode: String?
    let repeatMode: String?
}
