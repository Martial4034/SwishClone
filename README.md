# SwishClone

Utilitaire d'arrière-plan macOS qui contrôle les fenêtres au trackpad :
swipe/pinch pour déplacer, redimensionner, maximiser ou minimiser la
fenêtre active — inspiré de Swish.

## Structure
- `Sources/SwishCloneCore/` — logique pure, sans AppKit, testable en isolation :
  types de gestes (`FingerPosition`, `SwipeDirection`, `PinchDirection`,
  `Gesture`) et `GestureClassifier`, qui transforme des positions de doigts
  en geste détecté.
- `Sources/SwishClone/` — l'app macOS :
  - `TouchGestureView` capte les événements multi-touch du trackpad
    (`NSEvent.touches`) et délègue la classification au Core.
  - `WindowController` contrôle les fenêtres externes via l'Accessibility
    API (`AXUIElement`) et mappe chaque geste détecté vers une action.
  - `AppDelegate` fait tourner l'app en arrière-plan (icône menu bar, pas
    de Dock) et branche le tout.
- `Tests/SwishCloneCoreTests/` — tests unitaires sur le module core
  uniquement (classification de gestes).

## Commandes

Compiler :
```
swift build
```

Lancer l'app :
```
swift run
```

Lancer les tests unitaires :
```
swift test
```

## Tests manuels : une seule app de gestes à la fois

**Ne jamais faire tourner bran et l'app de test SwishClone en même temps.**
bran embarque la même bibliothèque `SwishGestures` : avec les deux lancés,
deux taps écoutent le même trackpad, deux machines à états suivent le
même geste, et chacune applique son action à la même fenêtre. Les
résultats sont alors faux et trompeurs — enchaînements qui semblent
échouer, fenêtre qui passe en quart puis revient en moitié, pincement
qui n'a plus d'effet. Quitter bran (ou éteindre ses gestes dans ses
réglages) avant chaque session de test, et inversement.

**Garde-fou au démarrage.** `GestureMonitor.start()` prend un verrou
(`flock` sur un fichier du dossier temporaire de l'utilisateur, libéré par
le système à la mort du processus) et lance `StartError.anotherHostRunning`
si un autre hôte le tient déjà : l'app de test affiche alors une alerte qui
nomme le détenteur. Avec le tap actif (étape 5b), deux hôtes avaleraient les
mêmes événements — c'est pire qu'un doublon de détection, d'où le refus
plutôt qu'un simple avertissement. Un hôte qui embarque `SwishGestures` doit
traiter ce cas dans son `catch`. La garde ne voit que les processus de la
même session et du même dossier temporaire : un hôte sous bac à sable
(container à part) ne la déclencherait pas.

## Limites connues

- **Apps Electron (Claude, etc.) : leur barre de titre est du contenu web.
  Les gestes ne s'y accrochent que sur l'espace laissé libre par l'app,
  voire nulle part quand la fenêtre est étroite.** Relevé sur Claude en
  demi-écran : du tout premier pixel jusqu'à 30 pt sous le haut de la
  fenêtre, tout est sous un `AXWebArea`, sauf les trois feux natifs.
  `TitlebarHitTest` exclut le contenu web pour ne jamais voler le
  défilement d'une page.

  **Piste écartée : accepter un groupe web « vide » dans la bande du haut.**
  Sondée en lecture seule sur Claude : sous l'en-tête (`.dframe-header`,
  48 pt de haut), le contenu de la conversation **défile dès y = 48 pt, et
  AX le présente comme un simple `AXGroup`, sans rôle de défilement** —
  seule sa classe CSS (`overflow-y-auto`) le trahit. La hauteur de zone par
  défaut (40 pt) passe au-dessus, mais le réglage monte jusqu'à 100 pt :
  au-delà de 48 pt, la règle assouplie accepterait des points sur la
  conversation, et le tap actif lui volerait son défilement. La seule
  parade serait de lire les classes CSS de chaque app, que rien ne
  garantit d'une version à l'autre. Le confort manquant (gestes sur Claude
  en fenêtre étroite) ne vaut pas ce risque.

- **Curseur ↔ des fenêtres liées : API privée.** macOS ignore le curseur
  d'une app en arrière-plan ; mesuré par un prototype, sans elle le curseur
  restait la flèche. `BackgroundCursor` active
  `CGSSetConnectionProperty(…, "SetsCursorInBackground", true)`, cherchée
  à l'exécution : si un futur macOS la retire, on perd le curseur, sans
  planter. C'est le seul appel privé de la bibliothèque, isolé pour être
  facile à retirer.

## Fenêtres liées

Réglage « Redimensionner les fenêtres voisines » (`linkedResizeEnabled`,
éteint par défaut). Deux fenêtres rangées par geste en moitiés
complémentaires (gauche et droite, haut et bas) qui se touchent : leur bord
commun se saisit à la souris et les redimensionne toutes les deux en
direct, comme « Resize Adjacent Windows » de Swish.

- **Une poignée** par paire (`LinkedResizeController`) : un panneau
  invisible de 8 pt posé sur le bord commun, juste au-dessus de la plus
  avancée des deux fenêtres — pas au-dessus de tout : une troisième fenêtre
  qui recouvre le bord garde ses clics. Il reçoit le clic lui-même : ni tap
  souris actif, ni combat avec la poignée native de macOS.
- **La fenêtre qui rétrécit parle d'abord** : sa taille est écrite seule et
  relue, et la frontière se recale sur ce qu'elle a pris (taille minimale
  de TextEdit, grille de Terminal) avant de placer l'autre. Plancher de
  120 pt par fenêtre.
- **Échap** pendant le glissé : retour aux cadres d'avant. **⌘** (au clic
  ou en cours de route) : seule la fenêtre au premier plan des deux suit,
  les deux sont déliées.
- Une fenêtre fermée pendant le glissé l'arrête proprement ; la paire est
  dissoute.
- Logique pure et testée dans `LinkedWindows.swift` (Core).

## Gestes un par un

Chaque geste se coupe seul (`GestureSettings.disabledActions`, vide par
défaut : tout est actif), comme dans Swish où l'on clique sur l'icône d'un
geste pour l'activer ou le désactiver.

- **Un geste coupé ne s'annonce pas** : ni aperçu, ni action ; sa séquence
  se lit comme une séquence inconnue. Les autres gestes de la famille
  restent actifs (↓ coupé : ↓↓ et ↓ puis → marchent toujours).
- **Une famille entièrement coupée sur une cible n'y est plus capturée** :
  « quitter » coupé, le pincement sur une icône du Dock revient au Dock.
- **`GestureCatalog`** (Core) liste chaque geste — action, cible,
  déclencheurs (`GestureTrigger.symbols` : « ← », « ↑↑ », « ↓ puis → ») —
  pour qu'un hôte construise sa propre page sans recopier la table. Les
  tests vérifient que chaque déclencheur listé mène bien à son action.
- Les valeurs brutes de `GestureAction` sont des identifiants stables,
  écrits dans les préférences (`com.swishclone.disabledActions`).

## Prérequis
- Xcode Command Line Tools installés (`xcode-select --install`)
- Pas besoin de l'app Xcode complète
- Permission Accessibility accordée à l'app pour que le contrôle de
  fenêtres fonctionne (voir plus bas)

## État d'avancement

### Phase 1 — Détection de gestes ✅
Capture des événements trackpad (`NSEvent.touches`) et classification pure
côté Core : swipe (4 directions, tout nombre de doigts), pinch (in/out,
détecté via la variation relative de l'écartement moyen entre les doigts),
tap. Testé manuellement sur trackpad réel, seuils calibrés en conditions
réelles (voir `GestureClassifier.defaultTapThreshold` /
`defaultPinchThreshold`).

### Phase 2 — App d'arrière-plan ✅
`NSApp.setActivationPolicy(.accessory)` : pas d'icône Dock, pas de fenêtre
au lancement. Icône dans la menu bar (SF Symbol `hand.draw`) avec un menu :
afficher/cacher la fenêtre de test, quitter. Fermer la fenêtre de test ne
quitte plus l'app.

### Phase 3 — Contrôle de fenêtres (Accessibility API) ✅
`WindowController` : vérification/demande de la permission Accessibility
(`AXIsProcessTrusted(WithOptions:)`), lecture de la fenêtre au premier plan
de n'importe quelle app (`AXUIElement`), lecture et écriture de sa
position/taille.

### Phase 4 — Mapping gestes → actions ✅
Les gestes détectés déclenchent de vraies actions sur la fenêtre au
premier plan (jamais notre propre fenêtre de test, explicitement exclue) :
- swipe gauche/droite → moitié gauche/droite de l'écran
- swipe haut ou pinch out → plein écran
- swipe bas → minimise (`AXMinimizedAttribute` — fonctionne pour la
  plupart des apps AppKit standard, pas garanti pour toutes)
- pinch in → centre la fenêtre à ~60% de la taille de l'écran

Un cooldown de 300ms entre deux actions évite qu'un geste se ré-applique
en double si le classifieur ré-émet un résultat très rapidement.

Testé manuellement de bout en bout : geste sur le trackpad → action
visible sur une fenêtre d'une autre app.

### Logs de diagnostic
Des logs verbeux (`[DEBUG session]`, `[DEBUG classify]`) ont servi à
diagnostiquer plusieurs bugs de calibration et de tracking de session.
Ils sont désactivés par défaut mais gardés dans le code, dernière
`GestureClassifier.debugLoggingEnabled` : passer cette constante à `true`
et recompiler les réactive dans les deux modules.

**Latence du tap** (`SWISHCLONE_TRACE=1`). Le tap tourne sur son propre
thread et chronomètre chaque callback par étape (décodage, machine, test de
cible, envoi, `tapEnable`, timer, diagnostics). Rien ne s'imprime en usage
normal, sauf une ligne de bilan à la fermeture par le menu. Avec la variable
d'environnement, on obtient en plus le détail de tout callback de plus de
5 ms, les tests de cible lents et le pire de chaque étape :
`SWISHCLONE_TRACE=1 swift run`. Ordres de grandeur mesurés : le premier
`NSEvent(cgEvent:)` d'une session coûte ~8 ms, un test de cible AX 30 à 70 ms
à froid sur une app jamais touchée depuis un moment (sans conséquence en
écoute seule, mais c'est ce qui retiendrait le défilement si le tap devenait
actif), et `CGEvent.tapEnable` peut dépasser 10 ms sous charge — d'où
l'absence d'appel dans le callback.

## Accorder la permission Accessibility
1. `swift run`.
2. Depuis le menu de l'icône dans la menu bar, déclenche une action sur
   une fenêtre (ou utilise "Coller fenêtre active à gauche"). macOS ouvre
   Réglages Système > Confidentialité et sécurité > Accessibilité.
3. Active le toggle pour l'app, relance le geste.
