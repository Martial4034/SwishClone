import AppKit
import SwishCloneCore

/// Point d'entrée public de la détection globale : démarre et arrête le
/// tap unique du swipe et du pincement (`GestureEventTap`), qui reste
/// interne — un hôte (l'app SwishClone, ou bran) n'a besoin que de ceci et
/// de `GestureSettings`.
///
/// **Tout ou rien.** Si l'un des deux taps (gestes, ou Échap) ne se crée
/// pas, rien ne tourne : un état « à moitié démarré » ne se laisse pas
/// afficher honnêtement par un hôte qui n'a qu'un interrupteur.
///
/// Ne demande jamais la permission Accessibility lui-même : c'est à
/// l'hôte de décider quand montrer la fenêtre du système (voir
/// `WindowController.requestAccessibilityPermission()`).
///
/// **Un seul hôte à la fois sur une même session.** `start()` refuse
/// (`StartError.anotherHostRunning`) quand un autre processus — l'app
/// SwishClone, bran — tient déjà la détection : deux hôtes suivraient le même
/// geste et agiraient chacun sur la même fenêtre, et avec le tap actif ils
/// avaleraient les mêmes événements. Voir `HostLock` et le README.
@MainActor
public enum GestureMonitor {

    public enum StartError: Error {
        /// Sans elle, le tap ne recevrait rien, sans erreur.
        case accessibilityNotTrusted
        /// `CGEventTapCreate` a échoué alors que l'Accessibilité est
        /// accordée — le plus souvent la permission « Contrôle de
        /// l'entrée » (Input Monitoring). Le détail est dans la console.
        case eventTapUnavailable
        /// Un autre processus (bran, ou l'app de test SwishClone) tient déjà
        /// la détection : deux hôtes suivraient le même geste et agiraient
        /// chacun sur la même fenêtre. `processID` et `name` désignent le
        /// détenteur quand il a pu être lu.
        case anotherHostRunning(processID: Int32?, name: String?)
    }

    private static let hostLock = HostLock()

    public private(set) static var isRunning = false

    /// Sans effet si la détection tourne déjà : appeler deux fois
    /// n'installe pas deux taps.
    public static func start() throws {
        guard !isRunning else { return }
        guard WindowController.isAccessibilityTrusted() else {
            throw StartError.accessibilityNotTrusted
        }

        do {
            try hostLock.acquire()
        } catch HostLock.Failure.heldElsewhere(let holder) {
            throw StartError.anotherHostRunning(processID: holder.processID, name: holder.name)
        }

        guard GestureEventTap.start() else {
            hostLock.release()
            throw StartError.eventTapUnavailable
        }
        // Écrans branchés, débranchés ou réarrangés : les zones utiles
        // changent, les placements mémorisés ne veulent plus rien dire.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowController.resetPlacements() }
        }
        LinkedResizeController.start()
        isRunning = true
    }

    public static func stop() {
        guard isRunning else { return }
        GestureEventTap.stop()
        LinkedResizeController.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        WindowController.resetPlacements()
        hostLock.release()
        isRunning = false
    }

    private static var screenObserver: (any NSObjectProtocol)?
}
