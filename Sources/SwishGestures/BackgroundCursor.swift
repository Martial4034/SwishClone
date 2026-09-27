import AppKit

/// **API privée** : permet à une app en arrière-plan d'imposer son curseur.
///
/// Sans elle, macOS ignore `NSCursor.set()` tant que l'app n'est pas au
/// premier plan — ce qui est toujours le cas d'un hôte de gestes. Mesuré par
/// le prototype du 25/09/2026 : la poignée des fenêtres liées recevait bien
/// les entrées et les glissés, mais le curseur restait la flèche, TextEdit
/// au premier plan ou non, glissé compris.
///
/// `CGSSetConnectionProperty(connexion, connexion, "SetsCursorInBackground",
/// true)` sur la connexion au serveur de fenêtres de l'app. Non documentée,
/// utilisée par des utilitaires de fenêtres connus. Les symboles sont
/// cherchés à l'exécution (`dlsym`) : si un futur macOS les retire, on perd
/// le curseur, sans planter.
///
/// Gardé à part pour être facile à retirer : c'est le seul appel privé de la
/// bibliothèque, choisi pour voir le rendu avant de trancher.
@MainActor
enum BackgroundCursor {

    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// `RTLD_DEFAULT` : chercher dans toutes les images chargées (AppKit
    /// charge déjà SkyLight, qui porte ces symboles).
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    /// Active ou coupe le curseur en arrière-plan. `false` si l'API est
    /// introuvable ou refuse (le curseur ne changera alors pas).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let connectionSymbol = dlsym(defaultHandle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(defaultHandle, "CGSSetConnectionProperty") else {
            print("[BackgroundCursor] API privée introuvable : le curseur ne changera pas en arrière-plan")
            return false
        }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSymbol, to: SetConnectionProperty.self)
        let error = set(connection, connection, "SetsCursorInBackground" as CFString,
                        enabled ? kCFBooleanTrue : kCFBooleanFalse)
        if error != 0 { print("[BackgroundCursor] refusé par le serveur de fenêtres (erreur \(error))") }
        return error == 0
    }
}
