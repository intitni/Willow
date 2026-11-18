import CorePresentation
import CoreStorage
import Foundation
import Observation
import UIKit

struct LoadedImage: Sendable {
    let bitmap: UIImage
    let originalSize: CGSize

    init(bitmap: UIImage, originalSize: CGSize? = nil) {
        self.bitmap = bitmap
        self.originalSize = originalSize ?? bitmap.size
    }
}

@MainActor @Observable
final class CachedImageViewModel {
    fileprivate(set) var image: LoadedImage?
    fileprivate(set) var error: String?
    private var operation = UUID()
    private var currentURL: URL?
    private var currentPolicy: ImageCache.Policy = .byURL
    private var loadedReaderImage: ReaderImage?

    fileprivate func begin(url: URL?, policy: ImageCache.Policy, thumbnail: Bool, readerImage: ReaderImage?) -> UUID? {
        guard !Task.isCancelled else { return nil }
        let sameCover = policy != .byURL && currentPolicy == policy
        let sameURL = policy == .byURL && currentPolicy == policy && currentURL == url
        operation = UUID()
        if sameURL, image != nil {
            if thumbnail { return nil }
            if let readerImage, loadedReaderImage == readerImage, error == nil { return nil }
        }
        currentURL = url
        currentPolicy = policy
        if !sameCover && !(sameURL && readerImage != nil) {
            image = nil
            loadedReaderImage = nil
        }
        error = nil
        return operation
    }

    fileprivate func finish(_ id: UUID, image: LoadedImage?, error: String?, readerImage: ReaderImage? = nil) {
        guard operation == id else { return }
        if let image {
            self.image = image
            loadedReaderImage = readerImage
        }
        self.error = error
    }
}

actor CachedImageModel {
    nonisolated let viewModel: CachedImageViewModel

    @MainActor init() { viewModel = CachedImageViewModel() }

    func load(url: URL?, policy: ImageCache.Policy, thumbnail: Bool, readerImage: ReaderImage?) async {
        guard let current = await viewModel.begin(url: url, policy: policy, thumbnail: thumbnail,
                                                  readerImage: readerImage) else { return }
        do {
            let priority: ImageCache.Priority = thumbnail ? .thumbnail : .reading
            guard let image = try await ImageCache.shared.load(for: url, priority: priority, policy: policy, decode: { data -> LoadedImage? in
                if thumbnail {
                    return await ImageCache.decodeThumbnail(data).map { LoadedImage(bitmap: UIImage(cgImage: $0)) }
                }
                if let readerImage, let image = await readerImage.decode(data) {
                    return LoadedImage(bitmap: UIImage(cgImage: image.bitmap), originalSize: image.originalSize)
                }
                return UIImage(data: data).map { LoadedImage(bitmap: $0) }
            }, showFallback: { image in
                guard !Task.isCancelled else { return }
                await self.viewModel.finish(current, image: image, error: nil)
            }) else { return }
            try Task.checkCancellation()
            await viewModel.finish(current, image: image, error: nil, readerImage: readerImage)
        } catch {
            if !Task.isCancelled {
                let message = (error as? URLError)?.code == .cannotDecodeContentData
                    ? L10n.text("Cover.UnsupportedImageFormat") : error.localizedDescription
                await viewModel.finish(current, image: nil, error: message)
            }
        }
    }
}
