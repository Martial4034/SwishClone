import CoreGraphics

/// Les quatre moitiés d'écran, celles qui ont une moitié complémentaire.
public enum HalfZone: Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// `nil` pour tout ce qui n'est pas une moitié (quarts, remplir…).
    public init?(_ action: GestureAction) {
        switch action {
        case .leftHalf: self = .left
        case .rightHalf: self = .right
        case .topHalf: self = .top
        case .bottomHalf: self = .bottom
        default: return nil
        }
    }

    public var complement: HalfZone {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    public var action: GestureAction {
        switch self {
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .topHalf
        case .bottom: return .bottomHalf
        }
    }
}

/// **Placement complémentaire** : une moitié se cale sur le bord RÉEL de la
/// fenêtre qui occupe déjà la moitié d'en face, plutôt que sur les 50 %
/// théoriques — pour que les deux se touchent, sans chevauchement ni vide.
///
/// Cas d'origine : TextEdit en moitié droite a une largeur minimale plus
/// grande que la moitié ; l'anti-débordement l'a repoussé vers la gauche.
/// Une fenêtre placée ensuite en moitié gauche, sur les 50 % théoriques,
/// passait en partie dessous. Dans l'autre sens, une app plus étroite que
/// la moitié laissait un vide : la règle est symétrique.
///
/// Pure : l'occupant arrive déjà validé (voir `PlacementValidation`).
public enum ComplementaryLayout {

    /// En dessous de cette part de la zone utile, la nouvelle fenêtre serait
    /// trop étroite (ou trop basse) pour servir : on revient au théorique.
    public static let minimumShare: CGFloat = 0.25

    /// Écart toléré entre l'occupant et le bord extérieur de sa zone : les
    /// apps arrondissent au point entier.
    public static let edgeTolerance: CGFloat = 2

    /// - Parameter occupant: le cadre réel actuel de la fenêtre qui occupe
    ///   la moitié complémentaire, ou `nil` s'il n'y en a pas de valide.
    public static func frame(for zone: HalfZone, in visible: CGRect, occupant: CGRect?) -> CGRect {
        let theoretical = WindowLayout.frame(for: zone.action, in: visible)!
        guard let occupant, isAnchored(occupant, in: zone.complement, of: visible) else { return theoretical }

        let result: CGRect
        switch zone {
        case .left:
            result = CGRect(x: visible.minX, y: theoretical.minY,
                            width: occupant.minX - visible.minX, height: theoretical.height)
        case .right:
            result = CGRect(x: occupant.maxX, y: theoretical.minY,
                            width: visible.maxX - occupant.maxX, height: theoretical.height)
        case .top:
            result = CGRect(x: theoretical.minX, y: visible.minY,
                            width: theoretical.width, height: occupant.minY - visible.minY)
        case .bottom:
            result = CGRect(x: theoretical.minX, y: occupant.maxY,
                            width: theoretical.width, height: visible.maxY - occupant.maxY)
        }

        let share: CGFloat
        switch zone {
        case .left, .right: share = result.width / visible.width
        case .top, .bottom: share = result.height / visible.height
        }
        return share >= minimumShare ? result : theoretical
    }

    /// **Où recoller la fenêtre de `zone` sur sa voisine**, qui vient de
    /// prendre son cadre final (`neighbor`, dans la moitié d'en face) :
    /// `nil` si elles se touchent déjà, ou si le recollage la ferait
    /// retomber sur la moitié théorique (voisine partie, ou moins de 25 %).
    ///
    /// Le placement complémentaire cale une moitié sur sa voisine au moment
    /// où on la place. Si c'est la voisine, placée ensuite, qui ne prend pas
    /// exactement sa moitié — plus haute que demandé puis remontée pour ne
    /// pas passer sous le Dock, ou arrondie à sa grille —, la première ne la
    /// touche plus.
    public static func restuckFrame(for zone: HalfZone, in visible: CGRect, current: CGRect, neighbor: CGRect) -> CGRect? {
        let facing = innerEdge(of: neighbor, in: zone.complement)
        guard abs(innerEdge(of: current, in: zone) - facing) > contactTolerance else { return nil }
        let target = frame(for: zone, in: visible, occupant: neighbor)
        guard abs(innerEdge(of: target, in: zone) - facing) <= contactTolerance else { return nil }
        return target
    }

    /// En deçà, deux bords se touchent (arrondi au point).
    static let contactTolerance: CGFloat = 1

    /// Le bord d'une fenêtre tourné vers la moitié d'en face.
    static func innerEdge(of frame: CGRect, in zone: HalfZone) -> CGFloat {
        switch zone {
        case .left: return frame.maxX
        case .right: return frame.minX
        case .top: return frame.maxY
        case .bottom: return frame.minY
        }
    }

    /// L'occupant est-il toujours calé sur le bord extérieur de sa zone (le
    /// bord droit de l'écran pour une moitié droite) ? Sinon il n'occupe plus
    /// la zone, et son bord intérieur ne veut plus rien dire.
    static func isAnchored(_ frame: CGRect, in zone: HalfZone, of visible: CGRect) -> Bool {
        switch zone {
        case .left: return abs(frame.minX - visible.minX) <= edgeTolerance
        case .right: return abs(frame.maxX - visible.maxX) <= edgeTolerance
        case .top: return abs(frame.minY - visible.minY) <= edgeTolerance
        case .bottom: return abs(frame.maxY - visible.maxY) <= edgeTolerance
        }
    }
}

/// **La fenêtre mémorisée occupe-t-elle toujours sa zone ?**
///
/// Le critère est simple et ne demande aucune surveillance en continu : son
/// cadre actuel doit être celui qu'on a constaté après l'avoir placée, à
/// `moveTolerance` près. Déplacée ou redimensionnée à la main, fermée,
/// réduite, en plein écran natif : elle ne compte plus, et le placement
/// retombe sur le théorique.
public enum PlacementValidation {

    public static let moveTolerance: CGFloat = 2

    /// - Parameter actual: le cadre lu maintenant ; `nil` si illisible
    ///   (fenêtre fermée).
    public static func isStillPlaced(
        recorded: CGRect,
        actual: CGRect?,
        isMinimized: Bool,
        isFullScreen: Bool
    ) -> Bool {
        guard let actual, isMinimized == false, isFullScreen == false else { return false }
        return abs(actual.minX - recorded.minX) <= moveTolerance
            && abs(actual.minY - recorded.minY) <= moveTolerance
            && abs(actual.width - recorded.width) <= moveTolerance
            && abs(actual.height - recorded.height) <= moveTolerance
    }
}
