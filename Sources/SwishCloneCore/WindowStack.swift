import CoreGraphics

/// **La fenêtre du dessus à un point donné**, d'après la pile du serveur de
/// fenêtres, sans rien demander à aucune app.
///
/// Sert de garde avant le test de cible par Accessibilité. Celui-ci
/// (`AXUIElementCopyElementAtPosition`) interroge l'app qui possède la fenêtre
/// sous le curseur — et quand cette app est **l'hôte lui-même**, macOS ne
/// passe par aucun autre processus : la question est traitée sur le thread
/// appelant, c'est-à-dire le thread du tap. AppKit et SwiftUI y reconstruisent
/// alors des vues hors du thread principal, et Swift 6 arrête l'app
/// (`dispatch_assert_queue`). Relevé le 27/09/2026 dans bran : un défilement
/// dans ses propres réglages le faisait quitter.
///
/// La pile, elle, se lit depuis n'importe quel thread
/// (`CGWindowListCopyWindowInfo`, ~0,5 ms mesuré) et ne touche à aucune app.
public enum WindowStack {

    public struct Window: Equatable, Sendable {
        public let pid: Int32
        /// En coordonnées globales, origine en haut à gauche (celles de
        /// `CGWindowList`, d'AX et de `CGEvent.location`).
        public let bounds: CGRect
        public let alpha: Double
        /// `kCGWindowLayer` : 0 pour une fenêtre d'app ordinaire.
        public let layer: Int

        public init(pid: Int32, bounds: CGRect, alpha: Double, layer: Int = 0) {
            self.pid = pid
            self.bounds = bounds
            self.alpha = alpha
            self.layer = layer
        }
    }

    /// Vrai si une fenêtre de l'hôte est **au-dessus de toute fenêtre
    /// ordinaire d'une autre app** à ce point, la pile étant donnée de
    /// l'avant vers l'arrière. Il ne faut alors **pas** interroger
    /// l'Accessibilité — et il n'y a de toute façon rien à ranger : l'hôte ne
    /// range pas ses propres fenêtres.
    ///
    /// **Les fenêtres des autres apps ne comptent qu'au niveau 0.** Le Dock
    /// tient en permanence une fenêtre transparente de la taille de l'écran
    /// (niveau 20, alpha 1, relevé le 27/09/2026) que l'Accessibilité
    /// traverse : la compter la placerait « au-dessus » de tout, et la garde ne
    /// servirait jamais. Les fenêtres de l'hôte, elles, comptent à tout niveau
    /// (panneaux, bandeaux, barre de menus). En cas de doute, la règle penche
    /// vers « ne pas interroger » : au pire un geste n'est pas vu, jamais un
    /// plantage.
    ///
    /// Une fenêtre entièrement transparente (alpha 0) ne compte pas.
    public static func isOwnWindowOnTop(at point: CGPoint, in windows: [Window], ownPID: Int32) -> Bool {
        let top = windows.first { window in
            window.alpha > 0
                && window.bounds.contains(point)
                && (window.pid == ownPID || window.layer == 0)
        }
        return top?.pid == ownPID
    }

    /// Une fenêtre visible de l'hôte contient-elle le point, **même cachée** ?
    ///
    /// Sans elle, l'élément système ne peut pas tomber sur l'hôte, quel que
    /// soit l'ordre qu'il suit : le test AX habituel est sûr par construction.
    public static func hasOwnWindow(at point: CGPoint, in windows: [Window], ownPID: Int32) -> Bool {
        windows.contains { $0.pid == ownPID && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// L'app de la première fenêtre ordinaire (couche 0) d'une autre app sous
    /// le point. Sert quand une fenêtre de l'hôte est dessous : le test AX se
    /// fait alors dans cette app seule, jamais dans l'élément système, qui
    /// pourrait traverser jusqu'à l'hôte si l'ordre de la liste et celui d'AX
    /// divergent.
    public static func frontmostOtherOwner(at point: CGPoint, in windows: [Window], ownPID: Int32) -> Int32? {
        windows.first { window in
            window.pid != ownPID && window.layer == 0 && window.alpha > 0 && window.bounds.contains(point)
        }?.pid
    }
}
