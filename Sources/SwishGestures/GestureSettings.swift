import Foundation
import SwishCloneCore

/// Réglages des gestes, persistés dans `UserDefaults` à chaque changement
/// et lus à chaque geste par les moniteurs et `WindowController` — un
/// changement est donc pris en compte immédiatement, sans relancer l'app.
///
/// Vit dans `SwishGestures` (et non dans l'exécutable) parce que
/// `WindowController` et le code de gestes doivent pouvoir le lire, et
/// qu'une bibliothèque ne peut pas dépendre de l'exécutable qui l'embarque.
///
/// `ObservableObject` plutôt que `@Observable` : ce dernier demande
/// macOS 14, le package cible macOS 13.
///
/// `@MainActor` : lu par les moniteurs (thread principal) et écrit par
/// l'interface SwiftUI. Un consommateur en Swift 6 (bran) l'utilise
/// ainsi sans `@preconcurrency`.
@MainActor
public final class GestureSettings: ObservableObject {

    public static let shared = GestureSettings()

    private enum Key {
        static let swipeThreshold = "com.swishclone.swipeThreshold"
        static let pinchThreshold = "com.swishclone.pinchThreshold"
        static let gestureZoneHeight = "com.swishclone.gestureZoneHeight"
        static let animationDuration = "com.swishclone.animationDuration"
        static let swipeEnabled = "com.swishclone.swipeEnabled"
        static let pinchEnabled = "com.swishclone.pinchEnabled"
        static let stepPause = "com.swishclone.stepPause"
        static let cancelTimeout = "com.swishclone.cancelTimeout"
        static let previewEnabled = "com.swishclone.previewEnabled"
        static let hapticsEnabled = "com.swishclone.hapticsEnabled"
        static let linkedResizeEnabled = "com.swishclone.linkedResizeEnabled"
        static let disabledActions = "com.swishclone.disabledActions"
    }

    /// Somme cumulée de scroll en dessous de laquelle un swipe est ignoré.
    @Published public var swipeThreshold: Double {
        didSet { defaults.set(swipeThreshold, forKey: Key.swipeThreshold) }
    }

    /// Magnitude de pinch (pic, en valeur absolue) en dessous de laquelle
    /// un pinch est ignoré.
    @Published public var pinchThreshold: Double {
        didSet { defaults.set(pinchThreshold, forKey: Key.pinchThreshold) }
    }

    /// Hauteur, en points, de la zone active en haut de la fenêtre.
    @Published public var gestureZoneHeight: Double {
        didSet { defaults.set(gestureZoneHeight, forKey: Key.gestureZoneHeight) }
    }

    /// Durée, en secondes, de l'animation d'une fenêtre déplacée.
    @Published public var animationDuration: Double {
        didSet { defaults.set(animationDuration, forKey: Key.animationDuration) }
    }

    @Published public var swipeEnabled: Bool {
        didSet { defaults.set(swipeEnabled, forKey: Key.swipeEnabled) }
    }

    @Published public var pinchEnabled: Bool {
        didSet { defaults.set(pinchEnabled, forKey: Key.pinchEnabled) }
    }

    /// Immobilité, en secondes, qui valide une étape du geste et permet
    /// d'en enchaîner une autre sans lever les doigts (↓ puis → = quart).
    @Published public var stepPause: Double {
        didSet { defaults.set(stepPause, forKey: Key.stepPause) }
    }

    /// Immobilité, en secondes, qui annule le geste en cours.
    @Published public var cancelTimeout: Double {
        didSet { defaults.set(cancelTimeout, forKey: Key.cancelTimeout) }
    }

    /// Le panneau qui montre, pendant le geste, ce que fera le lever.
    @Published public var previewEnabled: Bool {
        didSet { defaults.set(previewEnabled, forKey: Key.previewEnabled) }
    }

    /// Le retour haptique à chaque étape validée et à l'annulation (si le
    /// trackpad le permet et que macOS l'autorise).
    @Published public var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    /// **Fenêtres liées** : le bord commun de deux moitiés complémentaires
    /// se saisit à la souris pour redimensionner les deux à la fois. Éteint
    /// par défaut tant qu'il n'est pas validé sur les apps courantes.
    @Published public var linkedResizeEnabled: Bool {
        didSet { defaults.set(linkedResizeEnabled, forKey: Key.linkedResizeEnabled) }
    }

    /// **Les gestes coupés un par un** (voir `GestureCatalog`). Vide par
    /// défaut : tout est actif. Écrit comme la liste triée des valeurs brutes,
    /// pour que les préférences restent lisibles et stables.
    @Published public var disabledActions: Set<GestureAction> {
        didSet { defaults.set(Self.encode(disabledActions), forKey: Key.disabledActions) }
    }

    public func isEnabled(_ action: GestureAction) -> Bool {
        disabledActions.contains(action) == false
    }

    public func setEnabled(_ action: GestureAction, _ enabled: Bool) {
        if enabled {
            disabledActions.remove(action)
        } else {
            disabledActions.insert(action)
        }
    }

    /// Triée, pour qu'un même ensemble s'écrive toujours pareil.
    nonisolated static func encode(_ actions: Set<GestureAction>) -> [String] {
        actions.map(\.rawValue).sorted()
    }

    /// Une valeur inconnue (écrite par une version plus récente, ou abîmée)
    /// est ignorée : le geste correspondant reste actif.
    nonisolated static func decode(_ stored: Any?) -> Set<GestureAction> {
        Set((stored as? [String] ?? []).compactMap(GestureAction.init(rawValue:)))
    }

    private let defaults = UserDefaults.standard

    /// Les réglages dont la machine à états a besoin, figés en une valeur.
    public var machineConfiguration: GestureStateMachine.Configuration {
        var configuration = GestureStateMachine.Configuration()
        configuration.swipeEnabled = swipeEnabled
        configuration.pinchEnabled = pinchEnabled
        configuration.disabledActions = disabledActions
        configuration.swipeThreshold = swipeThreshold
        configuration.pinchThreshold = pinchThreshold
        configuration.stepPause = stepPause
        configuration.cancelTimeout = cancelTimeout
        return configuration
    }

    private init() {
        // `object(forKey:) as? T ?? défaut` plutôt que `double(forKey:)` :
        // ce dernier renvoie 0 pour une clé absente, ce qui désactiverait
        // silencieusement tous les seuils au premier lancement.
        swipeThreshold = defaults.object(forKey: Key.swipeThreshold) as? Double ?? 16
        pinchThreshold = defaults.object(forKey: Key.pinchThreshold) as? Double ?? 0.1
        gestureZoneHeight = defaults.object(forKey: Key.gestureZoneHeight) as? Double ?? 40
        animationDuration = defaults.object(forKey: Key.animationDuration) as? Double ?? 0.2
        swipeEnabled = defaults.object(forKey: Key.swipeEnabled) as? Bool ?? true
        pinchEnabled = defaults.object(forKey: Key.pinchEnabled) as? Bool ?? true
        stepPause = defaults.object(forKey: Key.stepPause) as? Double ?? 0.3
        cancelTimeout = defaults.object(forKey: Key.cancelTimeout) as? Double ?? 0.8
        previewEnabled = defaults.object(forKey: Key.previewEnabled) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        linkedResizeEnabled = defaults.object(forKey: Key.linkedResizeEnabled) as? Bool ?? false
        disabledActions = Self.decode(defaults.object(forKey: Key.disabledActions))
    }
}
