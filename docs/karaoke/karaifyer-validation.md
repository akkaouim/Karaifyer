# Karaifyer validation (Michel)

Build: `cd karaifyer && ./build-app.sh --install`. Fill in each result (✅ / ❌ + note).

| # | Check | Result |
|---|---|---|
| 1 | Karaifyer opens; macOS asks for system audio recording and control of Spotify; SysRec still opens and records as before | |
| 2 | Enregistrement tab: record 2 songs from a short list | |
| 3 | Karaoké tab: the songs appear; « Ajouter des morceaux… » with an MP3 from outside SysRec adds a row (title from the tags or the file name) | |
| 4 | Ticking/unticking Retirer, changing Langue and Partie: `manifeste.csv` is updated (open it to check); the package / set dots go grey | |
| 5 | Analyser (2 new songs): progress bar, current step, time left, live terminal | |
| 6 | Pause for a few minutes, then Reprendre: the analysis continues where it was | |
| 7 | Arrêter après ce morceau: the current song finishes, the next one doesn't start | |
| 8 | Arrêter maintenant during « separate », then Analyser: the step is redone, no song reported done wrongly | |
| 9 | Right-click: open folder / video / set / chord grid / journal | |
| 10 | Editor: playback, current line and bar highlighted, ⏱, edit a lyric line and a chord (`Am . . F`), Enregistrer → video and iReal page updated with the correction | |
| 11 | Re-run « Refaire le morceau »: the corrections from #10 are still there | |
| 12 | Start a recording while an analysis runs: Karaifyer proposes to pause the analysis | |
| 13 | Réglages (⌘,): the three paths; choosing a wrong karaoke folder shows the orange banner and disables Analyser; « Défaut » restores it | |
