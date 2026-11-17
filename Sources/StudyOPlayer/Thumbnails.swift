import AVFoundation
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
final class ThumbnailGenerator: @unchecked Sendable { // shared state is behind `lock`
    private let queue = DispatchQueue(label: "studyoplayer.thumbnails", qos: .utility)
    private let lock = NSLock()
    private var generation = 0

    func cancel() { lock.lock(); generation += 1; lock.unlock() }

    /// Starts a new job, which makes any earlier one stop and drop its results.
    fileprivate func begin() -> Int { lock.lock(); defer { lock.unlock() }; generation += 1; return generation }

    /// Coarse to fine: frames spread over the whole video come first, then the gaps between
    /// them, so the strip looks complete early instead of filling from left to right.
    static func coarseToFine(_ count: Int) -> [Int] {
        var order: [Int] = []
        var taken = Set<Int>()
        for step in [16, 8, 4, 2, 1] {
            for i in stride(from: 0, to: count, by: step) where taken.insert(i).inserted { order.append(i) }
        }
        return order
    }

    fileprivate func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    /// Off-screen players working at once. Each decodes its own share of the frames, so the strip
    /// fills about this many times faster; three keeps the burst light on any Apple silicon Mac.
    private static let workers = 3

    func start(instance: OpaquePointer, url: URL, aspect: Double, count: Int,
               deliver: @escaping (Int, CGImage) -> Void) {
        let gen = begin()
        let order = Self.coarseToFine(count)
        let workers = min(Self.workers, count)
        queue.async { [self] in
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                let share = order.enumerated().filter { $0.offset % workers == w }.map(\.element)
                run(instance: instance, url: url, aspect: aspect, count: count, indices: share, gen: gen, deliver: deliver)
            }
        }
    }

    /// One off-screen player making the frames at `indices`.
    private func run(instance: OpaquePointer, url: URL, aspect: Double, count: Int, indices: [Int], gen: Int,
                     deliver: @escaping (Int, CGImage) -> Void) {
        do {
            let height = 60
            let width = max(40, min(200, Int((Double(height) * aspect).rounded()))) & ~1
            let ctx = FrameContext(width: width, height: height)
            guard let media = libvlc_media_new_path(instance, url.path) else { return }
            // Fast seek: jump to the nearest keyframe instead of decoding up to the exact time,
            // which is plenty for small previews and much quicker.
            for option in [":no-audio", ":no-spu", ":no-sub-autodetect-file", ":avcodec-hw=none", ":input-fast-seek"] {
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
                    for i in indices where isCurrent(gen) {
                        libvlc_media_player_set_time(mp, length * Int64(2 * i + 1) / Int64(2 * count))
                        usleep(60_000) // let frames from before the seek drain
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

// MARK: - Fast path (Apple's own decoder)

extension ThumbnailGenerator {
    /// Makes the frames with AVFoundation, which uses the Mac's hardware video decoder: for
    /// MP4, MOV and M4V the whole strip is ready in well under a second. `failed` is called when
    /// the file is a format AVFoundation cannot read (MKV, AVI…), so the libVLC path can take over.
    func startFast(url: URL, count: Int, deliver: @escaping (Int, CGImage) -> Void, failed: @escaping () -> Void) {
        let gen = begin()
        let asset = AVURLAsset(url: url)
        Task.detached(priority: .userInitiated) { [self] in
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
                  let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0
            else {
                DispatchQueue.main.async { if self.isCurrent(gen) { failed() } }
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 60)
            // Any frame within half a slot of the target will do: far quicker than an exact frame,
            // and neighbouring slots still show different moments.
            let slack = CMTime(seconds: duration.seconds / Double(2 * count), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = slack
            generator.requestedTimeToleranceAfter = slack
            let order = Self.coarseToFine(count)
            let times = order.map { CMTime(seconds: duration.seconds * Double(2 * $0 + 1) / Double(2 * count),
                                           preferredTimescale: 600) }
            var made = 0
            for await result in generator.images(for: times) {
                guard isCurrent(gen) else { break }
                guard let image = try? result.image,
                      let slot = times.firstIndex(where: { $0 == result.requestedTime }) else { continue }
                made += 1
                let index = order[slot]
                DispatchQueue.main.async { if self.isCurrent(gen) { deliver(index, image) } }
            }
            if made == 0 { DispatchQueue.main.async { if self.isCurrent(gen) { failed() } } }
        }
    }
}
