import CoreGraphics

/// Where the separate lyrics video opens: on a screen the main window is not on (the largest), for the show.
public enum VideoWindowPlacement {
    /// The show screen's index, or nil with a single screen (the window then reopens where it was left).
    public static func showScreen(screens: [CGRect], mainWindowScreen: Int?) -> Int? {
        let main = mainWindowScreen ?? 0
        return screens.indices.filter { $0 != main }.max { screens[$0].width * screens[$0].height < screens[$1].width * screens[$1].height }
    }

    /// The first-time frame: 16:9, centred.
    public static func centred(in screen: CGRect, width: CGFloat) -> CGRect {
        let size = CGSize(width: width, height: (width * 9 / 16).rounded())
        return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }
}
