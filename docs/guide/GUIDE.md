# Karaifyer : guide d'utilisation

Karaifyer prépare un spectacle karaoké live. Il enregistre des chansons depuis Spotify, puis les analyse.
Chaque morceau ressort avec :
- les pistes séparées pour la XR18, avec un clic ;
- une vidéo des paroles avec les accords ;
- une grille d'accords et un lien iReal Pro ;
- un set Ableton prêt à jouer.

Tout se fait dans une seule fenêtre, avec deux onglets : **Enregistrement** et **Karaoké**.

---

## 1. Installation et premier lancement

Sur un Mac neuf (macOS 26 ou plus récent), dans le Terminal :

```sh
xcode-select --install                    # outils de développement d'Apple (pas besoin de Xcode)
brew install uv ffmpeg git                # installer Homebrew d'abord si besoin : https://brew.sh
git clone https://github.com/akkaouim/Karaifyer.git    # n'importe où
cd Karaifyer/karaifyer && ./build-app.sh --install     # → ~/Applications/Karaifyer.app
```

**Au premier lancement**, Karaifyer propose de **créer le dossier karaoké**. Par défaut c'est `~/Karaoke`, ou
« Choisir un autre emplacement… », par exemple sur un disque externe. Il y crée tout ce qu'il faut :
- les dossiers de travail ;
- un manifeste vide ;
- un gabarit Ableton par défaut, à adapter à ton routage si ta table n'est pas une XR18 câblée de la même façon.

Les outils d'analyse et leurs modèles se téléchargent seuls à la première analyse (plusieurs Go : prévoir du
temps et de la place).

**Premier lancement :** macOS demande deux autorisations, à accepter :
- **enregistrer l'audio du système**, pour capter Spotify ;
- **contrôler Spotify**, pour lancer chaque titre et savoir quand il se termine.

**Où trouver l'app :** Karaifyer a son icône dans le Dock et dans ⌘-Tab. Une petite icône dans la barre des
menus donne l'état de l'enregistrement et de l'analyse en un coup d'œil.

**Réglages (⌘,) :** ils indiquent où se trouvent le dossier karaoké, le gabarit Ableton et le code du pipeline
(le dépôt cloné, trouvé automatiquement). « Tout est prêt » en vert signifie que rien ne manque. Sinon, un bandeau orange
dans l'onglet Karaoké dit quoi faire, par exemple « disque débranché ».

**Changer de dossier karaoké :** le bouton avec l'icône de disque, dans la barre de l'onglet Karaoké, montre le dossier
utilisé (par exemple « Hypermnesia › karaoke »). Il propose :
- **Changer de dossier karaoké…** : choisir le dossier qui contient `manifeste.csv`, ou un dossier vide pour en
  commencer un (le bandeau orange propose alors de le créer). Si vous choisissez par erreur le disque au lieu du dossier
  karaoké qu'il contient, l'app propose d'utiliser ce dossier-là.
- **Récents** : revenir en un clic à un des 5 derniers dossiers utilisés (par exemple un par soirée).
- **Afficher dans le Finder.**

Le changement est refusé pendant une analyse ou si une fenêtre Corriger a des modifications non enregistrées. Le morceau
chargé dans le Lecteur est déchargé et les fenêtres Corriger se ferment. Le même choix se fait aussi dans les Réglages.

**Grilles ouvertes** (Réglages) : « Télécharger » récupère Chordonomicon et patadata (≈ 100 Mo, une fois, usage
privé) et relie les morceaux par la feuille d'enregistrement (identifiants Spotify).

**Détecteur d'accords** (Réglages) :
- **Jiang 2019 (recommandé)** : le meilleur sur les morceaux testés ; nomme aussi les renversements, 9e et 11e ;
- **BTC** : presque aussi bon, 7e et sus ;
- **consonance-ACE** : moins juste, mais le seul qui s'en sort sur un enregistrement abîmé ;
- **madmom (ancien)** : majeur/mineur seulement.

Le choix vaut pour les analyses suivantes ; en changer refait l'étape des accords (≈ 10 s par morceau), sans toucher
aux grilles corrigées à la main. La première utilisation d'un détecteur l'installe (une connexion requise une fois).
Le journal du morceau indique le détecteur utilisé.

![Réglages](images/04-reglages.png)

---

## 2. Le parcours en bref

1. **Enregistrer** les chansons depuis Spotify (onglet Enregistrement).
2. **Ajouter** les morceaux à analyser (onglet Karaoké), y compris des fichiers qui ne viennent pas de Spotify.
3. **Régler** chaque morceau : parties jouées en live, langue, Set List.
4. **Analyser**. Cela peut tourner la nuit (environ 9 min par morceau) et reprend là où ça s'est arrêté.
5. **Vérifier** les morceaux « à vérifier », grâce au statut, aux pastilles et au rapport.
6. **Corriger** paroles et accords à l'oreille si besoin.
7. **Jouer** : ouvrir le set Ableton du morceau, le projecteur affiche la vidéo.

---

## 3. Enregistrer depuis Spotify

![Onglet Enregistrement](images/05-enregistrement.png)

- **Load List…** charge la feuille exportée en CSV (colonnes titre, artiste, lien Spotify, proposé par).
- **Ajouter un morceau…** ajoute une chanson sans passer par le CSV : coller le lien Spotify du morceau (le titre
  et l'artiste s'affichent), et éventuellement « Proposé par ». Le morceau s'ajoute à la fin de la liste (M1, M2…)
  pour cette session seulement : en quittant sans l'avoir enregistré, ou en chargeant une autre liste, il
  disparaît. Clic droit → « Retirer de la liste » l'enlève (un fichier déjà enregistré est gardé).
- **Start** lance l'enregistrement. Chaque ligne est jouée dans Spotify, enregistrée sans perte (FLAC, plus
  un MP3 en option) puis découpée exactement à la fin du titre. L'enregistrement capte uniquement Spotify,
  pas les autres sons du Mac.
- **Dossier de sortie :** tous les enregistrements vont dans le dossier choisi (« Change… »), quelle que soit
  la liste chargée ; aucun sous-dossier n'est créé par liste. Le journal `sysrec-log.txt` de ce dossier
  s'allonge à chaque série, avec le nom de la liste.
- **Noms des fichiers :** « Titre - Artiste.flac » (et .mp3), sans numéro. Si ce nom est déjà pris par un autre
  morceau, un suffixe est ajouté : « Titre - Artiste (2).flac ». Aucun fichier n'est jamais écrasé.
- **Reprise :** un morceau est reconnu par son identifiant Spotify, rangé dans le fichier (pas par son nom) :
  une ligne dont le morceau est déjà dans le dossier est sautée, même s'il vient d'une autre liste. Le même
  morceau présent deux fois dans une liste n'est enregistré qu'une fois. Pour réenregistrer un titre, supprime
  ses fichiers et relance **Start**. Un petit fichier caché `.karaifyer-index.json` évite de relire tous les
  fichiers à chaque fois ; le supprimer ne fait rien perdre.
- **Change… (dossier de sortie) :** après le choix du dossier, trois boutons :
  - « Déplacer les fichiers » : les enregistrements et le journal partent dans le nouveau dossier ;
  - « Utiliser sans déplacer » ;
  - « Annuler » (ou Échap) : rien ne change.
  Le déplacement n'est pas proposé vers un dossier situé à l'intérieur du dossier actuel.
- **Déplacer vers…** (clic droit sur des lignes) : leurs fichiers (FLAC, MP3) partent dans le dossier choisi,
  sans jamais écraser un fichier existant (il est alors laissé en place et signalé). Le manifeste karaoké suit
  (une copie est gardée) et rien n'est réanalysé. Les lignes déplacées apparaissent « à enregistrer » tant que
  le dossier de sortie n'est pas celui-là.
- **Mise à jour des noms (une fois) :** au premier lancement de cette version, une fenêtre liste les
  changements avant de les faire :
  - les fichiers « 05 - Titre - Artiste » perdent leur numéro ;
  - les enregistrements des autres listes, rangés dans des sous-dossiers, rejoignent le dossier principal,
    qui devient le dossier de sortie ;
  - les sous-dossiers sans morceau nouveau (par exemple « old takes ») ne sont pas touchés ;
  - un même morceau enregistré deux fois est gardé avec un suffixe « (2) », pour que tu le supprimes ;
  - le manifeste karaoké suit et chaque changement est noté dans `sysrec-log.txt`.
  « Plus tard » la reproposera au lancement suivant.
- **Réglages Spotify conseillés :** qualité Lossless (ou Très élevée), normalisation du volume désactivée,
  fondu enchaîné à 0 s.

**Si une prise est abîmée** (micro-coupures, capture défectueuse), Karaifyer la refait. Pour une capture
défectueuse, il reconstruit la capture et relance Spotify avant de réessayer. Si le problème persiste, la
ligne est marquée ✗ « capture défectueuse » et aucun fichier abîmé n'est gardé. En fin de série, le journal
`sysrec-log.txt` résume les lignes « À vérifier ».

---

## 4. L'onglet Karaoké

![Onglet Karaoké](images/01-karaoke.png)

**Enregistrements introuvables :** si des lignes du manifeste pointent vers un fichier qui n'existe plus
(déplacé dans le Finder, disque débranché), un bandeau orange les signale. « Retrouver… » cherche dans le
dossier choisi : par identifiant Spotify, sinon par nom « Titre - Artiste ». La liste trouvée est montrée avant
la mise à jour du manifeste (une copie est gardée).

**Noms des dossiers de sortie :** chaque morceau a son dossier `sortie/Titre - Artiste/` et son set
`sets/<Set List>/Titre - Artiste.als` (« (2) » si un autre morceau porte déjà ce nom). Changer le titre ou l'artiste
renomme le dossier et le set. Les fichiers internes gardent le numéro du morceau (`travail/005/`,
`paroles/005.lrc`, `accords/005.txt`, `mesures/005.json`). Les anciens dossiers « 005_artiste_titre » : un bandeau
bleu propose « Renommer… », une fois. Fermez d'abord les sets ouverts dans Live ; les sets sont refaits (quelques
secondes par morceau), rien d'autre n'est réanalysé, les anciens sets vont à la Corbeille et une copie du manifeste
est gardée.

**Actions rapides :** sur un morceau analysé, ✏️ ouvre la fenêtre Corriger et ▶️ le joue dans le Lecteur.

**Première colonne :** pendant une analyse, l'avancement de chaque morceau ; en dehors, ⟳ orange signale un
morceau « à réanalyser » (corrections enregistrées, titre modifié, réglage changé…). La colonne se trie.

**Colonne Corrigé :** ♬ quand les accords ou les mesures ont été corrigés à la main (les deux changent les accords
de la vidéo), 🎤 quand les paroles l'ont été. Survoler donne les dates. Taper « corrigé » dans la recherche ne
montre que les morceaux corrigés.

**Colonnes BPM, Tonalité, Vérifié :** le tempo habituel du morceau et sa tonalité détectée (« C#m », « Eb »),
une fois analysé. Le bouton « Vérifié » marque un morceau comme contrôlé (la date est gardée dans le manifeste) ; le
statut affiche alors « vérifié » en vert. Un nouveau clic le retire. Une analyse qui change les paroles, les
accords, le mix ou la vidéo le retire aussi, pour que « vérifié » corresponde toujours à ce qui est là ; une
analyse qui ne refait rien le garde.

**Barre d'outils**
- **Ajouter des morceaux…** accepte n'importe quels fichiers audio (FLAC, WAV, MP3, M4A, AIFF). Le titre et
  l'artiste sont lus dans les tags, ou à défaut dans le nom du fichier. Un fichier déjà présent est ignoré.
- **Analyser tout / la sélection.**
- **Rapport** ouvre le rapport global ; **iReal Pro** ouvre la page des liens d'import.

**Colonnes**
- **Titre, Artiste :** modifiables. Clique dans la case, tape, puis Entrée.
- **Retirer (joué en live) :** les parties que vous jouez sur scène. Leur fader XR18 démarre à zéro au début
  du morceau ; les autres démarrent à 0 dB. « Autres » correspond à l'accompagnement (canaux 17–18), par
  exemple des claviers joués en live.
- **Langue :** langue des paroles, utilisée pour l'alignement et la transcription.
- **Statut :** l'état du morceau, suivi du détail des problèmes. Survole-le pour l'explication complète.
- **Étapes :** une pastille par étape de l'analyse.

| Pastille | Signification |
|---|---|
| 🟢 verte | étape faite et à jour |
| 🟠 orange | étape faite, mais son résultat est à vérifier (survole pour voir pourquoi) |
| 🔵 bleue | en cours |
| 🔴 rouge | échec (le message apparaît au survol) |
| ⚪ grise | à faire ou à refaire (un réglage ou une étape précédente a changé) |

**Clic droit sur un morceau**
- Ouvrir le dossier, la vidéo, le set Ableton, la grille d'accords ou le journal.
- **Ouvrir dans le Lecteur** : charge le morceau dans l'onglet Lecteur et y bascule (morceau prêt uniquement).

**Trier et chercher** : un clic sur l'en-tête d'une colonne trie le tableau (un second clic inverse) — le statut se
trie par gravité (échec, à réessayer, à vérifier, ok), les étapes par avancement. Le champ « Rechercher » filtre par
titre, artiste, id ou Set List (accents et majuscules ignorés).
- **Corriger paroles et accords…** (section 7).
- **Changer de Set List…** : la Set List range le set Ableton du morceau dans le bon dossier de la soirée.
- **Refaire le morceau**, ou **Refaire une étape** ▸.
- **Refaire la détection des temps** : oublie la détection des temps enregistrée et la refait (elle est sinon
  réutilisée tant que l'audio ne change pas) ; les corrections de mesure (`mesures/<id>.json`) sont gardées.
- **Retirer du manifeste…** (un ou plusieurs morceaux sélectionnés) : une fenêtre récapitule ce qui part.
  - La ligne est toujours retirée du manifeste, et une copie de l'ancien manifeste est gardée
    (`manifeste.avant-retrait-<date>.csv`). Le rapport, les pages iReal et l'index des grilles sont refaits.
  - Trois cases, avec la place occupée :
    - **Fichiers d'analyse** (`travail/`, `sortie/`, le set Ableton) : cochée ;
    - **Corrections** (`paroles/`, `accords/`, `mesures/`) : cochée ;
    - **Enregistrement audio** (le FLAC) : décochée ; jamais proposée quand une autre ligne du manifeste
      utilise le même enregistrement (005/050, 041/081).
  - **Rien n'est effacé** : tout part dans la Corbeille du Mac et peut en être sorti.
  - Impossible pendant une analyse. Un morceau retiré est déchargé du Lecteur, et sa fenêtre Corriger est fermée.

---

## 5. Analyser

![Analyse en cours](images/02-analyse-en-cours.png)

- **Un morceau à la fois.** Ce qui est déjà à jour est sauté.
- **Pause / Reprendre :** même après des heures. **Arrêter après ce morceau** termine le morceau en cours
  puis s'arrête. **Arrêter maintenant** interrompt tout de suite ; l'étape interrompue sera refaite à la
  prochaine analyse.
- **Pendant l'analyse, les réglages sont verrouillés** (un cadenas l'indique). Ils redeviennent modifiables à
  la fin ou après un arrêt.
- **Marqueurs (colonne de gauche) :**
  - roue qui tourne : le morceau en cours ;
  - horloge : un morceau en attente ;
  - ✓ ou ✗ : un morceau terminé pendant cette analyse.
- **Barre de progression :** affiche le morceau, l'étape et le temps restant estimé. Le **Terminal** montre le
  journal en direct, chaque ligne précédée de son heure (bouton **Copier**).
- **Nouvel essai automatique :** à la fin d'une analyse, les morceaux restés « à réessayer » (service de
  paroles LRCLIB injoignable) sont relancés une fois.
- **Le Mac ne se met pas en veille** pendant l'analyse. Si tu lances un enregistrement pendant une analyse,
  Karaifyer propose de la mettre en pause ; elle reprend toute seule à la fin de l'enregistrement.

---

## 6. Lire le statut et les alertes

| Alerte | Ce que ça veut dire | Que faire |
|---|---|---|
| **tempo instable (X % du morceau hors tempo)** | le tempo varie vraiment (vieil enregistrement, morceau joué sans clic, changement de tempo) | écouter le clic avant le spectacle, ou le couper sur ce morceau |
| **dérive du clic N ms** | sur un passage, le clic s'écarte de la batterie de plus de 30 ms | écouter ce passage au retour |
| **paroles transcrites automatiquement : à relire** | aucune parole trouvée en ligne : elles ont été transcrites depuis la voix | relire et corriger dans l'éditeur |
| **paroles à vérifier : X % des mots calés** | l'alignement des mots sur la voix est imparfait | vérifier dans l'éditeur ou la vidéo |
| **sans paroles** | rien trouvé et rien entendu (instrumental) | déposer un texte `paroles/<id>.txt` si besoin |
| **à réessayer** | service en ligne injoignable | relancer plus tard (fait automatiquement une fois) |

Le **rapport** (bouton Rapport) liste tous les morceaux, du plus à risque au moins à risque :

![Rapport](images/06-rapport.png)

---

## 7. Corriger paroles et accords

**Clic droit sur le morceau, puis Corriger paroles et accords…** La fenêtre s'ouvre par-dessus Karaifyer.

![Éditeur](images/03-editeur.png)

- **Lecture** (Espace quand aucun champ n'est en cours de saisie, ou ⌥ Espace) joue l'enregistrement. La ligne et la mesure en cours sont surlignées en jaune.
- **Volume :** le curseur à droite de la barre de lecture règle le volume (mémorisé pour tous les morceaux).
- **Aller à une ligne :** le bouton ⇥ avant le chronomètre place la lecture au début de la ligne.
- **Clic :** la case « Clic » ajoute un clic sur chaque temps (plus aigu sur le temps 1), avec son propre volume ;
  le compteur « 1/4 » montre le temps en cours, et chaque case affiche en haut à droite son nombre de temps (« 4 t. », en orange quand il diffère de la mesure). Il suit la grille telle qu'elle est dans la fenêtre.
- **Temps 1 décalé :** clic droit sur le numéro d'une mesure :
  - « Décaler le début de la mesure d'un temps plus tôt / plus tard (et les suivantes) » déplace le début de cette
    mesure d'un temps et recompte la suite à partir d'elle, jusqu'à la prochaine mesure verrouillée ;
  - « Verrouiller cette mesure » (🔒) la protège : une correction faite sur une mesure précédente ne la décale pas.
    Par exemple, verrouiller la mesure 70 avant de corriger la 50 limite la correction aux mesures 50 à 69 ;
    verrouiller la mesure qui suit une mesure courte garde cette mesure courte ;
  - les accords suivent leurs temps.
- **Mesure :** le menu à côté de la tonalité choisit 2/4, 3/4, 4/4, 6/8 ou 12/8 ; « Swing » marque un jeu ternaire
  (style iReal).
- Ces corrections sont enregistrées dans `mesures/<id>.json` et reprises à chaque analyse : grille, vidéo, clic du
  Lecteur et iReal suivent.

**Synchroniser les paroles** :
- **Synchroniser** lance le morceau avec les 4 clics du décompte, comme en spectacle (même son que le lecteur de la
  fenêtre : volume et « Clic » compris). Au départ la ligne en grand est vide, la première ligne s'affiche « à venir ».
- **Entrée**, quand la ligne commence à être chantée, la cale à cet instant : elle s'affiche en grand (et en surbrillance
  dans la liste), la suivante passe « à venir ». L'appui est ramené sur le début de la
  voix entendue juste avant (jusqu'à 0,4 s) ; sans voix détectée, l'instant de l'appui est gardé.
- **↑** (ou ⌫) annule le dernier calage, **Espace** met en pause, **Échap** quitte en gardant ce qui est calé. Chaque
  calage s'annule aussi avec ⌘Z.
- **Synchroniser à partir de la ligne en jaune** reprend 2 s avant la ligne précédente, sans tout rejouer.
- En pause, le texte se corrige comme d'habitude (mot, + Ligne), et **Remplacer le texte…** permet de tout remplacer
  (⌘A ⌘V) : les lignes inchangées gardent leur temps.
- **Enregistrer** garde les temps comme correction des paroles (`paroles/<id>.lrc`), qui passe avant LRCLIB ; la
  vidéo est refaite avec les lignes calées.

**Grilles d'accords (tablatures et grilles ouvertes)** :
- **Rechercher la grille…** ouvre une recherche du morceau sur Ultimate Guitar et La Boîte à chansons : choisir la
  version la plus fiable.
- **Importer une grille…** : coller la grille (accords au-dessus des paroles, ChordPro, ou fichier patadata), puis
  « Appliquer ». La grille est fusionnée avec la détection et remplace les cases tout de suite (⌘Z pour revenir) :
  - un accord écrit au-dessus d'un mot tombe sur le temps où ce mot est chanté ;
  - un refrain répété, ou un couplet de même harmonie, reprend les accords déjà placés ;
  - même fondamentale que l'audio : l'accord de la grille gagne (C# devient C#m, A devient Amaj7) ;
  - fondamentale ou basse différente : l'accord de la grille sur la basse entendue (A sur F# s'écrit F#m7), et la
    mesure est entourée d'orange — « grille et audio diffèrent : à vérifier à l'oreille » ;
  - ailleurs, l'accord détecté prend la version de la grille de même fondamentale.
- **Grille trouvée dans patadata / Chordonomicon : appliquer ?** — proposée quand une grille ouverte existe pour le
  morceau ; « Ignorer » ne la propose plus pour ce morceau.
- **Afficher la progression d'accords** : la progression complète de Chordonomicon (une section par ligne), dans une
  fenêtre flottante qui reste au-dessus jusqu'à sa fermeture ou celle de la fenêtre Corriger.
- Les contours orange servent à la relecture et ne sont pas enregistrés ; « Enregistrer » garde la grille comme
  correction (`accords/<id>.txt`).
- **Annuler / Rétablir :** ⌘Z et ⇧⌘Z (ou les flèches en bas à gauche) annulent et rétablissent les
  modifications des paroles, des accords et de la tonalité. Pendant la saisie d'un champ, ⌘Z agit sur son texte.
- **Paroles (à gauche) :** cliquer une ligne y va. Le temps et le texte sont modifiables. ⏱ cale le début de
  la ligne sur la lecture ; + ajoute une ligne, la corbeille la supprime.
- **Accords (à droite) :** une case par mesure, 4 par ligne ; cliquer le numéro va à la mesure. La tonalité
  est modifiable en haut (ex. « C# minor »).
  - `A B` : les deux accords se partagent la mesure ;
  - `Am . . F` : un symbole par temps, `.` prolonge l'accord précédent ;
  - `N.C.` : pas d'accord ;
  - accords reconnus : `C`, `C#m`, `Bb7`, `Cmaj7`, `Dm7`, `F#m7b5`, `Gsus4`, `Edim`, `Caug`, `A6`, `D9`,
    `Cadd9`, avec une basse : `C/E`, `Am/G`. Une case invalide est entourée de rouge.
- **Enregistrer** garde les corrections sans relancer l'analyse : seul ce que tu as modifié devient une
  correction (paroles et/ou accords). Le morceau est marqué « à réanalyser » (⟳ orange dans la première colonne
  de l'onglet Karaoké) ; « Analyser » refait alors la vidéo, le set Ableton et la page iReal, quand tu veux.
- **Les corrections ne sont jamais écrasées** par une nouvelle analyse. Pour revenir à la détection
  automatique, supprime le fichier `paroles/<id>.lrc` ou `accords/<id>.txt` dans le dossier karaoké, puis
  refais le morceau.

**Paroles introuvables en ligne :** Karaifyer les transcrit depuis la voix du chanteur (alerte « à relire »).
Tu peux aussi déposer un texte brut `paroles/<id>.txt` ; il sera calé automatiquement sur la voix.

---

## La vidéo des paroles

Un cadre néon cyan sur un mur de briques, le titre et l'artiste en néon rose qui respire doucement (avec un léger
clignotement de temps en temps) ; le cadre pulse sur chaque temps, plus fort sur le premier temps de la mesure.

- **Grille + paroles** (par défaut) : en haut, **2 lignes de 4 mesures** — la ligne active est toujours en haut, la
  mesure jouée surlignée et un **curseur** qui avance temps par temps ; quand la ligne se termine, celle du dessous
  monte et les 4 mesures suivantes apparaissent. En bas, **les paroles seules** : la ligne chantée qui s'allume
  syllabe par syllabe, la suivante en gris.
- **Accords sur les paroles** : l'ancienne présentation (accords au-dessus des syllabes, rangée de 4 mesures pendant
  les instrumentaux), sur le même fond.
- Le menu **Vidéo** de l'onglet Karaoké choisit la disposition des vidéos rendues par l'analyse (`paroles.mp4`, sets
  Ableton) ; en changer refait les vidéos à la prochaine analyse.

## 7 bis. Le Lecteur : répéter et vérifier

L'onglet **Lecteur** joue un morceau analysé avec sa vidéo. C'est le Mac qui joue, sur sa sortie audio
habituelle, pas la XR18. Il sert à répéter chez soi en coupant sa partie, et à vérifier la séparation en
écoutant chaque piste seule.

![Lecteur](images/08-lecteur.png)

- **Ouvrir un morceau :**
  - cherche par titre, artiste ou numéro (sans te soucier des accents) ;
  - un clic **sélectionne seulement** ; **double-clic**, **Entrée** ou **Charger** ouvre le morceau ;
  - le morceau ouvert est marqué ▶︎, et un morceau grisé n'est pas encore prêt (le survol dit ce qui manque).
- **Vidéo :** dessinée **en direct**, calée sur le son (tempo, boucle et position suivent aussitôt). Double-clic pour
  le **plein écran**, puis double-clic ou Échap pour en sortir. Un morceau analysé avant cette version garde l'ancienne
  vidéo (« Réanalyser pour la vidéo en direct »).
- **Disposition :** « Grille + paroles » (par défaut) ou « Accords sur les paroles », mémorisée.
- **Transport :** ⏮ retour au début, ▶︎/⏸, et la **barre de position** à faire glisser pour aller n'importe où.
  **Espace** lance ou arrête la lecture, sauf pendant que tu tapes dans la recherche.
- **Boucle :**
  - « Début de boucle » et « Fin de boucle » posent la boucle à l'endroit écouté, **calée sur la barre de
    mesure la plus proche** ;
  - « Boucle » l'active, « Effacer » la supprime, et la zone de la boucle apparaît en jaune sur la barre de
    position.
- **Tempo (BPM) :**
  - le tempo du morceau s'affiche (par exemple 100) ; − / + ou une valeur tapée le change, « Original »
    revient au tempo d'origine ;
  - la hauteur ne change pas, la vidéo et le clic suivent ;
  - la plage va de la moitié à 1,5 fois le tempo d'origine.
- **Hauteur :**
  - de −6 à +6 demi-tons, sans changer le tempo ;
  - « Réinitialiser » revient à la tonalité d'origine ;
  - les accords de la vidéo suivent la transposition (pratique pour trouver où poser un capodastre) ; rien n'est
    enregistré ;
- **Exporter le mix… → Vidéo + master** : la vidéo est dessinée telle qu'affichée (disposition, transposition, tempo).
- **Mixeur :**
  - une tranche par piste (Clic, Guide voix, Guitare, Basse, Piano, Batterie, Accompagnement, Back Vocals),
    chacune avec un fader (de −∞ à +6 dB), **M** (couper) et **S** (solo) ;
  - avec un solo actif, seules les pistes en solo sont jouées, et une piste coupée reste coupée même en solo ;
  - le **Master** règle le volume général.
- **Mémorisé par morceau :** le mix, le tempo, la hauteur et la boucle (qui se rouvre désactivée). La première
  fois, le morceau s'ouvre comme au spectacle : les parties « Retirer » à zéro, le reste à 0 dB.
- **Exporter le mix… :** tout le morceau, **tel que tu l'entends** (mix, tempo, hauteur ; la boucle est
  ignorée), avec deux choix :

  | Contenu | Formats et qualité |
  |---|---|
  | **Master seul** | AAC (.m4a) ou MP3 en 128, 192, 256 ou 320 kbps ; WAV ou FLAC en 16 ou 24 bits |
  | **Vidéo + master** | MP4 en 1080p ou 720p, qualité Haute ou Standard, son AAC de 128 à 320 kbps |

  Les derniers choix sont gardés. Une barre suit la progression ; « Annuler » ne laisse aucun fichier.

---

## 8. Ce que produit l'analyse

Pour chaque morceau, un dossier `sortie/<id>_<artiste>_<titre>/` contient :
- `accompagnement.flac`, `guitare.flac`, `basse.flac`, `piano.flac`, `batterie.flac`, `back_vocals.flac`,
  `guide_voix.flac` (voix principale, pour les retours) et `clic.flac` (avec décompte) ;
- `paroles.mp4` (vidéo des paroles), `paroles.lrc` et `accords.txt` (grille, 4 mesures par ligne).

### La vidéo des paroles

- **Introduction :** le titre et les premières mesures, la mesure en cours en jaune.

  ![Intro](images/10-video-intro.png)

- **Pendant le chant :**
  - les syllabes s'allument en jaune au moment où elles sont chantées ;
  - les accords s'affichent au-dessus de la syllabe où ils changent ;
  - la ligne apparaît 0,5 s avant d'être chantée ;
  - la ligne suivante est annoncée en gris, avec ses accords.

  ![Ligne chantée](images/11-video-ligne.png)

- **Passages instrumentaux :** à partir d'une mesure sans chant, la grille de 4 mesures s'affiche, avec la
  mesure en cours en jaune. Avant une longue reprise, un décompte 4-3-2-1 suit les derniers temps.

  ![Instrumental](images/12-video-instrumental.png)

### iReal Pro

La page `ireal/<Set List>.html` contient un lien par morceau. Ouvre-la sur l'appareil où iReal Pro est
installé et touche un titre pour l'importer, tonalité incluse. Le tempo se règle dans iReal.

![iReal Pro](images/07-ireal.png)

### Le set Ableton

**Un set par morceau,** dans `sets/<Set List>/`, construit à partir de ton gabarit. Il s'ouvre sur la
mesure 1 :

| Mesure | Contenu |
|---|---|
| **1** (silencieuse) | envoi des faders à la XR18 (parties jouées en live à zéro, le reste à 0 dB) |
| **2** | début du morceau : le clic et son décompte, puis tout le reste ; le **repère** du morceau est ici |
| fin | **arrêt automatique** de Live |

- **Play** à l'ouverture envoie les faders, puis le clic démarre.
- **Revenir au repère** (mesure 2) relance le clic depuis le début, sans renvoyer les faders.

**Pistes et canaux de la XR18 :**

| Canal XR18 | Piste |
|---|---|
| 10 | Clic (retours seulement) |
| 11 | Voix guide = chant principal (retours seulement) |
| 12, 13, 14, 15 | Guitare, Basse, Piano, Batterie |
| 16 | Back Vocals |
| 17–18 | Accompagnement (stéréo) |

**Réglages à faire une seule fois** pour les faders et l'arrêt automatique : voir `karaoke/README.md`, section
« Sets Ableton ».

---

## 9. Dépannage

- **Bandeau orange « Pas encore de dossier karaoké » :** clique **Créer le dossier karaoké ici** ou choisis un
  emplacement. Si ton dossier est sur un disque externe, branche-le puis clique **Réessayer**.
- **« uv introuvable » ou « ffmpeg introuvable » :** `brew install uv ffmpeg`, puis **Réessayer**.
- **« à réessayer » sur un morceau :** le service de paroles LRCLIB est temporairement indisponible. Relance
  plus tard (Refaire une étape ▸ lyrics), ou attends le nouvel essai automatique de fin d'analyse.
- **La vidéo d'un morceau ne change pas après une correction :** vérifie que le morceau a bien été réanalysé
  (pastilles vertes), puis rouvre la vidéo.
- **Une ligne d'enregistrement est marquée ✗ « capture défectueuse » :** relance-la (supprime le fichier s'il
  existe, puis **Start**). Si ça se reproduit, envoie le journal `sysrec-log.txt`.
- **Quitter pendant une analyse :** Karaifyer demande confirmation, puis arrête proprement l'analyse.
  L'étape interrompue sera refaite.
