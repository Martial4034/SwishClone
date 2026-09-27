/// Sur quoi un geste a commencé. Décidé une fois, au début du geste, et
/// retenu jusqu'au lever : c'est ce qui choisit la table des actions.
public enum GestureTargetKind: Equatable, Sendable {
    /// La barre de titre (ou d'outils) d'une fenêtre.
    case titlebar
    /// L'icône d'une app lancée, dans le Dock.
    case dockApp
}

/// Ce qu'un geste terminé demande de faire à sa cible.
///
/// Décrit l'intention, pas la géométrie : c'est `WindowController` (ou
/// `AppController` pour une app), côté SwishGestures, qui la traduit. La
/// machine à états et l'aperçu n'ont besoin que de savoir *quoi* montrer et
/// *quoi* appliquer.
///
/// **Les valeurs brutes sont des identifiants stables** : l'hôte les écrit
/// dans ses préférences (les gestes désactivés). Renommer un cas est libre,
/// changer sa valeur brute réactive en silence le geste chez qui l'avait
/// coupé.
public enum GestureAction: String, CaseIterable, Equatable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf

    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    /// Remplir l'écran, en restant sur le même bureau.
    case maximize
    case minimize
    /// Le plein écran natif (bouton vert, bureau à part).
    case toggleFullScreen
    /// Le bouton rouge, comme un clic : l'app garde la main (un document non
    /// enregistré ouvre sa feuille de dialogue, rien n'est perdu).
    case close
    /// Fenêtre recentrée à 60 %. Plus associée à aucun geste depuis que le
    /// pincement ferme la fenêtre ; réservée au double tap (P1).
    case centerReduced

    /// Quitter l'app de l'icône du Dock visée, comme ⌘Q : l'app décide
    /// (« Enregistrer ? » compris) et peut refuser.
    case quitApp
}
