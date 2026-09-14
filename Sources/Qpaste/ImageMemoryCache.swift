import AppKit

/// Decoded image costs are bounded explicitly. NSCache may discard even the
/// image just returned by an async load, sending the view back into loading.
@MainActor
final class ImageMemoryCache {
    let maximumBytes: Int
    private struct Value { let image: NSImage; let bytes: Int; var used: UInt64 }
    private var values: [String: Value] = [:]
    private var clock: UInt64 = 0
    private(set) var byteCount = 0

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func value(for name: String) -> NSImage? {
        guard var value = values[name] else { return nil }
        clock &+= 1; value.used = clock; values[name] = value
        return value.image
    }

    func insert(_ image: NSImage, for name: String) {
        if let previous = values.removeValue(forKey: name) { byteCount -= previous.bytes }
        let bytes = max(1, Int(image.size.width * image.size.height) * 4)
        guard bytes <= maximumBytes else { return }
        while byteCount + bytes > maximumBytes || values.count >= 256 {
            guard let oldest = values.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = values.removeValue(forKey: oldest) else { break }
            byteCount -= removed.bytes
        }
        clock &+= 1
        values[name] = Value(image: image, bytes: bytes, used: clock)
        byteCount += bytes
    }
}
