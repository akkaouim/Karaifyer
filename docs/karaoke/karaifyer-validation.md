# Karaifyer validation (Michel)

Build: `cd karaifyer && ./build-app.sh --install`. Fill in each result (✅ / ❌ + note).

| # | Check | Result |
|---|---|---|
| 1 | Karaifyer opens; macOS asks for system audio recording and control of Spotify; SysRec still opens and records as before | |
| 2 | Enregistrement tab: record 2 songs from a short list | |
| 3 | Karaoké tab: the songs appear; « Ajouter des morceaux… » with an MP3 from outside SysRec adds a row (title from the tags or the file name) | |
| 4 | Ticking/unticking Retirer, changing Langue, and « Changer de Set List… » (right-click): `manifeste.csv` is updated (open it to check); the package / set dots go grey | |
| 5 | Analyser (2 new songs): progress bar, current step, time left, live terminal | |
| 6 | Pause for **30 minutes during « separate »**, then Reprendre: the step finishes normally (no « timeout ») and the analysis continues | |
| 7 | Arrêter après ce morceau: the current song finishes, the next one doesn't start | |
| 8 | Arrêter maintenant during « separate », then Analyser: the step is redone, no song reported done wrongly | |
| 9 | Right-click: open folder / video / set / chord grid / journal | |
| 10 | Editor: playback, current line and bar highlighted, ⏱, edit a lyric line and a chord (`Am . . F`), Enregistrer → video and iReal page updated with the correction | |
| 11 | Re-run « Refaire le morceau »: the corrections from #10 are still there | |
| 12 | Start a recording while an analysis runs: Karaifyer proposes to pause the analysis (« Annuler » or Escape doesn't start the recording) | |
| 13 | Réglages (⌘,): the three paths; choosing a wrong karaoke folder shows the orange banner and disables Analyser; « Défaut » restores it | |
| 14 | Editor: type in a lyric or chord cell and click **Enregistrer** straight away (no Return): the typed text is saved | |
| 15 | Editor: type « je t'aime » in a lyric line — spaces type normally (Lecture/Pause is **⌥ Espace**) | |
| 16 | Editor: start editing one line's text, click ⏱ on another line (it moves), then press Return: the text lands on the line you were editing | |
| 17 | Table: tick Guit. then Basse quickly on one song: `retirer` ends as `guitar;bass` | |
| 18 | Accept « Mettre en pause » when starting a recording during an analysis: when the recording batch ends, the analysis resumes by itself | |
| 19 | Quit Karaifyer during an analysis: it asks first; after quitting, no `karaoke traiter` process is left (Moniteur d'activité) | |
| 20 | During a run: title/artist, Set List, Retirer, Langue, Ajouter and Analyser are disabled (a notice says why); « Ouvrir… » still works; everything unlocks at the end or after Arrêter | |
| 21 | Marker column: spinner on the song being processed (pause symbol while paused), clock on the waiting ones, check/cross when finished; nothing on songs outside the run | |
| 22 | Hover the Statut cell of an « alerte » song: the reasons are listed; hover a dot: the step's name, what it does, its state and any error | |
| 23 | Video: in an instrumental break of a bar or more the chord row appears (current bar yellow) instead of a frozen lit line; the grey next-line preview shows its chords above it | |
| 24 | Lecteur: a single click only selects; double-click, « Charger » or Return loads; the loaded song shows ▶︎; non-ready songs are greyed out with the reason | |
| 25 | Lecteur: video and voice stay in sync over a whole song; ⏮ goes back to the start; dragging the position bar jumps video and audio together | |
| 26 | Lecteur: faders, M and S are heard at once (solo isolates, mute wins over solo); Master changes the overall level | |
| 27 | Lecteur: a bar-snapped loop repeats with no gap; « Boucle » and « Effacer » work | |
| 28 | Lecteur: changing the BPM changes speed without changing pitch, video and click follow; transposing changes pitch without changing tempo, the reminder shows | |
| 29 | Lecteur: the mix, tempo, pitch and loop come back after reopening the song and after restarting the app | |
| 30 | Lecteur: double-click on the video goes full screen, double-click or Escape exits; Space plays/pauses but types a space in the search field | |
| 31 | Export: « Master seul » in AAC, MP3, WAV and FLAC sounds like the player's mix (incl. a muted part, tempo, pitch); « Vidéo + master » MP4 stays in sync at a changed tempo; « Annuler » leaves no file; the sheet remembers the choices | |
| 31 bis | Corriger : each bar cell shows its beat count top right (« 4 t. »), orange when it differs from the time signature; it updates at once after a bar fix | |
| 32 | Corriger : « Clic » on, the click follows the music after a seek, pause/resume and a bar fix during playback; its volume is separate and remembered | |
| 33 | Corriger : Danser — right-click bar 50 « Décaler … plus tard » ×2, the click's accent falls on beat 1 again to the end; ⌘Z undoes both, chords follow | |
| 34 | Corriger : a waltz set to 3/4 shows 3-beat cells; after « Enregistrer », the video's chord rows and the Lecteur's click accent every 3 beats | |
| 35 | iReal : a song set to 12/8 imports as 12/8 Slow Rock; 4/4 + Swing as Medium Swing | |
