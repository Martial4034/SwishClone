/// La table qui traduit une séquence d'étapes en action, selon la cible.
///
/// Séparée de la machine à états pour que le catalogue puisse grandir
/// (tiers, fermer, quitter…) sans toucher à la mécanique du geste : la
/// machine dit « l'utilisateur a fait ↓ puis → », cette table dit « quart
/// en bas à droite ».
public enum GestureSequence {

    public enum Family: Equatable, Sendable {
        case swipe, pinch
    }

    /// Une famille de gestes a-t-elle au moins une action **active** sur
    /// cette cible ? Sinon, la machine ne capture pas le geste et le laisse à
    /// l'app (le Dock, pour un swipe sur une icône ; la page, quand tous les
    /// glissés sont désactivés) — à l'étape 5, un geste capturé sera avalé.
    ///
    /// Tiré du catalogue plutôt que d'une table à part : un geste ajouté au
    /// catalogue ouvre sa cible, un geste désactivé la referme.
    public static func accepts(_ family: Family, on kind: GestureTargetKind, disabled: Set<GestureAction> = []) -> Bool {
        GestureCatalog.hasEnabledAction(family, on: kind, disabled: disabled)
    }

    /// L'état de l'enchaînement, rejoué étape par étape.
    ///
    /// Séparé de `resolve` pour se tester seul. Deux axes, chacun avec sa
    /// direction courante, et `hasCombined` : vrai dès que les deux axes ont
    /// été actifs ensemble, et jamais remis à faux. C'est ce drapeau — pas la
    /// valeur courante des axes — qui distingue un vrai quart sur lequel on
    /// change d'avis d'un axe unique qui oscille (↑↓), lequel reste sans
    /// action.
    struct Chain: Equatable {
        var horizontal: SwipeDirection?
        var vertical: SwipeDirection?
        var hasCombined = false
        /// La dernière étape traitée, pour repérer deux étapes verticales
        /// identiques COLLÉES : une étape horizontale entre les deux casse
        /// la consécutivité.
        private var lastStep: SwipeDirection?

        init(_ steps: [SwipeDirection]) {
            for step in steps { apply(step) }
        }

        private mutating func apply(_ step: SwipeDirection) {
            switch step {
            case .left, .right:
                // Inverser l'horizontale sur un vrai quart efface la
                // verticale : on repart de la seule nouvelle direction
                // (↑ → ← donne la moitié gauche, pas le quart haut-gauche).
                // La verticale, elle, se combine toujours normalement : le
                // dernier ↑/↓ gagne sans toucher à l'horizontale.
                if hasCombined, let current = horizontal, current != step {
                    vertical = nil
                }
                horizontal = step
            case .up, .down:
                vertical = step
                // Deux ↑ (ou deux ↓) d'affilée forcent le retour à la moitié
                // correspondante, même sur un quart déjà construit : on
                // efface l'horizontale. Réservé à la verticale — ←← et →→
                // ne changent rien.
                if lastStep == step { horizontal = nil }
            }
            lastStep = step
            if horizontal != nil, vertical != nil { hasCombined = true }
        }
    }

    /// `nil` pour une séquence qui ne correspond à rien : l'aperçu l'annonce,
    /// et le lever ne fait rien.
    ///
    /// L'enchaînement est illimité, sans lever les doigts : on peut changer
    /// d'avis autant de fois qu'on veut.
    public static func resolve(swipes steps: [SwipeDirection], on kind: GestureTargetKind = .titlebar) -> GestureAction? {
        guard kind == .titlebar else { return nil }

        let chain = Chain(steps)

        // Jamais combiné : un seul axe. La table exacte, et rien d'autre —
        // ↑↓ ou ←→ (changer d'avis sans jamais avoir combiné) restent sans
        // action, pour que ↑↑ et ↓↓ gardent leur sens de moitiés.
        guard chain.hasCombined else {
            switch steps {
            case [.left]: return .leftHalf
            case [.right]: return .rightHalf
            case [.up]: return .maximize
            case [.down]: return .minimize
            case [.up, .up]: return .topHalf
            case [.down, .down]: return .bottomHalf
            default: return nil
            }
        }

        // Combiné : la direction courante de chaque axe. Quarts dans
        // n'importe quel ordre (« Both orders work », Swish) ; un axe seul,
        // après qu'une inversion horizontale a effacé la verticale ou qu'un
        // double vertical a effacé l'horizontale, est une moitié.
        switch (chain.horizontal, chain.vertical) {
        case (.left?, .up?): return .topLeftQuarter
        case (.right?, .up?): return .topRightQuarter
        case (.left?, .down?): return .bottomLeftQuarter
        case (.right?, .down?): return .bottomRightQuarter
        case (.left?, nil): return .leftHalf
        case (.right?, nil): return .rightHalf
        case (nil, .up?): return .topHalf
        case (nil, .down?): return .bottomHalf
        default: return nil
        }
    }

    public static func resolve(pinches steps: [PinchDirection], on kind: GestureTargetKind = .titlebar) -> GestureAction? {
        switch (kind, steps) {
        case (.titlebar, [.out]): return .toggleFullScreen
        // Comme Swish : resserrer ferme. Resserrer deux fois (quitter l'app)
        // attend le P1, et une phase de pincement lisible.
        case (.titlebar, [.in_]): return .close
        // Sur une icône du Dock, resserrer quitte l'app (Swish, onglet Apps).
        // Écarter (nouvelle fenêtre, chez Swish) viendra plus tard.
        case (.dockApp, [.in_]): return .quitApp
        default: return nil
        }
    }
}
