//
//  PlaybackDeviceProfile.swift
//  HappiE
//

import AVFoundation
import Foundation
import VideoToolbox

/// The small, HappiE-owned capability description sent when minting a play URL.
/// This deliberately describes AVPlayer, rather than trying to mirror Jellyfin's
/// much larger DeviceProfile model.
struct PlaybackDeviceProfile: Codable, Equatable {
    let engineId: String
    let containers: [String]
    let videoCodecs: [String]
    let audioCodecs: [String]
    let maxBitrate: Int
    let hdrFormats: [String]
    let dolbyVisionProfiles: [Int]
}

enum PlaybackDeviceProfileBuilder {
    static let minimumBitrate = 420_000
    static let defaultMaxBitrate = 20_000_000

    /// Builds an AVPlayer profile from explicit gates so capability decisions
    /// stay deterministic and unit-testable.
    static func avPlayer(
        allowsHEVC: Bool,
        allowsAV1: Bool,
        allowsHDR: Bool,
        allowsDolbyVision: Bool,
        maxBitrate: Int = defaultMaxBitrate
    ) -> PlaybackDeviceProfile {
        var videoCodecs = ["h264"]
        if allowsHEVC {
            videoCodecs.append("hevc")
        }
        if allowsAV1 {
            videoCodecs.append("av1")
        }

        return PlaybackDeviceProfile(
            engineId: "avplayer",
            containers: ["mp4", "mov", "m4v", "hls"],
            videoCodecs: videoCodecs,
            audioCodecs: ["aac", "ac3", "eac3", "mp3", "alac"],
            maxBitrate: max(minimumBitrate, maxBitrate),
            hdrFormats: allowsHDR && allowsHEVC ? ["hdr10", "hlg"] : [],
            // DV profile 5 and 8 are only advertised for native AVPlayer with
            // both an HDR display and hardware HEVC decoding. Other DV profiles
            // must be converted by the server instead of risking a black frame.
            dolbyVisionProfiles: allowsDolbyVision && allowsHEVC ? [5, 8] : []
        )
    }

    @MainActor
    static func currentAVPlayer() -> PlaybackDeviceProfile {
        let allowsHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let allowsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let hdrModes = AVPlayer.availableHDRModes
        let allowsHDR = hdrModes.contains(.hdr10) || hdrModes.contains(.hlg)
        let allowsDolbyVision = hdrModes.contains(.dolbyVision)
        return avPlayer(
            allowsHEVC: allowsHEVC,
            allowsAV1: allowsAV1,
            allowsHDR: allowsHDR,
            allowsDolbyVision: allowsDolbyVision
        )
    }
}
