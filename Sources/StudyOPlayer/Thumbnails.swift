import CoreGraphics
import Foundation

/// Memory buffer libvlc renders small frames into.
private final class FrameContext {
    let width: Int, height: Int
    let buffer: UnsafeMutableRawPointer
    let pixelLock = NSLock()
    private let countLock = NSLock()
    private var displayed = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
    }
    deinit { buffer.deallocate() }

    func noteFrame() { countLock.lock(); displayed += 1; countLock.unlock() }
    var frames: Int { countLock.lock(); defer { countLock.unlock() }; return displayed }

    func makeImage() -> CGImage? {
        pixelLock.lock()
        let data = Data(bytes: buffer, count: width * height * 4)
        pixelLock.unlock()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Makes evenly spaced preview frames of a video for the Touch Bar, using a second, silent,
/// off-screen libvlc player so it works for every format the main player supports.
final class ThumbnailGenerator {
    private let queue = DispatchQueue(label: "studyoplayer.thumbnails", qos: .utility)
    private let lock = NSLock()
    private var generation = 0

    func cancel() { lock.lock(); generation += 1; lock.unlock() }

    private func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    func start(instance: OpaquePointer, url: URL, aspect: Double, count: Int,
               deliver: @escaping (Int, CGImage) -> Void) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        queue.async { [self] in
            let height = 60
            let width = max(40, min(200, Int((Double(height) * aspect).rounded()))) & ~1
            let ctx = FrameContext(width: width, height: height)
            guard let media = libvlc_media_new_path(instance, url.path) else { return }
            for option in [":no-audio", ":no-spu", ":no-sub-autodetect-file", ":avcodec-hw=none"] {
                libvlc_media_add_option(media, option)
            }
            guard let mp = libvlc_media_player_new(instance) else { libvlc_media_release(media); return }
            libvlc_media_player_set_media(mp, media)
            libvlc_media_release(media)

            libvlc_video_set_callbacks(mp, { opaque, planes in
                let c = Unmanaged<FrameContext>.fromOpaque(opaque!).takeUnretainedValue()
                c.pixelLock.lock()
                planes?.pointee = c.buffer
                return nil
            }, { opaque, _, _ in
                Unmanaged<FrameContext>.fromOpaque(opaque!).takeUnretainedValue().pixelLock.unlock()
            }, { opaque, _ in
                Unmanaged<FrameContext>.fromOpaque(opaque!).takeUnretainedValue().noteFrame()
            }, Unmanaged.passUnretained(ctx).toOpaque())
            libvlc_video_set_format(mp, "RV32", UInt32(width), UInt32(height), UInt32(width * 4))
            libvlc_media_player_play(mp)

            func waitForFrame(after mark: Int, timeout: Double) -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while ctx.frames <= mark {
                    if Date() > deadline || !isCurrent(gen) { return false }
                    usleep(20_000)
                }
                return true
            }

            if waitForFrame(after: 0, timeout: 6) {
                let length = libvlc_media_player_get_length(mp)
                if length > 0 {
                    for i in 0..<count where isCurrent(gen) {
                        libvlc_media_player_set_time(mp, length * Int64(2 * i + 1) / Int64(2 * count))
                        usleep(150_000) // let frames from before the seek drain
                        guard waitForFrame(after: ctx.frames, timeout: 1.5), let image = ctx.makeImage() else { continue }
                        DispatchQueue.main.async { if self.isCurrent(gen) { deliver(i, image) } }
                    }
                }
            }
            libvlc_media_player_stop(mp)
            libvlc_media_player_release(mp)
            withExtendedLifetime(ctx) {}
        }
    }
}
