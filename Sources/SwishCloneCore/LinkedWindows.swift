import CoreGraphics

/// L'orientation de la frontière entre deux fenêtres liées.
public enum LinkAxis: Hashable, Sendable {
    /// Gauche | droite : la frontière est verticale et se déplace en x.
    case vertical
    /// Haut / bas : la frontière est horizontale et se déplace en y.
    case horizontal
}

/// Le bord commun de deux fenêtres liées, en coordonnées AX.
public struct LinkedBorder: Equatable, Sendable {
    public var axis: LinkAxis
    /// x (frontière verticale) ou y (horizontale) du bord commun.
    public var position: CGFloat
    /// La partie du bord où les deux fenêtres se font face, sur l'autre axe.
    public var spanStart: CGFloat
    public var spanEnd: CGFloat

    /// La bande qu'on peut saisir : `LinkedPair.handleHalfThickness` de part
    /// et d'autre du bord, sur la longueur où les fenêtres se font face.
    public var handleRect: CGRect {
        let half = LinkedPair.handleHalfThickness
        switch axis {
        case .vertical:
            return CGRect(x: position - half, y: spanStart, width: 2 * half, height: spanEnd - spanStart)
        case .horizontal:
            return CGRect(x: spanStart, y: position - half, width: spanEnd - spanStart, height: 2 * half)
        }
    }
}

/// **Deux fenêtres liées** : les deux moitiés complémentaires d'un écran,
/// qui se touchent. Leur bord commun se saisit pour redimensionner les deux
/// à la fois (« Resize Adjacent Windows » de Swish).
public enum LinkedPair {

    /// Écart toléré entre les deux bords, vide ou chevauchement : les apps
    /// arrondissent au point entier (même valeur que le placement
    /// complémentaire).
    public static let contactTolerance: CGFloat = 2

    /// Demi-épaisseur de la bande saisissable : 8 pt en tout, un peu plus
    /// que la poignée native de macOS, pour la couvrir entièrement.
    public static let handleHalfThickness: CGFloat = 4

    /// En dessous, les fenêtres se font à peine face : pas de frontière.
    public static let minimumSpan: CGFloat = 40

    /// Écart toléré entre une fenêtre et le bord extérieur de sa moitié.
    /// Large : Terminal arrondit sa hauteur à la ligne de texte, et laisse
    /// quelques points de vide sous une moitié basse.
    public static let anchorTolerance: CGFloat = 24

    /// **La fenêtre tient-elle encore sa moitié ?** Collée au bord extérieur
    /// de sa zone (le bord gauche de l'écran pour une moitié gauche).
    ///
    /// Plus souple que `PlacementValidation`, qui exige le cadre exact
    /// constaté après le placement : une app qui se réajuste un peu plus tard
    /// (Terminal) aurait dissous la paire sans que rien ne bouge à l'écran —
    /// la frontière cessait alors de répondre, puis remarchait après un
    /// nouveau placement. Qu'elles se touchent encore, `border` le vérifie.
    public static func isAnchored(_ frame: CGRect, in zone: HalfZone, of visible: CGRect) -> Bool {
        switch zone {
        case .left: return abs(frame.minX - visible.minX) <= anchorTolerance
        case .right: return abs(frame.maxX - visible.maxX) <= anchorTolerance
        case .top: return abs(frame.minY - visible.minY) <= anchorTolerance
        case .bottom: return abs(frame.maxY - visible.maxY) <= anchorTolerance
        }
    }

    /// - Parameters:
    ///   - first: la fenêtre de gauche (frontière verticale) ou du haut.
    ///   - second: celle de droite ou du bas.
    /// - Returns: `nil` si elles ne se touchent pas.
    public static func border(between first: CGRect, and second: CGRect, axis: LinkAxis) -> LinkedBorder? {
        let firstEnd = first.maxAlong(axis)
        let secondStart = second.minAlong(axis)
        guard abs(secondStart - firstEnd) <= contactTolerance else { return nil }

        let spanStart = max(first.minAcross(axis), second.minAcross(axis))
        let spanEnd = min(first.maxAcross(axis), second.maxAcross(axis))
        guard spanEnd - spanStart >= minimumSpan else { return nil }

        return LinkedBorder(axis: axis, position: (firstEnd + secondStart) / 2, spanStart: spanStart, spanEnd: spanEnd)
    }
}

/// **Un glissé de frontière en cours** : où poser la frontière, et les deux
/// cadres qui en découlent.
///
/// Chaque fenêtre garde son bord extérieur ; seule la frontière bouge. Les
/// deux fenêtres restent donc dans leur étendue d'origine — donc dans la
/// zone utile — sans avoir à la connaître.
///
/// Une app ne prend pas toujours la taille demandée : taille minimale
/// (TextEdit), ou taille arrondie à sa grille (Terminal, au caractère près).
/// macOS n'expose ni l'une ni l'autre : après chaque écriture, on relit, et
/// la frontière se recale sur la taille réellement prise (`settledBorder`).
public struct LinkedResize: Sendable {

    public enum Side: Sendable { case first, second }

    /// Plancher, en points, en dessous duquel on ne rétrécit jamais une
    /// fenêtre, même si l'app l'accepterait : elle ne servirait plus à rien.
    public static let minimumExtent: CGFloat = 120

    /// Écart, en points, au-delà duquel la taille reçue n'est plus celle
    /// demandée (en deçà : arrondi au point).
    public static let sizeTolerance: CGFloat = 1

    public let axis: LinkAxis
    public let originalFirst: CGRect
    public let originalSecond: CGRect
    public let minimumFirst: CGFloat
    public let minimumSecond: CGFloat

    public init(axis: LinkAxis, first: CGRect, second: CGRect) {
        self.axis = axis
        originalFirst = first
        originalSecond = second
        // Jamais plus que la taille de départ : la frontière de départ reste
        // toujours atteignable, même pour une fenêtre déjà très étroite.
        minimumFirst = min(Self.minimumExtent, first.extentAlong(axis))
        minimumSecond = min(Self.minimumExtent, second.extentAlong(axis))
    }

    /// La frontière au début du glissé : entre les deux bords, s'ils ne se
    /// touchaient qu'à `contactTolerance` près.
    public var startBorder: CGFloat {
        (originalFirst.maxAlong(axis) + originalSecond.minAlong(axis)) / 2
    }

    /// La frontière demandée, bornée pour que chaque fenêtre garde au moins
    /// le plancher.
    public func clampedBorder(_ proposed: CGFloat) -> CGFloat {
        let lower = originalFirst.minAlong(axis) + minimumFirst
        let upper = originalSecond.maxAlong(axis) - minimumSecond
        guard lower <= upper else { return startBorder }
        return min(max(proposed, lower), upper)
    }

    /// Les deux cadres pour une frontière demandée (bornée au passage) :
    /// collés, et d'étendue totale inchangée.
    public func frames(borderAt proposed: CGFloat) -> (first: CGRect, second: CGRect) {
        let border = clampedBorder(proposed)
        var first = originalFirst
        var second = originalSecond
        switch axis {
        case .vertical:
            first.size.width = border - originalFirst.minX
            second.origin.x = border
            second.size.width = originalSecond.maxX - border
        case .horizontal:
            first.size.height = border - originalFirst.minY
            second.origin.y = border
            second.size.height = originalSecond.maxY - border
        }
        return (first, second)
    }

    /// **Où la frontière s'est réellement posée**, d'après les tailles
    /// relues après l'écriture : `nil` si les deux fenêtres ont pris la
    /// taille demandée. Sinon, les cadres sont à réécrire pour cette
    /// frontière, que la fenêtre récalcitrante accepte déjà — l'autre vient
    /// s'y coller.
    ///
    /// **Rien n'est retenu d'un mouvement à l'autre.** Le mouvement suivant
    /// redemande une taille d'après la souris : une app qui arrondit à sa
    /// grille finit par passer au cran suivant, alors qu'un « minimum »
    /// appris sur un simple arrondi bloquerait la frontière pour de bon
    /// (constaté avec Terminal : on ne pouvait plus la ramener vers lui).
    ///
    /// Une fenêtre restée plus grande que demandé (minimum, ou arrondi vers
    /// le haut) a priorité : c'est une contrainte, l'autre doit céder.
    public func settledBorder(requested: (first: CGRect, second: CGRect), actualFirst: CGRect, actualSecond: CGRect) -> CGFloat? {
        let extraFirst = actualFirst.extentAlong(axis) - requested.first.extentAlong(axis)
        let extraSecond = actualSecond.extentAlong(axis) - requested.second.extentAlong(axis)
        let borderFromFirst = originalFirst.minAlong(axis) + actualFirst.extentAlong(axis)
        let borderFromSecond = originalSecond.maxAlong(axis) - actualSecond.extentAlong(axis)
        if extraFirst > Self.sizeTolerance { return borderFromFirst }
        if extraSecond > Self.sizeTolerance { return borderFromSecond }
        if extraFirst < -Self.sizeTolerance { return borderFromFirst }
        if extraSecond < -Self.sizeTolerance { return borderFromSecond }
        return nil
    }

    /// **L'ordre des écritures** : la fenêtre qui rétrécit d'abord, celle
    /// qui grandit ensuite. Au pire un vide d'une image entre les deux,
    /// jamais de chevauchement.
    public static func writeOrder(from oldBorder: CGFloat, to newBorder: CGFloat) -> [Side] {
        newBorder > oldBorder ? [.second, .first] : [.first, .second]
    }

    /// Pour une fenêtre qui rétrécit, la taille s'écrit avant la position :
    /// dans l'autre ordre, elle dépasserait un instant de son étendue (et de
    /// l'écran) avant de rétrécir.
    public static func resizesBeforeMoving(from old: CGRect, to new: CGRect) -> Bool {
        new.width * new.height < old.width * old.height
    }
}

// MARK: - Mesures selon l'axe

extension CGRect {
    /// L'axe du déplacement de la frontière.
    func minAlong(_ axis: LinkAxis) -> CGFloat { axis == .vertical ? minX : minY }
    func maxAlong(_ axis: LinkAxis) -> CGFloat { axis == .vertical ? maxX : maxY }
    func extentAlong(_ axis: LinkAxis) -> CGFloat { axis == .vertical ? width : height }
    /// L'autre axe : la longueur de la frontière.
    func minAcross(_ axis: LinkAxis) -> CGFloat { axis == .vertical ? minY : minX }
    func maxAcross(_ axis: LinkAxis) -> CGFloat { axis == .vertical ? maxY : maxX }
}
