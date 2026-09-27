import Foundation

/// **Le geste, du premier doigt posé au dernier levé : une valeur pure.**
///
/// ```
///   idle ──began (sur la cible)──▶ swipe ──ended──▶ commit ──▶ swallowingMomentum ──fin d'inertie──▶ idle
///     │                             │  ▲
///     │                             │  └─ immobile ≥ stepPause : étape validée (haptique)
///     │                             └─ Échap, ou immobile ≥ cancelTimeout ──▶ swipeCancelled (avale jusqu'au lever)
///     └─began (hors cible)──▶ rien : tout passe jusqu'au prochain began
/// ```
///
/// Le pincement suit le même schéma (`pinch`, `pinchCancelled`,
/// `pinchPassThrough`), avec une fin de geste détectée par la phase quand
/// l'hôte la fournit, par un silence de `pinchSessionGap` sinon.
///
/// Trois règles portent tout le reste :
///
/// 1. **L'action part au lever, jamais avant.** C'est ce qui permet ↓ seul
///    (réduire) et ↓ puis → (quart en bas à droite) : en agissant pendant le
///    geste, ↓ aurait déjà réduit la fenêtre.
/// 2. **La cible est décidée une fois, au début du geste**, par `isOnTarget`
///    — l'hôte y fait son test d'accessibilité, coûteux, et on ne l'appelle
///    qu'une fois par geste. Son type (barre de titre, icône du Dock) choisit
///    la table des actions ; un geste sans action sur ce type de cible n'est
///    pas capturé. Tout le geste, inertie comprise, est ensuite
///    avalé ou laissé passer **d'un bloc** : une app qui recevrait la moitié
///    d'un scroll pourrait rester coincée au milieu.
/// 3. **Les pauses ne produisent aucun événement** — des doigts immobiles
///    n'envoient rien. La machine expose donc `nextDeadline`, et l'hôte la
///    réveille avec `.tick` à cette date.
///
/// Rien ici ne touche à AppKit, au temps réel ni à un thread : l'hôte fournit
/// l'heure, et tout se rejoue dans `swift test`.
public struct GestureStateMachine: Sendable {

    public struct Configuration: Equatable, Sendable {
        public var swipeEnabled = true
        public var pinchEnabled = true
        /// **Les gestes coupés un par un.** Un geste désactivé ne montre ni
        /// aperçu ni action : sa séquence se lit comme une séquence inconnue.
        /// Les autres gestes de la famille restent actifs (↓ coupé, ↓↓ et
        /// ↓ puis → marchent toujours). Quand toute une famille est coupée
        /// sur une cible, le geste n'y est plus capturé du tout.
        public var disabledActions: Set<GestureAction> = []
        /// Amplitude cumulée, sur une étape, au-delà de laquelle une direction
        /// de swipe devient candidate.
        public var swipeThreshold: Double = 16
        /// Même chose pour le pincement, en magnitude relative à l'étape.
        public var pinchThreshold: Double = 0.1
        /// Immobilité qui valide l'étape en cours et permet d'en enchaîner une
        /// autre sans lever les doigts.
        public var stepPause: TimeInterval = 0.3
        /// Immobilité qui annule le geste.
        public var cancelTimeout: TimeInterval = 0.8
        /// Silence qui vaut « doigts levés » pour un pincement sans phase.
        public var pinchSessionGap: TimeInterval = 0.15
        /// Faux : la machine suit le geste mais laisse tout passer (l'hôte
        /// peut alors se contenter d'un tap en écoute seule).
        public var blocksEvents = false
        /// En dessous, un événement ne compte pas comme un mouvement : il ne
        /// repousse ni la validation d'étape ni l'annulation.
        public var scrollMovementEpsilon: Double = 0.1
        public var pinchMovementEpsilon: Double = 0.002

        public init() {}
    }

    /// Les phases d'un geste trackpad, sans AppKit. Pour un scroll, `phase`
    /// vaut `nil` pendant l'inertie et pour une molette de souris ;
    /// `momentum` vaut `nil` tant que les doigts sont posés.
    public enum Phase: Equatable, Sendable {
        case mayBegin, began, changed, ended, cancelled
    }

    public enum Event: Equatable, Sendable {
        case scroll(phase: Phase?, momentum: Phase?, dx: Double, dy: Double)
        /// `cumulative` : magnitude depuis le début du pincement (positive en
        /// écartant). `phase` : `nil` si l'hôte ne la connaît pas.
        case magnify(cumulative: Double, phase: Phase?)
        case escape
        case tick
    }

    public enum Disposition: Equatable, Sendable {
        case pass, swallow
    }

    public enum Preview: Equatable, Sendable {
        case action(GestureAction)
        /// Une séquence qui ne correspond à rien : le lever ne fera rien, et
        /// l'aperçu doit le dire plutôt que de disparaître.
        case unrecognized
    }

    public enum Haptic: Equatable, Sendable {
        case step, cancel
    }

    public enum CancelReason: Equatable, Sendable {
        /// Immobile au-delà de `cancelTimeout`.
        case stillness
        case escape
        /// Le système a interrompu le geste (phase `cancelled`).
        case interrupted
    }

    public enum Effect: Equatable, Sendable {
        case showPreview(Preview)
        case hidePreview
        case haptic(Haptic)
        case commit(GestureAction)
        case cancelled(CancelReason)
    }

    public struct Output: Equatable, Sendable {
        public var disposition: Disposition
        public var effects: [Effect]
    }

    public var configuration: Configuration

    private var state: State = .idle
    private var shownPreview: Preview?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    // MARK: - État

    private struct SwipeTracking: Equatable, Sendable {
        var kind: GestureTargetKind
        var steps: [SwipeDirection] = []
        var candidate: SwipeDirection?
        var accX: Double = 0
        var accY: Double = 0
        var lastMovementAt: TimeInterval
        /// Faux tant que le geste n'a été qu'armé par `mayBegin` (doigts
        /// posés, pas encore bougé) : le `began` qui suit continue ce geste au
        /// lieu d'en ouvrir un autre.
        var hasBegun: Bool
    }

    private struct PinchTracking: Equatable, Sendable {
        var kind: GestureTargetKind
        var steps: [PinchDirection] = []
        var candidate: PinchDirection?
        var stepBase: Double = 0
        /// Magnitude, relative à l'étape, de plus grande amplitude. C'est elle
        /// qui décide, pas la dernière : en relâchant, les doigts font souvent
        /// retomber la magnitude sous le seuil juste avant le lever (Phase 5).
        var stepPeak: Double = 0
        var lastMagnitude: Double = 0
        var lastMovementAt: TimeInterval
        var lastEventAt: TimeInterval
        var usesPhase: Bool
    }

    private enum State: Equatable, Sendable {
        case idle
        case swipe(SwipeTracking)
        case swipeCancelled
        case swallowingMomentum
        case pinch(PinchTracking)
        case pinchCancelled(lastEventAt: TimeInterval, usesPhase: Bool)
        case pinchPassThrough(lastEventAt: TimeInterval, usesPhase: Bool)
    }

    /// Un geste est-il suivi (et donc, en mode bloquant, avalé) ?
    public var isTracking: Bool {
        switch state {
        case .swipe, .pinch: return true
        default: return false
        }
    }

    /// La prochaine date à laquelle l'hôte doit envoyer `.tick`. `nil` quand
    /// rien n'est en attente.
    public var nextDeadline: TimeInterval? {
        switch state {
        case let .swipe(t):
            var deadline = t.lastMovementAt + configuration.cancelTimeout
            if t.candidate != nil {
                deadline = min(deadline, t.lastMovementAt + configuration.stepPause)
            }
            return deadline
        case let .pinch(p):
            var deadline = p.lastMovementAt + configuration.cancelTimeout
            if p.candidate != nil {
                deadline = min(deadline, p.lastMovementAt + configuration.stepPause)
            }
            if p.usesPhase == false {
                deadline = min(deadline, p.lastEventAt + configuration.pinchSessionGap)
            }
            return deadline
        case let .pinchCancelled(lastEventAt, usesPhase),
             let .pinchPassThrough(lastEventAt, usesPhase):
            return usesPhase ? nil : lastEventAt + configuration.pinchSessionGap
        case .idle, .swipeCancelled, .swallowingMomentum:
            return nil
        }
    }

    /// Abandonne tout geste en cours, sans action ni retour haptique.
    ///
    /// Pour l'hôte dont le tap vient d'être coupé par macOS : des
    /// événements ont été perdus, le geste en cours n'a plus de fin fiable.
    /// Rend l'effet qui masque l'aperçu s'il était affiché.
    public mutating func reset() -> [Effect] {
        var effects: [Effect] = []
        show(nil, effects: &effects)
        state = .idle
        return effects
    }

    // MARK: - Entrée

    /// `isOnTarget` n'est appelé qu'au début d'un geste — jamais pendant. Il
    /// rend le type de cible sous le curseur, ou `nil` s'il n'y en a pas.
    public mutating func handle(
        _ event: Event,
        at now: TimeInterval,
        isOnTarget: () -> GestureTargetKind?
    ) -> Output {
        var effects: [Effect] = []
        let captured: Bool

        switch event {
        case let .scroll(phase, momentum, dx, dy):
            captured = handleScroll(phase: phase, momentum: momentum, dx: dx, dy: dy,
                                    now: now, isOnTarget: isOnTarget, effects: &effects)
        case let .magnify(cumulative, phase):
            captured = handleMagnify(cumulative, phase: phase, now: now,
                                     isOnTarget: isOnTarget, effects: &effects)
        case .escape:
            captured = handleEscape(effects: &effects)
        case .tick:
            handleTick(now: now, effects: &effects)
            captured = false
        }

        let blocks = captured && configuration.blocksEvents
        return Output(disposition: blocks ? .swallow : .pass, effects: effects)
    }

    // MARK: - Swipe

    private mutating func handleScroll(
        phase: Phase?,
        momentum: Phase?,
        dx: Double,
        dy: Double,
        now: TimeInterval,
        isOnTarget: () -> GestureTargetKind?,
        effects: inout [Effect]
    ) -> Bool {
        // L'inertie qui suit un geste capturé est avalée elle aussi : sans ça,
        // la fenêtre fraîchement rangée défilerait toute seule juste après.
        if let momentum {
            guard case .swallowingMomentum = state else { return false }
            if momentum == .ended || momentum == .cancelled { state = .idle }
            return true
        }

        // Ni phase ni inertie : une molette de souris. Jamais un geste.
        guard let phase else { return false }

        switch phase {
        case .mayBegin, .began:
            if phase == .began, case var .swipe(t) = state, t.hasBegun == false {
                // Armé par `mayBegin` : c'est le même geste qui démarre.
                t.hasBegun = true
                state = .swipe(t)
                return true
            }
            // Un nouveau geste. Ce qui restait d'un précédent (des phases
            // perdues) est abandonné sans action.
            show(nil, effects: &effects)
            guard configuration.swipeEnabled,
                  GestureCatalog.hasEnabledAction(.swipe, disabled: configuration.disabledActions),
                  let kind = isOnTarget(),
                  GestureSequence.accepts(.swipe, on: kind, disabled: configuration.disabledActions) else {
                state = .idle
                return false
            }
            state = .swipe(SwipeTracking(kind: kind, lastMovementAt: now, hasBegun: phase == .began))
            return true

        case .changed:
            switch state {
            case var .swipe(t):
                move(&t, dx: dx, dy: dy, now: now)
                state = .swipe(t)
                show(preview(swipes: t.steps + [t.candidate].compactMap { $0 }, on: t.kind), effects: &effects)
                return true
            case .swipeCancelled:
                return true
            default:
                return false
            }

        case .ended:
            switch state {
            case let .swipe(t):
                show(nil, effects: &effects)
                let steps = t.steps + [t.candidate].compactMap { $0 }
                if let action = enabledAction(swipes: steps, on: t.kind) {
                    effects.append(.commit(action))
                }
                state = .swallowingMomentum
                return true
            case .swipeCancelled:
                state = .swallowingMomentum
                return true
            default:
                return false
            }

        case .cancelled:
            // Le système a interrompu le geste : jamais d'action, et pas
            // d'inertie à attendre.
            switch state {
            case let .swipe(t):
                abandon(pending: t.steps.isEmpty == false || t.candidate != nil, reason: .interrupted, effects: &effects)
                state = .idle
                return true
            case .swipeCancelled:
                state = .idle
                return true
            default:
                return false
            }
        }
    }

    private func move(_ t: inout SwipeTracking, dx: Double, dy: Double, now: TimeInterval) {
        guard abs(dx) + abs(dy) >= configuration.scrollMovementEpsilon else { return }
        t.accX += dx
        t.accY += dy
        t.lastMovementAt = now
        t.candidate = max(abs(t.accX), abs(t.accY)) >= configuration.swipeThreshold
            ? Self.direction(dx: t.accX, dy: t.accY)
            : nil
    }

    /// Conventions de signe de `NSEvent.scrollWheel`, confirmées sur le
    /// trackpad : `dx < 0` = gauche, `dy > 0` = **bas** (l'inverse de
    /// `GestureClassifier` sur l'axe Y).
    static func direction(dx: Double, dy: Double) -> SwipeDirection {
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy > 0 ? .down : .up
    }

    private func preview(swipes steps: [SwipeDirection], on kind: GestureTargetKind) -> Preview? {
        guard steps.isEmpty == false else { return nil }
        return enabledAction(swipes: steps, on: kind).map(Preview.action) ?? .unrecognized
    }

    // MARK: - Pincement

    private mutating func handleMagnify(
        _ magnitude: Double,
        phase: Phase?,
        now: TimeInterval,
        isOnTarget: () -> GestureTargetKind?,
        effects: inout [Effect]
    ) -> Bool {
        // Un hôte qui n'a pas réveillé la machine à temps : le silence a déjà
        // clos la session précédente, on la termine avant d'en ouvrir une.
        if let deadline = gapDeadline, now >= deadline {
            handleTick(now: deadline, effects: &effects)
        }

        let lifted = phase == .ended || phase == .cancelled

        switch state {
        case var .pinch(p):
            p.lastEventAt = now
            if phase != nil { p.usesPhase = true }
            if lifted {
                if phase == .ended {
                    finishPinch(p, effects: &effects)
                } else {
                    abandon(pending: p.steps.isEmpty == false || p.candidate != nil, reason: .interrupted, effects: &effects)
                    state = .idle
                }
                return true
            }
            move(&p, magnitude: magnitude, now: now)
            state = .pinch(p)
            show(preview(pinches: p.steps + [p.candidate].compactMap { $0 }, on: p.kind), effects: &effects)
            return true

        case let .pinchCancelled(_, usesPhase):
            state = lifted ? .idle : .pinchCancelled(lastEventAt: now, usesPhase: usesPhase || phase != nil)
            return true

        case let .pinchPassThrough(_, usesPhase):
            state = lifted ? .idle : .pinchPassThrough(lastEventAt: now, usesPhase: usesPhase || phase != nil)
            return false

        default:
            // Début d'un pincement. Une fin isolée (phase perdue) ne démarre
            // rien.
            guard lifted == false else { return false }
            guard configuration.pinchEnabled,
                  GestureCatalog.hasEnabledAction(.pinch, disabled: configuration.disabledActions),
                  let kind = isOnTarget(),
                  GestureSequence.accepts(.pinch, on: kind, disabled: configuration.disabledActions) else {
                state = .pinchPassThrough(lastEventAt: now, usesPhase: phase != nil)
                return false
            }
            var p = PinchTracking(kind: kind, lastMovementAt: now, lastEventAt: now, usesPhase: phase != nil)
            move(&p, magnitude: magnitude, now: now)
            state = .pinch(p)
            show(preview(pinches: p.steps + [p.candidate].compactMap { $0 }, on: p.kind), effects: &effects)
            return true
        }
    }

    private func move(_ p: inout PinchTracking, magnitude: Double, now: TimeInterval) {
        let delta = abs(magnitude - p.lastMagnitude)
        p.lastMagnitude = magnitude
        guard delta >= configuration.pinchMovementEpsilon else { return }
        p.lastMovementAt = now
        let relative = magnitude - p.stepBase
        if abs(relative) > abs(p.stepPeak) { p.stepPeak = relative }
        p.candidate = abs(p.stepPeak) >= configuration.pinchThreshold
            ? (p.stepPeak > 0 ? .out : .in_)
            : nil
    }

    private mutating func finishPinch(_ p: PinchTracking, effects: inout [Effect]) {
        show(nil, effects: &effects)
        let steps = p.steps + [p.candidate].compactMap { $0 }
        if let action = enabledAction(pinches: steps, on: p.kind) {
            effects.append(.commit(action))
        }
        state = .idle
    }

    /// La table, moins les gestes désactivés : utilisé pour l'aperçu **et**
    /// pour l'action, pour qu'un geste coupé ne s'annonce jamais.
    private func enabledAction(swipes steps: [SwipeDirection], on kind: GestureTargetKind) -> GestureAction? {
        GestureSequence.resolve(swipes: steps, on: kind).flatMap(enabled)
    }

    private func enabledAction(pinches steps: [PinchDirection], on kind: GestureTargetKind) -> GestureAction? {
        GestureSequence.resolve(pinches: steps, on: kind).flatMap(enabled)
    }

    private func enabled(_ action: GestureAction) -> GestureAction? {
        configuration.disabledActions.contains(action) ? nil : action
    }

    private func preview(pinches steps: [PinchDirection], on kind: GestureTargetKind) -> Preview? {
        guard steps.isEmpty == false else { return nil }
        return enabledAction(pinches: steps, on: kind).map(Preview.action) ?? .unrecognized
    }

    /// L'échéance du silence de fin de pincement, pour les états qui en ont
    /// une.
    private var gapDeadline: TimeInterval? {
        switch state {
        case let .pinch(p) where p.usesPhase == false:
            return p.lastEventAt + configuration.pinchSessionGap
        case let .pinchCancelled(lastEventAt, false), let .pinchPassThrough(lastEventAt, false):
            return lastEventAt + configuration.pinchSessionGap
        default:
            return nil
        }
    }

    // MARK: - Échap et temps

    private mutating func handleEscape(effects: inout [Effect]) -> Bool {
        switch state {
        case let .swipe(t):
            abandon(pending: t.steps.isEmpty == false || t.candidate != nil, reason: .escape, effects: &effects)
            state = .swipeCancelled
            return true
        case let .pinch(p):
            abandon(pending: p.steps.isEmpty == false || p.candidate != nil, reason: .escape, effects: &effects)
            state = .pinchCancelled(lastEventAt: p.lastEventAt, usesPhase: p.usesPhase)
            return true
        default:
            return false
        }
    }

    private mutating func handleTick(now: TimeInterval, effects: inout [Effect]) {
        switch state {
        case var .swipe(t):
            let still = now - t.lastMovementAt
            if still >= configuration.cancelTimeout {
                abandon(pending: t.steps.isEmpty == false || t.candidate != nil, reason: .stillness, effects: &effects)
                state = .swipeCancelled
            } else if let candidate = t.candidate, still >= configuration.stepPause {
                t.steps.append(candidate)
                t.candidate = nil
                t.accX = 0
                t.accY = 0
                state = .swipe(t)
                effects.append(.haptic(.step))
                show(preview(swipes: t.steps, on: t.kind), effects: &effects)
            }

        case var .pinch(p):
            // Sans phase, le silence est le lever — et il arrive avant toute
            // pause d'étape, puisque `pinchSessionGap` < `stepPause`.
            if p.usesPhase == false, now - p.lastEventAt >= configuration.pinchSessionGap {
                finishPinch(p, effects: &effects)
                return
            }
            let still = now - p.lastMovementAt
            if still >= configuration.cancelTimeout {
                abandon(pending: p.steps.isEmpty == false || p.candidate != nil, reason: .stillness, effects: &effects)
                state = .pinchCancelled(lastEventAt: p.lastEventAt, usesPhase: p.usesPhase)
            } else if let candidate = p.candidate, still >= configuration.stepPause {
                p.steps.append(candidate)
                p.candidate = nil
                p.stepBase = p.lastMagnitude
                p.stepPeak = 0
                state = .pinch(p)
                effects.append(.haptic(.step))
                show(preview(pinches: p.steps, on: p.kind), effects: &effects)
            }

        case let .pinchCancelled(lastEventAt, false), let .pinchPassThrough(lastEventAt, false):
            if now - lastEventAt >= configuration.pinchSessionGap { state = .idle }

        default:
            break
        }
    }

    // MARK: - Effets

    /// Annule sans agir. Le retour haptique et `.cancelled` ne partent que
    /// s'il y avait quelque chose à annuler : poser deux doigts sur une barre
    /// de titre et les relever n'a rien d'un geste raté.
    private mutating func abandon(pending: Bool, reason: CancelReason, effects: inout [Effect]) {
        show(nil, effects: &effects)
        guard pending else { return }
        effects.append(.haptic(.cancel))
        effects.append(.cancelled(reason))
    }

    /// N'émet que les changements : l'aperçu n'est redessiné que quand ce
    /// qu'il montre change.
    private mutating func show(_ preview: Preview?, effects: inout [Effect]) {
        guard preview != shownPreview else { return }
        shownPreview = preview
        effects.append(preview.map(Effect.showPreview) ?? .hidePreview)
    }
}
