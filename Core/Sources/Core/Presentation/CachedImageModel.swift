import CoreStorage
import Foundation
import ImageIO
import Observation
import UIKit

@MainActor @Observable
final class CachedImageViewModel {
    fileprivate(set) var image: UIImage?
    fileprivate(set) var error: String?
    private var operation = UUID()

    fileprivate func begin() -> UUID {
        operation = UUID()
        image = nil
        error = nil
        return operation
    }

    fileprivate func finish(_ id: UUID, image: UIImage?, error: String?) {
        guard operation == id else { return }
        self.image = image
        self.error = error
    }
}

actor CachedImageModel {
    nonisolated let viewModel: CachedImageViewModel

    @MainActor init() { viewModel = CachedImageViewModel() }

    func load(url: URL?, thumbnail: Bool) async {
        guard !Task.isCancelled else { return }
        let current = await viewModel.begin()
        guard let url else { return }
        do {
            let data = try await ImageCache.shared.data(for: url, priority: thumbnail ? .thumbnail : .reading)
            try Task.checkCancellation()
            let decoded: UIImage?
            if thumbnail, let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                decoded = UIImage(cgImage: image)
            } else { decoded = UIImage(data: data) }
            try Task.checkCancellation()
            await viewModel.finish(current, image: decoded,
                error: decoded == nil ? L10n.text("Cover.UnsupportedImageFormat") : nil)
        } catch {
            if !Task.isCancelled { await viewModel.finish(current, image: nil, error: error.localizedDescription) }
        }
    }
}
