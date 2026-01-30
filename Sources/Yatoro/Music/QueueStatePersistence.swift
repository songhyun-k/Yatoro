import Foundation
import Logging
@preconcurrency import MusicKit

@MainActor
enum QueueStatePersistence {

    private static var stateFileURL: URL {
        ConfigurationParser.configFolderURL
            .appendingPathComponent("queue.json", isDirectory: false)
    }

    // MARK: - Save (synchronous, called before exit)

    static func saveState() {
        let player = Player.shared

        var songIDs: [String] = []
        var currentIndex: Int? = nil
        let currentEntry = player.player.queue.currentEntry

        for entry in player.player.queue.entries {
            switch entry.item {
            case .song(let song):
                if let currentEntry, entry.id == currentEntry.id {
                    currentIndex = songIDs.count
                }
                songIDs.append(song.id.rawValue)
            default:
                logger?.debug(
                    "QueueStatePersistence: Skipping non-song queue entry: \(entry)"
                )
            }
        }

        guard !songIDs.isEmpty else {
            logger?.info("QueueStatePersistence: Queue is empty, nothing to save.")
            // Remove stale file if queue is empty
            try? FileManager.default.removeItem(at: stateFileURL)
            return
        }

        let shuffleMode: String? = {
            switch player.player.state.shuffleMode {
            case .off: return "off"
            case .songs: return "songs"
            case .none: return nil
            @unknown default: return nil
            }
        }()

        let repeatMode: String? = {
            switch player.player.state.repeatMode {
            case .none?: return "none"
            case .one: return "one"
            case .all: return "all"
            case nil: return nil
            @unknown default: return nil
            }
        }()

        let state = QueueState(
            songIDs: songIDs,
            currentIndex: currentIndex,
            playbackTime: player.player.playbackTime,
            shuffleMode: shuffleMode,
            repeatMode: repeatMode
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL, options: .atomic)
            logger?.info("QueueStatePersistence: Saved queue state (\(songIDs.count) songs).")
        } catch {
            logger?.error("QueueStatePersistence: Failed to save state: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore (async, called at startup)

    static func restoreState() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateFileURL.path) else {
            logger?.info("QueueStatePersistence: No saved queue state found.")
            return
        }

        let state: QueueState
        do {
            let data = try Data(contentsOf: stateFileURL)
            state = try JSONDecoder().decode(QueueState.self, from: data)
        } catch {
            logger?.error("QueueStatePersistence: Failed to decode state: \(error.localizedDescription)")
            return
        }

        guard !state.songIDs.isEmpty else {
            logger?.info("QueueStatePersistence: Saved state has no songs.")
            return
        }

        // Fetch songs from catalog in batches
        let batchSize = 200
        var songsByID: [String: Song] = [:]

        let idBatches = stride(from: 0, to: state.songIDs.count, by: batchSize).map {
            Array(state.songIDs[$0..<min($0 + batchSize, state.songIDs.count)])
        }

        for batch in idBatches {
            do {
                let musicIDs = batch.map { MusicItemID($0) }
                let request = MusicCatalogResourceRequest<Song>(
                    matching: \.id,
                    memberOf: musicIDs
                )
                let response = try await request.response()
                for song in response.items {
                    songsByID[song.id.rawValue] = song
                }
            } catch {
                logger?.error(
                    "QueueStatePersistence: Failed to fetch songs: \(error.localizedDescription)"
                )
                return
            }
        }

        // Rebuild ordered song list, skipping songs that no longer exist
        var songs: [Song] = []
        var adjustedCurrentIndex: Int? = state.currentIndex
        var skippedBeforeCurrent = 0

        for (i, id) in state.songIDs.enumerated() {
            if let song = songsByID[id] {
                songs.append(song)
            } else {
                logger?.debug("QueueStatePersistence: Song \(id) no longer available, skipping.")
                if let ci = state.currentIndex, i < ci {
                    skippedBeforeCurrent += 1
                }
            }
        }

        guard !songs.isEmpty else {
            logger?.info("QueueStatePersistence: No songs could be restored.")
            return
        }

        // Adjust currentIndex for skipped songs
        if let ci = adjustedCurrentIndex {
            adjustedCurrentIndex = ci - skippedBeforeCurrent
            if adjustedCurrentIndex! >= songs.count || adjustedCurrentIndex! < 0 {
                adjustedCurrentIndex = nil
            }
        }

        // Rotate so current song is at the front
        let rotatedSongs: [Song]
        if let ci = adjustedCurrentIndex, ci > 0 {
            rotatedSongs = Array(songs[ci...]) + Array(songs[..<ci])
        } else {
            rotatedSongs = songs
        }

        let player = Player.shared
        player.player.queue = .init(for: MusicItemCollection(rotatedSongs))

        do {
            try await player.player.prepareToPlay()
        } catch {
            logger?.error(
                "QueueStatePersistence: Failed to prepare player: \(error.localizedDescription)"
            )
            return
        }

        // Restore playback position
        player.player.playbackTime = state.playbackTime

        // Restore shuffle mode
        if let shuffleMode = state.shuffleMode {
            switch shuffleMode {
            case "off":
                player.player.state.shuffleMode = .off
            case "songs":
                player.player.state.shuffleMode = .songs
            default:
                break
            }
        }

        // Restore repeat mode
        if let repeatMode = state.repeatMode {
            switch repeatMode {
            case "none":
                player.player.state.repeatMode = MusicPlayer.RepeatMode.none
            case "one":
                player.player.state.repeatMode = .one
            case "all":
                player.player.state.repeatMode = .all
            default:
                break
            }
        }

        logger?.info(
            "QueueStatePersistence: Restored queue state (\(rotatedSongs.count) songs)."
        )
    }
}
