# Karaoké live : cahier des charges et plan de développement

Oct 12, 2026 · @Michel

## Contexte et objectifs

Le pipeline doit livrer un dossier prêt à jouer pour chacun des 120 morceaux : accompagnement sans les parties jouées en live, clic calé sur l'enregistrement, vidéo de paroles synchronisées.

Le concert est un karaoké live pour un anniversaire. Deux musiciens jouent : Michel (claviers, guitare) et Pierre (guitares, basse, percussions). Les invités chantent en lisant les paroles projetées. Les musiciens jouent au clic : la timeline de chaque morceau est l'horloge maître, et les paroles comme l'accompagnement en découlent.

120 morceaux représentent environ 8 heures d'audio à traiter. Ce volume impose un traitement par lot entièrement automatisé, sans intervention morceau par morceau pendant le calcul.

## Périmètre

Le développement couvre le pipeline d'analyse et la préparation de l'intégration Ableton. L'acquisition audio, la vérification morceau par morceau et les répétitions sont assurées par Michel.

| Élément | Dans le périmètre | Responsable |
| --- | --- | --- |
| Manifeste des morceaux (titre, artiste, durée, ISRC) à partir de la liste Spotify | Oui | Développement |
| Acquisition des fichiers audio | Non : le pipeline accepte tout fichier audio déposé dans le dossier d'entrée, quelle que soit son origine | Michel |
| Séparation des pistes par instrument, grille de temps, clic | Oui | Développement |
| Paroles synchronisées et vidéo de paroles | Oui | Développement |
| Rapport de qualité pour prioriser la vérification | Oui | Développement |
| Gabarit de set Ableton et routage vers la console XR18, selon le plan d'adressage fourni par Michel | Oui | Développement |
| Vérification et correction manuelle | Non | Michel |
| Répétitions et montage du set final | Non | Michel et Pierre |
| Génération automatique des sets Ableton (.als), un par partie de soirée | Oui | Développement |

## Hypothèses et contraintes

Cinq hypothèses conditionnent le plan ; chacune est vérifiée en phase 0 et le plan est ajusté si l'une tombe.

1. **Machine :** Mac Apple Silicon (série M) avec au moins 16 Go de RAM et 60 Go d'espace disque libre. Sur processeur Intel, le temps de calcul serait multiplié par 3 à 5.
2. **Fichiers d'entrée :** un fichier par morceau, version identique à celle référencée sur Spotify (même durée à 2 secondes près), en qualité équivalente ou supérieure à un fichier compressé de 256 kbit/s. Un fichier de moindre qualité dégrade nettement la séparation des pistes.
3. **Logiciel live :** Ableton Live dans une édition qui gère la vidéo en vue Arrangement et au moins 8 pistes. L'édition et la version exacte sont à confirmer : les sets générés dépendent de la version du gabarit.
4. **Matériel :** une console Behringer XR18 utilisée comme interface audio USB (jusqu'à 18 canaux depuis Ableton), avec un plan d'adressage fourni par Michel. Les retours des musiciens passent par des départs auxiliaires de la console, vers un ampli casque ou des intra-auriculaires.
5. **Tempo :** aucun changement de tempo ou de tonalité en live. Les horodatages des paroles restent donc exprimés en secondes, alignés sur l'enregistrement d'origine.

Question ouverte : quelle part des 120 titres est en français ? Les bases de paroles synchronisées couvrent moins bien le répertoire français, ce qui augmente le nombre de textes à fournir par Michel et le temps de vérification.

## Exigences fonctionnelles du pipeline

Le pipeline prend un manifeste et un dossier de fichiers audio, et produit pour chaque morceau un dossier contenant cinq livrables : accompagnement, pistes séparées par instruments (au minimum basse, guitare lead, piano, batterie, et si possible, guitare secondaires et autres instruments (cordes, saxophone, etc.) a adapter suivant les chansons), clic, paroles synchronisées, vidéo de paroles.

### Entrée : le manifeste

Un fichier CSV, une ligne par morceau. Une commande optionnelle le pré-remplit à partir de la playlist Spotify, via l'API Web en lecture des métadonnées uniquement.

| Colonne | Contenu | Exemple |
| --- | --- | --- |
| id | Numéro d'ordre, 3 chiffres | 042 |
| titre, artiste, album | Métadonnées Spotify |  |
| duree_ref_s | Durée de référence Spotify, en secondes | 214 |
| isrc | Identifiant de l'enregistrement | FRZ039800212 |
| fichier | Nom du fichier audio dans le dossier d'entrée | 042.wav |
| retirer | Pistes jouées en live, à retirer de l'accompagnement | guitar;bass |
| decompte_mesures | Nombre de mesures de décompte avant le morceau | 2 |

### Étapes de traitement

1. **Contrôle d'entrée :** vérifier la présence du fichier, comparer sa durée à la référence (alerte au-delà de 2 secondes d'écart), convertir en WAV 44,1 kHz stéréo, détecter le silence initial et le retirer en conservant la valeur du décalage.
2. **Séparation des pistes :** produire 6 pistes (voix, batterie, basse, guitare, piano, autres), puis un mixage d'accompagnement qui exclut la voix et les pistes listées dans la colonne retirer.
3. **Grille de temps :** détecter les temps et les premiers temps de mesure, calculer le tempo moyen et sa stabilité, puis générer un clic audio qui suit les temps détectés (accent sur le premier temps), précédé du décompte. Un morceau dont le tempo varie de plus de 3 % est signalé.
4. **Paroles :** interroger LRCLIB avec titre, artiste, album et durée. Si des paroles synchronisées existent, les recaler du décalage de l'étape 1. Sinon, aligner sur la piste voix, avec WhisperX, les paroles brutes de LRCLIB ou, à défaut, le texte fourni par Michel dans un dossier paroles d'entrée. Aucune transcription automatique : un morceau sans texte est signalé dans le rapport.
5. **Contrôle de calage des paroles :** pour chaque ligne, vérifier la présence d'énergie dans la piste voix à son horodatage, et calculer un taux de lignes bien calées par morceau.
6. **Vidéo de paroles :** générer une vidéo 1920x1080 sans son, décalée de la durée du décompte. Elle affiche le titre pendant le décompte, la ligne en cours mise en évidence et la ligne suivante, ainsi qu'un compte à rebours visuel avant chaque reprise du chant après plus de 8 secondes d'instrumental.
7. **Rapport global :** un tableau de tous les morceaux avec statut, source des paroles, taux de calage, stabilité du tempo et alertes, trié du plus risqué au moins risqué. Il sert de liste de priorité pour la vérification manuelle.
8. **Sets Ableton :** un fichier .als par partie de soirée, créé à partir du set gabarit, avec les morceaux enchaînés, un repère par titre et le routage du plan d'adressage XR18. La répartition et l'ordre viennent d'une colonne partie ajoutée au manifeste.

### Sortie : un dossier par morceau

```
sortie/042_artiste_titre/
  accompagnement.flac    mixage sans voix ni parties live, avec décompte silencieux
  clic.flac              clic avec décompte
  guide_voix.flac        voix isolée, pour les retours des musiciens
  pistes/                les 6 pistes séparées
  paroles.lrc            paroles synchronisées, recalées sur le décompte
  paroles.mp4            vidéo de paroles
  temps.csv              temps et premiers temps de mesure détectés
  rapport.json           métriques et alertes du morceau
```

Tous les fichiers audio d'un même dossier démarrent au même instant zéro et ont la même durée. C'est la condition de la synchronisation dans Ableton : il suffit de les poser tous au début de la timeline.

## Exigences non fonctionnelles

Le traitement des 120 morceaux doit tenir en une nuit et pouvoir reprendre là où il s'est arrêté.

| Exigence | Cible |
| --- | --- |
| Durée du traitement complet | Moins de 10 heures, mesurée sur 3 morceaux en phase 0 puis extrapolée |
| Reprise sur erreur | Chaque étape écrit son résultat ; une relance saute les étapes déjà faites. Un morceau en échec n'arrête pas le lot |
| Retraitement ciblé | Relancer un morceau ou une étape seule (exemple : refaire l'accompagnement après changement de la colonne retirer) |
| Traçabilité | Un journal par morceau, et un rapport global en CSV et HTML |
| Espace disque | Environ 25 Go en FLAC pour 120 morceaux |
| Fonctionnement hors ligne | Tout sauf la requête LRCLIB et l'option Spotify ; les modèles sont téléchargés une fois |
| Précision du clic | Dérive inférieure à 30 ms par rapport à la batterie sur toute la durée d'un morceau à tempo stable |
| Précision des paroles | Ligne affichée entre 300 ms avant et 100 ms après le début du chant |

## Architecture et stack technique

Le pipeline est une application Python en ligne de commande, entièrement locale, qui enchaîne sept étapes autour d'un fichier audio unique.

[embedded content: pipeline · 7 étapes, de l'entrée au set Ableton]

La piste voix issue de la séparation alimente l'alignement des paroles ; la grille de temps fixe la durée du décompte, que la vidéo reprend.

| Brique | Outil retenu | Rôle |
| --- | --- | --- |
| Langage et environnement | Python 3.11, gestionnaire uv | Environnement reproductible |
| Interface | Typer | Commandes manifeste, traiter, rapport |
| Audio | ffmpeg, soundfile | Conversion, découpe, mixage, encodage FLAC |
| Séparation | Demucs, modèle htdemucs_6s, accélération Apple (MPS) | 6 pistes séparées |
| Temps et mesures | Beat This! | Temps, premiers temps, tempo |
| Paroles | API LRCLIB ; textes fournis par Michel, alignés avec WhisperX | Paroles synchronisées ligne par ligne |
| Vidéo | ffmpeg avec sous-titres ASS générés depuis le LRC | Rendu rapide, mise en forme contrôlée |
| Sets Ableton | Python (gzip et lxml) sur un set gabarit | Génération des fichiers .als |
| Métadonnées (option) | API Web Spotify, lecture seule | Pré-remplissage du manifeste |

## Intégration Ableton

Le pipeline génère un set Ableton (.als) par partie de soirée, prêt à ouvrir : morceaux enchaînés, un repère par titre, routage conforme au plan d'adressage de la console XR18.

La génération part d'un set gabarit que Michel enregistre dans sa version d'Ableton, avec les pistes, le routage USB et la fenêtre vidéo déjà réglés. Le pipeline y place les fichiers de chaque morceau à la suite et pose les repères, sans toucher au reste. Le format .als n'étant pas documenté officiellement, cette approche limite le risque d'incompatibilité.

| Piste du set | Fichier | Canaux USB vers la XR18 | Rôle à la console |
| --- | --- | --- | --- |
| Accompagnement | accompagnement.flac | 2 (stéréo) | Façade |
| Clic | clic.flac | 1 (mono) | Départs retours des musiciens uniquement, jamais en façade |
| Guide voix | guide_voix.flac | 1 (mono) | Retours des musiciens, coupé par défaut |
| Pistes de secours | pistes/*.flac | Aucun par défaut | Désactivées dans le set, à router au cas par cas |
| Paroles | paroles.mp4 | Aucun | Fenêtre vidéo en plein écran sur le projecteur |

Ableton n'occupe ainsi que 4 canaux de la XR18, ce qui en laisse 14 pour les micros des chanteurs et les instruments live. Les numéros de canaux exacts viennent du plan d'adressage.

Organisation recommandée : un set par partie de soirée (10 à 15 morceaux), les morceaux s'enchaînant dans l'Arrangement avec un repère par titre. Un set unique de 120 morceaux avec vidéo serait lourd à charger et risqué en cas de plantage.

À valider en phase 0 : l'ouverture d'un set généré dans Ableton, la sortie sur les bons canaux de la XR18, l'affichage plein écran de la fenêtre vidéo sur le projecteur, et la tenue de la synchronisation vidéo sur un set de 15 morceaux.

## Plan de développement et rétroplanning indicatif (non contraignant)

Deux phases de développement, séparées par une décision go / no-go, livrent le pipeline et les 120 dossiers le 19 octobre.

[embedded content: rétroplanning · 12 au 30 octobre 2026]

L'acquisition audio conditionne tout : 3 fichiers de test sont nécessaires le 13 octobre, et l'ensemble avant le 17 octobre pour lancer le calcul.

1. **Phase 0, faisabilité (13 et 14 octobre).** Chaîne complète sur 3 morceaux choisis pour couvrir les cas difficiles : un titre au tempo stable, un enregistrement ancien ou live au tempo fluctuant, un titre français absent de LRCLIB. Entrées attendues de Michel le 13 octobre : les 3 fichiers audio, le set gabarit enregistré dans sa version d'Ableton et le plan d'adressage XR18. Critères de go :
   - séparation exploitable à l'écoute, sans doublon gênant avec le jeu live ;
   - clic sans dérive au-delà de 30 ms sur le titre à tempo stable ;
   - au moins 90 % des lignes de paroles bien calées ;
   - un set .als généré à partir du gabarit s'ouvre dans Ableton et sort sur les bons canaux de la XR18 ;
   - vidéo en plein écran sur le projecteur validée dans Ableton ;
   - temps de calcul extrapolé à 120 morceaux inférieur à deux nuits.
2. **Phase 1, industrialisation (15 au 17 octobre).** Commande manifeste avec option Spotify, traitement par lot avec reprise sur erreur, rendu vidéo final, rapport global en HTML, génération des sets .als par partie de soirée et mode d'emploi d'une page.
3. **Calcul par lot (nuits du 17 et du 18 octobre).** Traitement par vagues au fil de l'arrivée des fichiers, puis génération des sets une fois la répartition par partie arrêtée.
4. **Livraison (19 octobre).** 120 dossiers, sets Ableton générés par partie de soirée, rapport global trié par risque.

Si un critère de go échoue, la parade correspondante de la section Risques s'applique et le périmètre est revu le 14 octobre au soir.

## Risques et parades

Le risque principal n'est pas technique : c'est le volume de vérification manuelle, estimé à 30 à 60 heures pour 120 morceaux.

| Risque | Effet | Parade |
| --- | --- | --- |
| Vérification trop longue (15 à 30 min par titre) | Morceaux non vérifiés le 30 octobre | Rapport trié par risque : vérifier d'abord les titres signalés, survoler les autres. Prévoir une liste réduite de titres sûrs |
| Paroles absentes de LRCLIB, surtout en français | Plus d'alignement automatique, calage moins fiable | Texte fourni par Michel, aligné avec WhisperX ; contrôle de calage automatique et signalement dans le rapport |
| Tempo instable (enregistrements anciens ou live) | Clic difficile à suivre pour les musiciens | Clic calqué sur les temps détectés et non sur un BPM fixe ; titres signalés, à jouer sans clic si besoin |
| Séparation imparfaite (guitare et piano qui débordent dans les autres pistes) | Doublons audibles avec le jeu live | Accepter le résidu ou retirer aussi la piste autres ; écouter les titres signalés |
| Fichier d'entrée différent de la version Spotify | Paroles décalées | Contrôle de durée à l'entrée, détection du silence initial |
| Fichiers d'entrée livrés en retard | Lot de calcul décalé | Traiter par vagues au fil de l'arrivée des fichiers |
| Calcul plus lent que prévu | Lot non terminé en une nuit | Mesure en phase 0, découpage sur deux nuits si besoin |
| Format .als non documenté, propre à chaque version d'Ableton | Set généré illisible ou incomplet | Partir d'un gabarit enregistré dans la version utilisée, ne modifier que clips et repères, test d'ouverture en phase 0 ; repli : import manuel dans le gabarit |
| Budget de canaux de la XR18 dépassé | Pas assez d'entrées pour les micros et instruments live | Limiter Ableton à 8 canaux USB (accompagnement stéréo, clic, guide voix) |
| Vidéo mal gérée par Ableton en plein écran | Paroles non projetables | Test en phase 0 ; repli : lecteur vidéo séparé lancé sur le premier temps du décompte |
