import Foundation
import Testing
@testable import KaraifyerCore

struct ExportOptionsTests {
    @Test func defaults() {
        let d = ExportOptions.defaults
        #expect(d.kind == .masterOnly && d.format == .aac && d.kbps == 256 && d.bits == 24 && d.height == 1080 && d.highQuality)
        #expect(d.ext == "m4a")
        var v = d; v.kind = .videoMaster
        #expect(v.ext == "mp4")
    }

    @Test func audioArgsPerFormat() {
        var o = ExportOptions.defaults
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.m4a") == ["-i", "m.wav", "-c:a", "aac", "-b:a", "256k", "o.m4a"])
        o.format = .mp3; o.kbps = 320
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.mp3") == ["-i", "m.wav", "-c:a", "libmp3lame", "-b:a", "320k", "o.mp3"])
        o.format = .wav; o.bits = 16
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.wav") == ["-i", "m.wav", "-c:a", "pcm_s16le", "o.wav"])
        o.format = .flac; o.bits = 24
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 1, out: "o.flac")
                == ["-i", "m.wav", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", "o.flac"])
    }

    @Test func videoArgsScaleTimeAndSize() {
        var o = ExportOptions.defaults
        o.kind = .videoMaster; o.height = 720; o.highQuality = false; o.videoKbps = 192
        #expect(o.ffmpegArgs(wav: "m.wav", video: "v.mp4", rate: 0.9, out: "o.mp4") == [
            "-i", "v.mp4", "-i", "m.wav", "-map", "0:v:0", "-map", "1:a:0",
            "-vf", "setpts=PTS/0.9,scale=-2:720", "-c:v", "libx264", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", "o.mp4"])
    }

    @Test func namesAndDurations() {
        #expect(ExportOptions.fileName(id: "042", titre: "AC/DC: Back?", ext: "m4a") == "042 AC-DC- Back- – mix.m4a")
        #expect(abs(ExportOptions.duration(songSeconds: 180, rate: 0.9) - 200) < 1e-3)   // 0.9 as Float is 0.89999998
    }

    @Test func rememberedChoices() {
        var o = ExportOptions.defaults; o.format = .flac; o.bits = 16
        #expect(ExportOptions.decode(o.encoded()) == o && ExportOptions.decode(Data("x".utf8)) == .defaults)
    }
}
