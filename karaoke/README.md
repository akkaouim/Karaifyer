# Karaoké live : pipeline d'analyse

Transforme les fichiers enregistrés par SysRec en un dossier prêt à jouer par morceau :
accompagnement (sans voix ni parties jouées en live), clic avec décompte, voix guide,
6 pistes séparées, paroles synchronisées (`.lrc`) et vidéo de paroles (`.mp4`), plus un
rapport global trié par risque.

```sh
export KARAOKE_HOME=/Volumes/Hypermnesia/karaoke     # disque externe (≈ 0,7 Go par morceau)
cd karaoke
uv run karaoke manifeste --audio "$HOME/Music/SysRec/Karaoké - Feuille 1"
#   puis compléter dans $KARAOKE_HOME/manifeste.csv : retirer (ex. guitar;bass;piano), langue, partie
uv run karaoke traiter                       # tout ; reprend là où ça s'est arrêté
uv run karaoke traiter --ids 041 --forcer package   # refaire un morceau (ex. après changement de « retirer »)
uv run karaoke rapport                       # rapport.csv / rapport.html triés par risque
uv run karaoke sets                          # un set Ableton par partie de soirée → $KARAOKE_HOME/sets/
```

**Sets Ableton.** `karaoke sets` part du gabarit (`gabarit/gabarit Project/gabarit.als`, jamais modifié) et
écrit un `.als` par valeur de la colonne `partie` : morceaux enchaînés (4 s d'écart), un repère par titre,
une piste par canal XR18 (10 clic, 11 voix lead, 12 guitare, 13 basse, 14 piano, 15 batterie,
16 back vocals, 17–18 accompagnement) et, au début de chaque morceau, un clip MIDI qui place les faders
de la XR18 : parties de `retirer` à zéro, le reste à 0 dB. Sur la XR18 : X Air → Setup → Mixer →
MIDI Config → « USB Rx » activé.

Colonne `retirer` : les parties jouées en live (`guitar`, `bass`, `piano`, `drums`). Elles restent
disponibles sur leur canal, fader à zéro au départ du morceau.

**Paroles manquantes ou à corriger.** Déposer dans `$KARAOKE_HOME/paroles/` :
- `<id>.txt` : texte brut, aligné automatiquement sur la voix (marche aussi hors ligne) ;
- `<id>.lrc` : paroles synchronisées, prioritaires sur tout le reste. Pour corriger un
  calage, copier `sortie/<dossier>/paroles.lrc`, le corriger, et le déposer sous ce nom :
  sa ligne `[karaoke:decalage=…]` (à garder) indique qu'il est déjà au temps du spectacle.
  Un `.lrc` sans cette ligne est lu au temps de l'enregistrement d'origine (comme LRCLIB).

La relance refait automatiquement les paroles et la vidéo de ce morceau.

**Statuts du rapport.** `ok`, `alerte` (à vérifier en priorité : tempo instable,
paroles absentes ou mal calées, dérive du clic), `a_reessayer` (LRCLIB injoignable :
relancer plus tard), `echec` (voir `travail/<id>/journal.log`).

Chaque étape est indépendante : modifier une étape ne refait les suivantes que si son
résultat change. Conception et mesures : `docs/karaoke/` ; tests : `uv run pytest`
(rapides) et `KARAOKE_SAMPLE=<fichier> uv run pytest -m slow` (modèles réels).
