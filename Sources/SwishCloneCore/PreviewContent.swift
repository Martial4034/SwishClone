import CoreGraphics

/// **Ce que le panneau d'aperçu dessine**, déduit de ce que la machine
/// annonce — sans AppKit, pour être testé.
///
/// Le rectangle d'une zone vient de `WindowLayout.frame(for:in:)` appliqué à
/// un écran de référence, ramené à l'unité : **le même calcul que l'action
/// réelle**. L'aperçu ne
/// peut donc pas montrer autre chose que ce que fera le lever.
public enum PreviewContent: Equatable, Sendable {
    /// La zone visée, dans un écran unitaire (0…1, origine en haut à gauche).
    case zone(CGRect)
    /// Un feu tricolore de macOS, redessiné : rouge pour fermer, jaune pour
    /// réduire, vert pour le plein écran.
    case light(TrafficLight)
    /// Le feu rouge, avec l'icône de l'app en petit dans son coin : quitter
    /// une app se distingue de fermer une fenêtre. L'hôte fournit l'icône.
    case quitApp
    /// Une séquence sans action : le lever ne fera rien.
    case unrecognized

    public init(_ preview: GestureStateMachine.Preview) {
        guard case let .action(action) = preview else {
            self = .unrecognized
            return
        }
        switch action {
        case .minimize: self = .light(.minimize)
        case .toggleFullScreen: self = .light(.fullScreen)
        case .close: self = .light(.close)
        case .quitApp: self = .quitApp
        default:
            // Un écran de 1 000 points ramené à 1 : `WindowLayout` partage
            // au point entier, ce qui n'aurait pas de sens sur 1 × 1.
            let side: CGFloat = 1000
            let reference = CGRect(x: 0, y: 0, width: side, height: side)
            self = WindowLayout.frame(for: action, in: reference).map {
                PreviewContent.zone(CGRect(x: $0.minX / side, y: $0.minY / side,
                                           width: $0.width / side, height: $0.height / side))
            } ?? .unrecognized
        }
    }
}

/// Les trois boutons de fenêtre de macOS, tels que le panneau les
/// redessine (couleurs et tracés dans `GesturePreviewPanel`).
public enum TrafficLight: Equatable, Sendable {
    case close, minimize, fullScreen
}

extension GestureStateMachine.Preview {

    /// Ce que le panneau montre, dit en mots. Le panneau compact ne
    /// l'affiche pas ; c'est son étiquette VoiceOver, et le texte des logs.
    public func label(appName: String? = nil) -> String {
        guard case let .action(action) = self else { return "Aucune action" }
        return action.label(appName: appName)
    }
}

extension GestureAction {

    /// Le nom de l'action, tel qu'un hôte l'affiche (aperçu, carte de geste).
    public func label(appName: String? = nil) -> String {
        switch self {
        case .leftHalf: return "Moitié gauche"
        case .rightHalf: return "Moitié droite"
        case .topHalf: return "Moitié haute"
        case .bottomHalf: return "Moitié basse"
        case .topLeftQuarter: return "Quart en haut à gauche"
        case .topRightQuarter: return "Quart en haut à droite"
        case .bottomLeftQuarter: return "Quart en bas à gauche"
        case .bottomRightQuarter: return "Quart en bas à droite"
        case .maximize: return "Remplir l'écran"
        case .minimize: return "Réduire dans le Dock"
        case .toggleFullScreen: return "Plein écran"
        case .close: return "Fermer la fenêtre"
        case .centerReduced: return "Centrer"
        case .quitApp: return "Quitter \(appName ?? "l'app")"
        }
    }
}

/// **Où poser le panneau** : au centre de la zone utile de l'écran de la
/// cible, façon HUD système — entre la barre de menus et le Dock. En
/// coordonnées AX (origine en haut à gauche).
public enum PreviewPlacement {

    /// L'écran de la cible : celui de la fenêtre visée (son centre, sinon
    /// sa plus grande part), ou, sans fenêtre — une icône du Dock —, celui
    /// du curseur.
    public static func screenIndex(targetFrame: CGRect?, cursor: CGPoint, screens: [CGRect]) -> Int? {
        if let targetFrame, let index = ScreenGeometry.screenIndex(for: targetFrame, among: screens) {
            return index
        }
        let probe = CGRect(x: cursor.x, y: cursor.y, width: 1, height: 1)
        return ScreenGeometry.screenIndex(for: probe, among: screens)
    }

    /// Centré dans `visible`, la zone utile de cet écran.
    public static func frame(size: CGSize, centeredIn visible: CGRect) -> CGRect {
        CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
