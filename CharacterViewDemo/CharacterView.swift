//
//  CharacterView.swift
//  CharacterViewDemo
//
//  Created by Adam Lyttle on 25/2/2026.
//

import SwiftUI
import UIKit
import ImageIO
import MobileCoreServices


struct CharacterView: UIViewRepresentable {

    /// Prefix for the GIF filenames in your bundle.
    /// Example prefix "character" -> characterIdle.gif, characterDancing.gif...
    let filename: String

    @Binding var state: CharacterState

    var contentMode: UIView.ContentMode = .scaleAspectFit
    var preloadOnInit: Bool = true

    init(
        filename: String = "character",
        state: Binding<CharacterState>,
        contentMode: UIView.ContentMode = .scaleAspectFit,
        preloadOnInit: Bool = true
    ) {
        self.filename = filename
        self._state = state
        self.contentMode = contentMode
        self.preloadOnInit = preloadOnInit

        if preloadOnInit {
            GifCache.shared.preloadAll(prefix: filename)
        }
    }

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = contentMode
        iv.clipsToBounds = true
        iv.backgroundColor = .clear

        context.coordinator.lastState = state
        setImage(for: state, in: iv)

        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if context.coordinator.lastState != state {
            context.coordinator.lastState = state
            setImage(for: state, in: uiView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastState: CharacterState?
        var lastRequestedKey: String?
    }

    private func setImage(for state: CharacterState, in imageView: UIImageView) {
        
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 ) {
            let key = filename + state.gifBaseName
            
            // Prevent late async completion from an old request overwriting the new state.
            imageView.stopAnimating()
            (imageView.superview as Any?) // no-op; keeps function pure
            // Store request key
            // (coordinator isn't directly accessible here, so we do the simple safe approach:
            // we capture key and only apply if it still matches the latest key on the view)
            
            imageView.accessibilityIdentifier = key
            GifCache.shared.image(baseName: key) { animated in
                guard let animated else { return }
                // Only apply if this is still the latest requested animation for this view
                guard imageView.accessibilityIdentifier == key else { return }
                
                imageView.stopAnimating()
                imageView.image = nil
                imageView.animationImages = nil
                
                imageView.image = animated
                imageView.animationRepeatCount = 0 // loop forever
                imageView.startAnimating()
            }
//        }
    }
}

// MARK: - Example usage

struct DemoCharacterScreen: View {
    @State private var state: CharacterState = .idle

    var body: some View {
        VStack(spacing: 16) {
            CharacterView(filename: "character", state: $state)
                .frame(width: 300, height: 533)

            HStack {
                Button("Idle") { state = .idle }
                Button("Dance") { state = .dancing }
                Button("Level Up") { state = .levelUp }
                Button("Game Over") { state = .gameOver }
            }
        }
        .padding()
        // Optional (init already preloads). Keep if you want extra safety.
        .onAppear { GifCache.shared.preloadAll(prefix: "character") }
    }
}

// MARK: - State

enum CharacterState: String, CaseIterable, Hashable {
    case idle
    case dancing
    case levelUp
    case gameOver

    /// Suffix part of the filename (no extension)
    /// Full filename becomes: "<prefix><suffix>.gif"
    var gifBaseName: String {
        switch self {
        case .idle:     return "Idle"
        case .dancing:  return "Dancing"
        case .levelUp:  return "LevelUp"
        case .gameOver: return "GameOver"
        }
    }
}

// MARK: - GIF Cache / Loader

final class GifCache {
    static let shared = GifCache()

    private let queue = DispatchQueue(label: "gif.cache.decode", qos: .userInitiated)
    private var cache: [String: UIImage] = [:]
    private var inflight: Set<String> = []

    private init() {}

    /// Preload all states for a given filename prefix.
    /// Example: prefix "character" -> characterIdle.gif, characterDancing.gif...
    func preloadAll(prefix: String, in bundle: Bundle = .main) {
        CharacterState.allCases.forEach { state in
            preload(baseName: prefix + state.gifBaseName, bundle: bundle)
        }
    }

    func preload(baseName: String, bundle: Bundle = .main) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.cache[baseName] != nil { return }
            if self.inflight.contains(baseName) { return }
            self.inflight.insert(baseName)
            defer { self.inflight.remove(baseName) }

            guard let url = bundle.url(forResource: baseName, withExtension: "gif") else {
                assertionFailure("Missing gif in bundle: \(baseName).gif")
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                assertionFailure("Could not load gif data: \(baseName).gif")
                return
            }
            guard let image = Self.decodeGif(data: data) else {
                assertionFailure("Could not decode gif: \(baseName).gif")
                return
            }
            self.cache[baseName] = image
        }
    }

    func image(baseName: String, bundle: Bundle = .main, completion: @escaping (UIImage?) -> Void) {
        // Fast path
        if let img = cache[baseName] {
            completion(img)
            return
        }

        // Decode in background then return on main
        queue.async { [weak self] in
            guard let self else { return }
            if self.cache[baseName] == nil {
                guard let url = bundle.url(forResource: baseName, withExtension: "gif"),
                      let data = try? Data(contentsOf: url) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.cache[baseName] = Self.decodeGif(data: data)
            }
            let img = self.cache[baseName]
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: GIF decoding (ImageIO -> animated UIImage)

    private static func decodeGif(data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        var images: [UIImage] = []
        images.reserveCapacity(count)

        var totalDuration: Double = 0

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let frameDuration = gifFrameDuration(source: src, index: i)
            totalDuration += frameDuration
            images.append(UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up))
        }

        if totalDuration <= 0 {
            totalDuration = Double(images.count) * (1.0 / 12.0)
        }

        return UIImage.animatedImage(with: images, duration: totalDuration)
    }

    private static func gifFrameDuration(source: CGImageSource, index: Int) -> Double {
        let defaultFrame = 1.0 / 12.0

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return defaultFrame
        }

        let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double
        let d = unclamped ?? clamped ?? defaultFrame

        return (d < 0.02) ? defaultFrame : d
    }
}


#Preview {
    DemoCharacterScreen()
}
