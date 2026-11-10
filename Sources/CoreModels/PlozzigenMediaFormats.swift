import Foundation

/// Shared input hints for negotiation and version selection with the linked
/// Aether/FFmpeg build, not a decoder router or a playback guarantee.
/// Keep containers, video and audio aligned; see docs/playback-engines.md.
public enum PlozzigenMediaFormats {
    public static let containers = [
        "mp4", "m4v", "mov", "mkv", "matroska", "webm", "avi",
        "mpegts", "ts", "m2ts", "mts", "m2t", "bdav", "bdmv",
        "mpeg", "mpegps", "mpg", "vob", "3gp", "3g2", "ogg", "ogv",
        "asf", "wmv", "flv", "rm", "rmvb"
    ]
    public static let videoCodecs = [
        "h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "vc1",
        "qtrle", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3",
        "flv1", "vp6", "vp6f", "vp6a", "h263", "theora", "rv10", "rv20", "rv30", "rv40"
    ]
    public static let audioCodecs = [
        "aac", "aac_latm", "ac3", "eac3", "mp2", "mp3", "alac", "flac",
        "opus", "vorbis", "truehd", "mlp", "dts", "dca",
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
        "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8",
        "pcm_alaw", "pcm_mulaw", "pcm_bluray", "pcm_dvd",
        "wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice",
        "nellymoser", "adpcm_swf", "speex", "amr_nb", "amr_wb",
        "cook", "atrac3", "sipr", "ralf", "ra_144", "ra_288"
    ]

    private static let containerSet = Set(containers)
    private static let videoSet = Set(videoCodecs)
    private static let audioSet = Set(audioCodecs)

    public static func supports(container: String) -> Bool {
        containerSet.contains(container.lowercased())
    }

    public static func supports(videoCodec: String) -> Bool {
        let codec = videoCodec.lowercased()
        switch codec {
        case "avc", "avc1": return true
        case "h265", "av01", "vc-1", "mpeg2", "flv": return true
        default: return videoSet.contains(codec)
        }
    }

    public static func supports(audioCodec: String) -> Bool {
        let codec = audioCodec.lowercased()
        switch codec {
        case "pcm", "lpcm", "ec3", "dts-hd", "dts-hd ma", "dtshd", "dca-ma": return true
        default: return audioSet.contains(codec)
        }
    }
}
