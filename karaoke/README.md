# Karaoké live : pipeline d'analyse

Transforme les fichiers enregistrés (Karaifyer, ou n'importe quel fichier audio) en un dossier prêt à jouer
par morceau :
accompagnement (sans voix ni parties jouées en live), clic avec décompte, voix guide,
6 pistes séparées, grille d'accords (`accords.txt`), paroles synchronisées (`.lrc`) et vidéo
de paroles (`.mp4`, accords au-dessus des syllabes), plus un rapport global trié par risque et
des liens d'import iReal Pro. Au quotidien, tout se pilote depuis l'app **Karaifyer**
([guide](../docs/guide/GUIDE.md)) ; les commandes ci-dessous restent disponibles.

```sh
export KARAOKE_HOME=~/Karaoke                 # ou un disque externe (≈ 0,7 Go par morceau)
cd karaoke
uv run karaoke init                          # crée le dossier : arborescence, manifeste, gabarit Ableton par défaut
uv run karaoke manifeste --audio "$HOME/Music/SysRec/Karaoké - Feuille 1"
#   puis compléter dans $KARAOKE_HOME/manifeste.csv : retirer (ex. guitar;bass;piano), langue, partie
uv run karaoke traiter                       # tout ; reprend là où ça s'est arrêté
uv run karaoke traiter --ids 041 --forcer package   # refaire un morceau (ex. après changement de « retirer »)
uv run karaoke rapport                       # rapport.csv / rapport.html triés par risque
uv run karaoke sets                          # un set Ableton par morceau, rangé par Set List → $KARAOKE_HOME/sets/
uv run karaoke ajouter fichier1.mp3 …        # ajouter des morceaux depuis n'importe quels fichiers audio
uv run karaoke modifier --id 042 --champ retirer --valeur "guitar;piano"   # une case du manifeste
uv run karaoke etat --json                   # état de chaque morceau (utilisé par Karaifyer)
```

La colonne `partie` du manifeste est la **Set List** (le nom affiché dans Karaifyer).

**Sets Ableton.** `karaoke sets` part du gabarit (`gabarit/gabarit Project/gabarit.als`, jamais modifié) et
écrit **un `.als` par morceau** dans `sets/<partie>/` : une piste par canal XR18 (10 clic, 11 voix lead,
12 guitare, 13 basse, 14 piano, 15 batterie, 16 back vocals, 17–18 accompagnement), la vidéo des paroles,
une **mesure 1 silencieuse** qui place les faders de la XR18 (parties de `retirer` à zéro, le reste à 0 dB),
le morceau et son repère en **mesure 2** (revenir au repère relance le clic sans renvoyer les faders) et, à la
fin, un clip qui **arrête Live automatiquement**. Le set s'ouvre sur la mesure 1.

Réglages, une seule fois :
1. XR18 : X Air → Setup → Mixer → MIDI Config → « USB Rx » activé.
2. Mac : Configuration audio et MIDI → Fenêtre → Studio MIDI → Pilote IAC → « Le périphérique est en ligne ».
3. Gabarit : ajouter une piste MIDI « Auto stop », sortie MIDI « IAC Driver (Bus 1) ».
4. Live → Réglages → Tempo & MIDI : entrée « IAC Driver (Bus 1) » → Remote = On.
5. Live en mode MIDI Map (⌘M), cliquer sur Stop, lancer `uv run karaoke apprendre-stop`, quitter MIDI Map,
   enregistrer le gabarit.

Colonne `retirer` : les parties jouées en live (`guitar`, `bass`, `piano`, `drums`, et `other` pour
l'accompagnement 17–18, ex. claviers joués en live). Elles restent
disponibles sur leur canal, fader à zéro au départ du morceau.

**Accords et iReal Pro.** Les accords sont détectés sur les pistes harmoniques (basse, guitare, piano,
autres ; détecteur au choix : `KARAOKE_ACCORDS` = `jiang` (défaut), `btc`, `ace` ou `madmom`, réglé par
Karaifyer ; repli sur le mix complet quand les pistes harmoniques sont muettes, chansons a cappella), calés sur les temps : `sortie/<dossier>/accords.txt` (4 mesures par ligne)
et, dans la vidéo, au-dessus de la syllabe chantée au changement. Après chaque `traiter`,
`$KARAOKE_HOME/ireal/<partie>.html` contient un lien par morceau : l'ouvrir sur l'appareil où iReal Pro
est installé et toucher un titre pour l'importer (tonalité incluse ; le tempo se règle dans iReal).
Détection automatique : à vérifier à l'oreille. Jiang et BTC nomment 7e, sus et accords renversés (un A/F# est
écrit F#m7) ; madmom ne connaît que majeur/mineur. Le code et le modèle de chaque détecteur sont téléchargés à la
première utilisation, à une version figée (`~/.cache/karaoke/chords/`).

**Paroles.** Sources, dans l'ordre :
1. ta correction (`paroles/<id>.lrc`, écrite par l'éditeur de Karaifyer) ;
2. LRCLIB, paroles synchronisées ; chaque ligne est recalée sur le moment où son premier mot est chanté, et
   s'affiche 0,5 s avant dans la vidéo ;
3. LRCLIB texte seul, ou ton texte `paroles/<id>.txt`, alignés sur la voix ;
4. sinon, **transcription** de la voix principale (Whisper large-v3, environ 1,1 × la durée du morceau ;
   alerte « à relire »).

Les mots et syllabes sont toujours alignés sur la voix isolée. La vidéo :
- allume les syllabes au moment où elles sont chantées ;
- place les accords au-dessus de la syllabe où ils changent ;
- annonce la ligne suivante avec ses accords ;
- affiche la grille de 4 mesures pendant les passages instrumentaux.

**Paroles manquantes ou à corriger** (sans l'app). Déposer dans `$KARAOKE_HOME/paroles/` :
- `<id>.txt` : texte brut, aligné automatiquement sur la voix (marche aussi hors ligne) ;
- `<id>.lrc` : paroles synchronisées, prioritaires sur tout le reste. Pour corriger un
  calage, copier `sortie/<dossier>/paroles.lrc`, le corriger, et le déposer sous ce nom :
  sa ligne `[karaoke:decalage=…]` (à garder) indique qu'il est déjà au temps du spectacle.
  Un `.lrc` sans cette ligne est lu au temps de l'enregistrement d'origine (comme LRCLIB).

La relance refait automatiquement les paroles et la vidéo de ce morceau.

**Temps et clic.** Beat This! détecte les temps, puis la grille est nettoyée :
- les temps sautés dans les passages calmes (demi-tempo) sont rétablis ;
- les temps parasites sont retirés ;
- les barres de mesure sont reconstruites par passage régulier.

Les morceaux à tempo libre ou qui dérivent vraiment ne sont pas touchés.

**Statuts du rapport.** `ok`, `alerte` (à vérifier), `a_reessayer` (LRCLIB injoignable, relancé
automatiquement une fois par Karaifyer), `echec` (voir `travail/<id>/journal.log`). Les alertes :
- **tempo instable** : moins de 85 % du morceau dans son tempo principal (±5 %) ;
- **dérive du clic** : un passage où le clic s'écarte de plus de 30 ms de la batterie ; jugé seulement si
  assez de temps tombent sur un coup de batterie ;
- **paroles à vérifier** : moins de 90 % des mots calés à ±0,5 s ;
- **paroles transcrites : à relire** ; **sans paroles**.

Chaque étape est indépendante : modifier une étape ne refait les suivantes que si son
résultat change. Conception et mesures : `docs/karaoke/` ; tests : `uv run pytest`
(rapides) et `KARAOKE_SAMPLE=<fichier> uv run pytest -m slow` (modèles réels).
