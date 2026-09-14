import SwiftUI

/// One accent, system neutrals, nothing else. Status is never carried by colour alone:
/// every dot sits next to a word.
enum Theme {
    /// Terracotta. Reads as warm on the light surface and still separates from the
    /// neutral greys by lightness, which matters for colour-blind readers.
    static let accent = Color(red: 0.78, green: 0.36, blue: 0.22)
    static let artworkRadius: CGFloat = 8
    static let rowArtworkSize: CGFloat = 52
}
