import CoreGraphics

/// La géométrie des écrans et des fenêtres, **en coordonnées AX** : origine
/// en haut à gauche de l'écran principal, y croissant vers le bas. C'est
/// l'espace dans lequel l'API Accessibility lit et écrit les fenêtres ; tout
/// ce qui vient d'AppKit (`NSScreen`, origine en bas à gauche) y est converti
/// une fois, à l'entrée, par `ScreenGeometry.axRect`.
public enum ScreenGeometry {

    /// Convertit un rectangle AppKit en rectangle AX.
    ///
    /// La référence est la hauteur de l'écran **principal** (celui qui porte
    /// la barre de menus, `NSScreen.screens.first`), ancre des deux espaces —
    /// pas `NSScreen.main`, qui désigne l'écran de la fenêtre active.
    public static func axRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// L'inverse, pour poser une fenêtre AppKit à un cadre calculé en AX. La
    /// formule est la même : le changement d'origine est sa propre inverse.
    public static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        axRect(fromCocoa: rect, primaryScreenHeight: primaryScreenHeight)
    }

    /// L'écran qui porte la fenêtre : celui qui contient son centre, sinon
    /// celui qui en recouvre la plus grande part. `nil` si aucun (fenêtre
    /// entièrement hors écran).
    public static func screenIndex(for windowFrame: CGRect, among screens: [CGRect]) -> Int? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let index = screens.firstIndex(where: { $0.contains(center) }) {
            return index
        }
        let overlaps = screens.map { screen -> CGFloat in
            let intersection = screen.intersection(windowFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
              overlaps[best] > 0 else { return nil }
        return best
    }
}

/// Le cadre visé par une action, dans la zone utile d'un écran (sans la
/// barre de menus ni le Dock), en coordonnées AX.
public enum WindowLayout {

    /// Fraction de l'écran occupée par `centerReduced`.
    public static let reducedScale: CGFloat = 0.6

    /// `nil` pour les actions qui ne sont pas un cadre (réduire, plein écran
    /// natif, fermer) : `WindowController` les traite à part.
    ///
    /// **Le partage tombe sur un point entier.** Une zone utile de 805 pt de
    /// haut donnait deux moitiés de 402,5 : les apps arrondissent chacune de
    /// leur côté (TextEdit prend 403 et dépasse d'un point vers le Dock), et
    /// les deux moitiés ne se touchaient plus exactement. La première moitié
    /// prend l'arrondi inférieur, la seconde le reste.
    public static func frame(for action: GestureAction, in visible: CGRect) -> CGRect? {
        let left = visible.minX
        let right = (visible.minX + visible.width / 2).rounded(.down)
        let top = visible.minY
        let bottom = (visible.minY + visible.height / 2).rounded(.down)
        let firstWidth = right - left
        let secondWidth = visible.maxX - right
        let firstHeight = bottom - top
        let secondHeight = visible.maxY - bottom

        switch action {
        case .leftHalf:
            return CGRect(x: left, y: top, width: firstWidth, height: visible.height)
        case .rightHalf:
            return CGRect(x: right, y: top, width: secondWidth, height: visible.height)
        case .topHalf:
            return CGRect(x: left, y: top, width: visible.width, height: firstHeight)
        case .bottomHalf:
            return CGRect(x: left, y: bottom, width: visible.width, height: secondHeight)
        case .topLeftQuarter:
            return CGRect(x: left, y: top, width: firstWidth, height: firstHeight)
        case .topRightQuarter:
            return CGRect(x: right, y: top, width: secondWidth, height: firstHeight)
        case .bottomLeftQuarter:
            return CGRect(x: left, y: bottom, width: firstWidth, height: secondHeight)
        case .bottomRightQuarter:
            return CGRect(x: right, y: bottom, width: secondWidth, height: secondHeight)
        case .maximize:
            return visible
        case .centerReduced:
            let width = visible.width * reducedScale
            let height = visible.height * reducedScale
            return CGRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
        case .minimize, .toggleFullScreen, .close, .quitApp:
            return nil
        }
    }

    // MARK: - Fenêtres qui refusent la taille demandée

    /// En dessous, un débordement est un arrondi, pas un débordement : les
    /// apps posent leurs fenêtres au point entier (402,5 demandé, 403 reçu).
    public static let overflowTolerance: CGFloat = 1

    /// **Le cadre réel ramené dans la zone utile, par simple translation**,
    /// ou `nil` s'il y tient déjà.
    ///
    /// Certaines apps ont une taille minimale plus grande que ce qu'on leur
    /// demande (Claude avec son panneau d'historique ouvert, par exemple) :
    /// elles se réajustent après coup et débordent de l'écran. La taille est
    /// leur décision — on n'y touche pas. On ne corrige que la position, en
    /// ancrant la fenêtre du côté où elle déborde : bord droit sur le bord
    /// droit de l'écran si elle dépasse à droite, et ainsi de suite.
    ///
    /// Plus grande que la zone utile sur un axe, elle ne peut pas y tenir :
    /// on garde alors son **début** visible — le bord gauche, où sont les
    /// feux tricolores, et le haut, où est la barre de titre.
    public static func correctedFrame(for actual: CGRect, in visible: CGRect) -> CGRect? {
        let x = fitted(start: actual.minX, length: actual.width, lower: visible.minX, upper: visible.maxX)
        let y = fitted(start: actual.minY, length: actual.height, lower: visible.minY, upper: visible.maxY)
        guard x != actual.minX || y != actual.minY else { return nil }
        return CGRect(x: x, y: y, width: actual.width, height: actual.height)
    }

    private static func fitted(start: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if length > upper - lower + overflowTolerance {
            return start == lower ? start : lower
        }
        if start + length > upper + overflowTolerance { return upper - length }
        if start < lower - overflowTolerance { return lower }
        return start
    }
}
