# Chord sources: pasted tabs and open datasets, merged with the detection

Part 2 of the chord-correction work. Part 1 (shipped) gave the pipeline better detectors: Jiang 2019 by default, BTC,
consonance-ACE, madmom.

## Why

Even the best detector gets chord *types* wrong: major/minor, missed 7ths and sus. It also reads the bass as the
root. Human-made charts usually get the chord names right but have no timing. Many songs also only write the chords
once, for the first verse and chorus, or list four chords at the top. Michel wants to bring those charts in and let
the pipeline place them on the music.

## What Michel gets

### In the « Corriger » window

- **« Rechercher la grille… »** opens the browser on a search for « titre artiste » on Ultimate Guitar and on La Boîte
  à chansons. Michel picks the version he trusts. Karaifyer never downloads from these sites itself.
- **« Importer une grille… »** opens a sheet with a text area:
  - Michel pastes a tab, or opens a `.txt`, ChordPro (`.cho`, `.chopro`) or patadata (`.sg`) file.
  - « Appliquer » merges it with the detection and **replaces the grid's cells immediately**, as one undoable step
    (⌘Z).
  - Bars where the tab and the audio disagree are outlined in **orange**, with the help text « grille et audio
    diffèrent : à vérifier à l'oreille ».
  - A summary line says what happened, e.g. « 42 accords placés sur les paroles, 18 mesures complétées par répétition,
    6 à vérifier ».
- **When an open dataset has a chart for the song,** a banner appears at the top of the chords column:
  - The banner reads « Grille trouvée dans patadata (ou Chordonomicon) : appliquer ? », with « Appliquer » and
    « Ignorer ».
  - « Appliquer » does the same as an import.
  - « Ignorer » hides the banner for this song, remembered.
  - Nothing is changed without Michel's click.
- **« Afficher la progression d'accords »:**
  - The button is enabled when Chordonomicon has the song. It opens a **floating panel**, a small non-modal window
    above the Corriger window, that stays open until Michel closes it or closes the Corriger window.
  - The panel shows the song's whole progression as Chordonomicon has it, one section per line:
    `Intro 1 : E G D A`, `Couplet 1 : D A D A …`, `Refrain 1 : E D A E D E D A Bm D`…
  - Section tags are written in French. Chord symbols use the grid's usual notation: `Bmin` → `Bm`, `Fs` → `F#`.
  - It's for reading while listening. It changes nothing by itself.
- **Saving:** as today, « Enregistrer » writes the grid to `accords/<id>.txt` (Michel's correction, which wins over
  the detection) and re-analyses the song.
- **The orange marks are a review aid for the session.** They aren't saved.

### The open datasets

- **What they are:**
  - **Chordonomicon:** CC BY-NC 4.0, about 680,000 progressions labelled by section, keyed by Spotify track id. It's
    an Ultimate Guitar scrape published by researchers.
  - **patadata:** about 1,000 songs, mostly French, chords inline in the lyrics. No licence stated, so it's for local
    private use only.
- **Downloading:**
  - Réglages gets a « Grilles ouvertes » row with « Télécharger » (about 100 MB, once) and the date of the copy.
  - The command line equivalent is `karaoke grilles telecharger`.
  - Files go to `$KARAOKE_HOME/grilles/`: `chordonomicon.parquet`, and `patadata/` at a pinned commit.
  - The row shows the licences in one line.
- **Spotify ids:**
  - Chordonomicon is keyed by Spotify id. The manifest gets an optional `spotify` column, filled by
    `karaoke grilles lier --feuille "<recording sheet.csv>"`.
  - Karaifyer runs it with the recording sheet it already knows.
  - Rows are matched on the sheet number at the start of each audio file name (« 41 - … »).
- **Storing each progression:**
  - After a download, and after `grilles lier`, every song with a Chordonomicon match gets its raw progression saved
    as is in `$KARAOKE_HOME/grilles/progressions/<id>.txt`, e.g.
    `<intro_1> E G D A <verse_1> D A D A … <chorus_1> E D A E D E D A Bmin D …`.
  - `karaoke etat --json` exposes it as `progression` (null when there is none). That's the data the panel and the
    banner use.
- **Matching:**
  - Chordonomicon matches on `spotify`. A song with two different rows for one id is skipped as unreliable.
  - patadata matches on the artist folder and the song title, normalised: lower case, no accents, punctuation as
    `_`.

## How the merge works

Everything happens in Python (`karaoke/chord_sources.py`), called by the app through
`karaoke grilles fusionner --id <id> [--texte -] [--source patadata|chordonomicon] --json`.

**Inputs:**
- the song's beats and bars;
- the **detected** per-beat chords: the detection, not Michel's correction, from the chords step result. It comes
  from a new `detection` field the step keeps when a correction exists;
- the lyrics' words with their times (lyrics step result);
- the chart.

**Parsing the chart:**
- **Formats:**
  - « chords above lyrics » lines: a line made only of chord symbols sits above the lyric line below it, and each
    chord's column gives its character offset;
  - ChordPro `[C]` inline;
  - patadata `\[C]` inline;
  - Chordonomicon `<verse_1> C Amin F G`, with sections but no lyrics.
- **Normalisation:**
  - Section headings are kept: [Verse], [Chorus], Couplet, Refrain, `\begin{chorus}`.
  - `capo N` is read.
  - Symbols are normalised to the grid's vocabulary: `min` → m, `s` → #, `&` → b, and Harte names through `symbol`.

**Steps, in order:**
1. **Transposition.** The chart is transposed by its capo. Then a single offset (0–11) is chosen: the one that best
   matches the detected roots over the whole song.
2. **Chords placed on the words** (charts with lyrics):
   - Each chart lyric line is matched to a song lyric line by normalised text similarity, in order, allowing skips.
   - Each chord's character offset maps to a word, the word's start time to the nearest beat, and the chord sounds
     from that beat until the next placed chord.
3. **Repetition:**
   - A song line with no chart chord gets the chords of a chart line with the same text (a repeated chorus).
   - Lines that are still empty, grouped into sections (by the chart's headings, or by gaps in the lyrics), get the
     chords of the earlier section whose detected roots bar by bar match best, if they match at least 70 %. Copying is
     bar by bar.
4. **Vocabulary**, for every beat still not covered (instrumental parts, songs whose chart has no lyrics, such as
   Chordonomicon): the detected chord is replaced by the chart's most frequent chord with the same root. If there's
   none, the detected chord stays.
5. **Agreement check** for every chord from steps 2–3, against the detection at that beat:
   - **Same root and same bass:** the chart's chord is used. This is how chord types get fixed: C# → C#m, A → Amaj7.
   - **Different root or bass:** the chart's chord is used, with the **detected bass** added as a slash: chart A +
     detected F# → A/F#, written F#m7 by the existing root-position rule; chart C + detected E → C/E. The bar is
     **flagged**.
   - **No detection at that beat (N.C.):** the chart's chord, no flag.

**Output:** the per-beat chords are cut into the existing bars (same bar count as the grid, so the correction file
always matches), as cells, plus the list of flagged bars and the counts for the summary line.

## Out of scope

- Fetching tabs from Ultimate Guitar or La Boîte à chansons automatically, or a browser button that sends a page.
- Using the separated bass stem to correct the detected bass.
- Saving the orange marks.
- Merging several charts for one song.

## Testing

- **Python:**
  - parsing each format (chords-above-lyrics with column offsets, ChordPro, `.sg`, Chordonomicon, capo, headings);
  - choosing the transposition;
  - placement on words;
  - chorus repetition by text;
  - verse repetition by detected roots;
  - the vocabulary rule;
  - the agreement rule (same root → chart; different root → chart/bass + flag);
  - the bar count preserved;
  - dataset matching (Spotify id, slug), skipping duplicate ids;
  - `grilles lier` on a sheet fixture;
  - the progression saved as is for a matched song, and exposed by `etat`;
  - `grilles fusionner --json`.
  - Real data: Danser with a pasted chord-above-lyrics tab built from Michel's chart. The merged grid must give F#m7
    where he wrote A/F#, and C#m everywhere.
- **Swift:**
  - the import sheet's result applied as one undoable step;
  - flagged bars outlined;
  - the banner shown only when the pipeline reports a chart and the song wasn't ignored;
  - progression formatting (section tags in French, one per line, Harte-style symbols to chart notation).
  - Manual: the panel opens, stays above the window, and closes with the window.
- **Manual (Michel's checklist):**
  - paste a tab from Ultimate Guitar for a French song, listen with « Clic » to the orange bars;
  - accept and ignore a dataset suggestion;
  - download the datasets in Réglages.
