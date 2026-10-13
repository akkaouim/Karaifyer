# Karaifyer

Application Mac (fenêtre, icône dans le Dock et dans la barre des menus) pour préparer le spectacle karaoké :
- **Enregistrement** : l'enregistreur Spotify de SysRec, à l'identique (copié, SysRec n'est pas modifié) ;
- **Karaoké** : le manifeste en tableau, l'analyse (séparation, temps, accords, paroles, vidéo, set
  Ableton) lancée et suivie depuis l'app, l'ouverture des résultats et la correction des paroles et
  des accords à l'oreille.

L'analyse reste faite par la commande `karaoke` (dossier `karaoke/` du dépôt) : l'app la pilote. Tout
continue de fonctionner en ligne de commande sans l'app.

## Installer

```sh
cd karaifyer
./build-app.sh --install        # → ~/Applications/Karaifyer.app
```

Au premier lancement, macOS demande l'autorisation d'**enregistrer l'audio du système** et de
**contrôler Spotify** (une fois pour Karaifyer, indépendamment de SysRec).

Réglages (⌘,) : dossier karaoké (par défaut `/Volumes/Hypermnesia/karaoke`), gabarit Ableton, et
dossier du projet `karaoke` (par défaut `~/Documents/mp3-pipeline/karaoke`). Un bandeau orange signale
ce qui manque (disque débranché, `uv` absent…) et désactive « Analyser ».

## Onglet Karaoké

- **Ajouter des morceaux…** : n'importe quels fichiers audio (FLAC, WAV, MP3, M4A, AIFF), pas
  seulement ceux de SysRec. Titre et artiste viennent des tags (sinon du nom du fichier) ; un fichier
  déjà présent est ignoré. S'il n'y a pas encore de manifeste, le bandeau propose de le créer depuis un
  dossier SysRec.
- **Tableau** : titre, artiste et partie modifiables (Entrée pour valider) ; **Retirer** = les parties
  jouées en live (fader à zéro au départ du morceau ; « Autres » = l'accompagnement 17–18) ; langue.
  Chaque modification est écrite dans `manifeste.csv` avec les mêmes vérifications qu'en ligne de
  commande. Les pastilles montrent chaque étape : grise = à faire, bleue = en cours, verte = faite,
  orange = bloquée, rouge = échec (le message apparaît au survol).
- **Analyser** : la sélection, ou tout si rien n'est sélectionné. Un morceau à la fois ; ce qui est à
  jour est sauté. **Pause / Reprendre** (même des heures), **Arrêter après ce morceau**,
  **Arrêter maintenant** (l'étape interrompue est refaite à la relance). Le Mac ne se met pas en veille
  pendant l'analyse. Lancer un enregistrement pendant une analyse propose de la mettre en pause.
- **Barre de progression** et **Terminal** (journal en direct, bouton Copier).
- **Clic droit** sur un morceau : ouvrir le dossier, la vidéo, le set Ableton, la grille d'accords, le
  journal ; refaire le morceau ou une étape ; **Corriger paroles et accords…**

## Corriger paroles et accords

La fenêtre de correction joue l'enregistrement. À gauche les paroles (`mm:ss.cc │ texte`), à droite la
grille d'accords, 4 mesures par ligne. Cliquer une ligne ou un numéro de mesure y va ; la ligne et la
mesure en cours sont surlignées ; ⏱ cale le début de la ligne sélectionnée sur la lecture.

Syntaxe d'une mesure :
- `A B` : les accords se partagent la mesure à égalité ;
- `Am . . F` : un symbole par temps, `.` prolonge l'accord précédent (autant de symboles que de temps) ;
- `N.C.` : pas d'accord ;
- accords acceptés : `C`, `C#m`, `Bb7`, `Cmaj7`, `Dm7`, `F#m7b5`, `Gsus4`, `Edim`, `Caug`, `A6`, `Am6`,
  `D9`, `Cadd9`, et une basse : `C/E`, `Am/G`.

**Enregistrer** écrit `paroles/<id>.lrc` et `accords/<id>.txt` dans le dossier karaoké puis réanalyse le
morceau (vidéo, set, page iReal). Ces corrections ne sont jamais écrasées par une relance. Pour revenir
à la détection automatique, supprimer le fichier correspondant et refaire le morceau. Le découpage en
mesures reste celui de la détection : on change les accords, pas la place des mesures. Dans iReal Pro,
`Am . . F` devient un partage égal (le format des liens ne porte pas les temps).
