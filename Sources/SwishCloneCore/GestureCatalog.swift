/// Ce qui déclenche une action : la suite d'étapes d'un même geste, sans
/// lever les doigts.
public enum GestureTrigger: Equatable, Sendable {
    case swipes([SwipeDirection])
    case pinches([PinchDirection])

    public var family: GestureSequence.Family {
        switch self {
        case .swipes: return .swipe
        case .pinches: return .pinch
        }
    }

    /// Le déclencheur en quelques caractères : « ← », « ↑↑ », « ↓ puis → »,
    /// « Écarter ». Deux fois la même direction se lit d'un bloc ; deux
    /// directions différentes demandent la pause, que « puis » rappelle.
    public var symbols: String {
        switch self {
        case let .swipes(steps):
            let arrows = steps.map(\.arrow)
            if Set(arrows).count == 1 { return arrows.joined() }
            return arrows.joined(separator: " puis ")
        case let .pinches(steps):
            return steps.map { $0 == .out ? "Écarter" : "Resserrer" }.joined(separator: " puis ")
        }
    }
}

extension SwipeDirection {
    public var arrow: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }
}

/// **La liste publique des gestes** : chaque action, sa cible et ce qui la
/// déclenche.
///
/// C'est ce qu'un hôte affiche (une carte par geste, une page d'aide) et ce
/// qu'il désactive geste par geste (`GestureStateMachine.Configuration
/// .disabledActions`), sans recopier la table de `GestureSequence`. Les
/// tests vérifient que chaque déclencheur listé ici résout bien vers son
/// action : les deux ne peuvent pas diverger sans qu'un test casse.
public enum GestureCatalog {

    public struct Entry: Equatable, Sendable {
        public let action: GestureAction
        public let target: GestureTargetKind
        /// Le premier est la forme à montrer ; les suivants sont les autres
        /// ordres qui mènent au même endroit (↓ puis → et → puis ↓).
        public let triggers: [GestureTrigger]

        public var family: GestureSequence.Family { triggers[0].family }
    }

    /// Dans l'ordre où un hôte les présenterait. `centerReduced` n'y est pas :
    /// aucun geste n'y mène aujourd'hui.
    public static let entries: [Entry] = [
        Entry(action: .leftHalf, target: .titlebar, triggers: [.swipes([.left])]),
        Entry(action: .rightHalf, target: .titlebar, triggers: [.swipes([.right])]),
        Entry(action: .maximize, target: .titlebar, triggers: [.swipes([.up])]),
        Entry(action: .minimize, target: .titlebar, triggers: [.swipes([.down])]),
        Entry(action: .topHalf, target: .titlebar, triggers: [.swipes([.up, .up])]),
        Entry(action: .bottomHalf, target: .titlebar, triggers: [.swipes([.down, .down])]),
        Entry(action: .topLeftQuarter, target: .titlebar, triggers: [.swipes([.up, .left]), .swipes([.left, .up])]),
        Entry(action: .topRightQuarter, target: .titlebar, triggers: [.swipes([.up, .right]), .swipes([.right, .up])]),
        Entry(action: .bottomLeftQuarter, target: .titlebar, triggers: [.swipes([.down, .left]), .swipes([.left, .down])]),
        Entry(action: .bottomRightQuarter, target: .titlebar, triggers: [.swipes([.down, .right]), .swipes([.right, .down])]),
        Entry(action: .toggleFullScreen, target: .titlebar, triggers: [.pinches([.out])]),
        Entry(action: .close, target: .titlebar, triggers: [.pinches([.in_])]),
        Entry(action: .quitApp, target: .dockApp, triggers: [.pinches([.in_])]),
    ]

    public static func entry(for action: GestureAction) -> Entry? {
        entries.first { $0.action == action }
    }

    /// Reste-t-il, pour cette famille, au moins un geste actif sur une cible
    /// (ou sur n'importe laquelle si `kind` vaut `nil`) ?
    public static func hasEnabledAction(
        _ family: GestureSequence.Family,
        on kind: GestureTargetKind? = nil,
        disabled: Set<GestureAction>
    ) -> Bool {
        entries.contains { entry in
            entry.family == family
                && (kind == nil || entry.target == kind)
                && disabled.contains(entry.action) == false
        }
    }
}
