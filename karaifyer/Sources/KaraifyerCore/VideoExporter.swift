import AVFoundation
import CoreVideo
import Foundation

/// The lyrics video to an MP4 (H.264 1080p, 25 fps): frame k is drawn by `KaraokeRenderer` at song time
/// k / fps · rate, so a tempo change in the Lecteur gives a video exactly as long as the stretched audio.
public enum VideoExporter {
    public struct ExportError: LocalizedError {
        public let errorDescription: String?
    }

    public static func export(scene: VideoScene, to url: URL, layout: String, transpose: Int, rate: Double = 1,
                              fps: Int32 = 25, progress: (Double) -> Bool) throws {
        try? FileManager.default.removeItem(at: url)
        let w = 1920, h = 1080
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw ExportError(errorDescription: "vidéo : encodeur indisponible") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError(errorDescription: "vidéo : \(writer.error?.localizedDescription ?? "écriture impossible")")
        }
        writer.startSession(atSourceTime: .zero)
        let renderer = KaraokeRenderer(scene: scene)
        let n = max(1, Int((scene.totalS / max(rate, 0.01) * Double(fps)).rounded(.up)))
        for k in 0..<n {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError(errorDescription: "vidéo : tampon indisponible") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw ExportError(errorDescription: "vidéo : tampon indisponible") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            renderer.draw(at: Double(k) / Double(fps) * rate, in: ctx, size: CGSize(width: w, height: h),
                          layout: layout, transpose: transpose)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: fps))
            if !progress(Double(k + 1) / Double(n)) {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(n), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw ExportError(errorDescription: "vidéo : \(writer.error?.localizedDescription ?? "échec de l'encodage")")
        }
    }
}
