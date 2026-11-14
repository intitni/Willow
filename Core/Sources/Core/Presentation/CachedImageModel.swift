import CoreStorage
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class CachedImageViewModel {
    fileprivate(set) var image: UIImage?
    fileprivate(set) var error: String?
    private var operation = UUID()
    private var currentURL: URL?
    private var currentPolicy: ImageCache.Policy = .byURL

    fileprivate func begin(url: URL?, policy: ImageCache.Policy, thumbnail: Bool) -> UUID? {
        guard !Task.isCancelled else { return nil }
        let sameCover = policy != .byURL && currentPolicy == policy
        if thumbnail, image != nil, policy == .byURL, currentPolicy == policy, currentURL == url { return nil }
        currentURL = url
        currentPolicy = policy
        operation = UUID()
        if !sameCover { image = nil }
        error = nil
        return operation
    }

    fileprivate func finish(_ id: UUID, image: UIImage?, error: String?) {
        guard operation == id else { return }
        if let image { self.image = image }
        self.error = error
    }
}

actor CachedImageModel {
    nonisolated let viewModel: CachedImageViewModel

    @MainActor init() { viewModel = CachedImageViewModel() }

    func load(url: URL?, policy: ImageCache.Policy, thumbnail: Bool) async {
        guard let current = await viewModel.begin(url: url, policy: policy, thumbnail: thumbnail) else { return }
        do {
            let priority: ImageCache.Priority = thumbnail ? .thumbnail : .reading
            guard let image = try await ImageCache.shared.load(for: url, priority: priority, policy: policy, decode: { data in
                if thumbnail {
                    return await ImageCache.decodeThumbnail(data).map { UIImage(cgImage: $0) }
                }
                return UIImage(data: data)
            }, showFallback: { image in
                guard !Task.isCancelled else { return }
                await self.viewModel.finish(current, image: image, error: nil)
            }) else { return }
            try Task.checkCancellation()
            await viewModel.finish(current, image: image, error: nil)
        } catch {
            if !Task.isCancelled {
                let message = (error as? URLError)?.code == .cannotDecodeContentData
                    ? L10n.text("Cover.UnsupportedImageFormat") : error.localizedDescription
                await viewModel.finish(current, image: nil, error: message)
            }
        }
    }
}
