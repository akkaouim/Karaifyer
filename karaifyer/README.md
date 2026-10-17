# Karaifyer (application Mac)

Application macOS pour préparer le spectacle karaoké. **Mode d'emploi complet, avec captures :
[docs/guide/GUIDE.md](../docs/guide/GUIDE.md).**

- **Enregistrement :** l'enregistreur Spotify, issu de SysRec (désormais obsolète). Il ajoute un filet de
  sécurité : une capture défectueuse est détectée, la capture est reconstruite et la ligne réessayée, sans
  jamais garder un fichier abîmé. Une ligne de synthèse remplace les milliers de lignes de silences, et un
  récapitulatif « À vérifier » termine chaque série.
- **Karaoké :**
  - le manifeste en tableau : titre, artiste, parties jouées en live, langue ; la Set List au clic droit ;
  - un statut détaillé et une pastille par étape (orange quand une alerte concerne cette étape) ;
  - l'analyse lancée depuis l'app, un morceau à la fois, avec Pause / Arrêter après ce morceau / Arrêter
    maintenant ;
  - une barre de progression, des marqueurs d'avancement et un terminal horodaté ;
  - un éditeur de paroles et d'accords avec lecture.

L'analyse elle-même reste faite par la commande `karaoke` (dossier `karaoke/`), que l'app pilote. Tout marche
aussi en ligne de commande, sans l'app.

## Construire et installer

```sh
cd karaifyer
./build-app.sh             # → karaifyer/Karaifyer.app
./build-app.sh --install   # → ~/Applications/Karaifyer.app
```

Seuls les Command Line Tools sont nécessaires, pas Xcode. L'app a son icône dans le Dock et une icône dans la
barre des menus. Au premier lancement, macOS demande l'enregistrement de l'audio du système et le contrôle de
Spotify.

**Réglages (⌘,) :**
- le dossier karaoké (par défaut `/Volumes/Hypermnesia/karaoke`) ;
- le gabarit Ableton ;
- le projet `karaoke` (par défaut `~/Documents/mp3-pipeline/karaoke`).

## Architecture

- `Sources/KaraifyerCore/` : la logique testée, sans interface :
  - lecture de `karaoke etat --json` et des événements de `traiter --json` ;
  - LRC et grille d'accords (même syntaxe que le pipeline) ;
  - machine d'état d'exécution (pause, reprise, arrêts) et estimation du temps restant ;
  - marqueurs d'avancement, textes d'aide, détection des captures défectueuses ;
  - lancement des processus dans leur propre groupe, pour que la pause et l'arrêt atteignent toute l'analyse.
- `Sources/Karaifyer/` : l'interface SwiftUI et l'enregistreur (Core Audio, contrôle de Spotify).
- **Tests :**
  `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- **Captures du guide :** `Karaifyer --screenshots <dossier>` rend les vues de l'app, le rapport et la page
  iReal en PNG à partir des vraies données, puis quitte.
- **Validation manuelle :** [docs/karaoke/karaifyer-validation.md](../docs/karaoke/karaifyer-validation.md).
