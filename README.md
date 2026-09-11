# Scanner de diapos — pour scanner SilverCrest sur Mac

<img src="docs/icone.png" width="128" align="right" alt="Icône">

Petite appli macOS pour numériser **diapositives et négatifs** avec un scanner de diapos **SilverCrest** (Lidl) quand le logiciel fourni ne fonctionne pas sur Mac.

Le scanner se présente en fait comme une **caméra USB standard (UVC)**, puce Sonix `0C45:6366`, en 2592×1680. Pas besoin de pilote : l'appli lit l'image directement et fait le reste.

*English: a small native macOS app for SilverCrest (Lidl) slide/negative scanners that show up as a UVC webcam (Sonix 0C45:6366). Live preview, colour-negative inversion with orange-mask removal, frame averaging, auto-scan on slide change or on a hand clap. UI in French.*

## Fonctions

- Aperçu en direct, numérisation avec **Espace / Entrée** ou le bouton de l'appli
- Types de film : **diapo couleur**, **négatif couleur** (inversion en densité et retrait du masque orange), **négatif N&B**, **diapo N&B**
- Niveaux automatiques, exposition, contraste, saturation
- Rotation, miroirs, rognage des bords (la bande noire du scanner à gauche est retirée d'office)
- **Anti-bruit** : moyenne de 1 à 16 images par scan
- **Scan automatique** au changement de diapo : on pousse le passe-vues, l'appli attend que l'image soit stable et numérise
- **Clap des mains** pour déclencher un scan (micro du Mac, sensibilité réglable)
- Enregistrement en **JPEG** ou **TIFF 16 bits**, numérotation automatique (`diapo_0001.jpg`…), dossier au choix

## Installation

### Version toute prête

1. Télécharger `ScannerDiapo.zip` dans les [Releases](../../releases), le décompresser et glisser **ScannerDiapo.app** dans **Applications**.
2. L'appli n'est pas signée par Apple : au premier lancement, **clic droit → Ouvrir**, puis **Ouvrir**.
   Si macOS dit que l'appli est « endommagée », lancer une fois dans le Terminal :
   ```
   xattr -dr com.apple.quarantine /Applications/ScannerDiapo.app
   ```
3. Autoriser l'accès à la **caméra** (et au **micro** si vous utilisez le clap).

macOS 13 ou plus récent, Mac Apple Silicon ou Intel.

### Depuis les sources

Il faut seulement les outils en ligne de commande d'Apple (`xcode-select --install`), pas Xcode.

```
git clone https://github.com/meutedechien/scanner-diapo-silvercrest.git
cd scanner-diapo-silvercrest
./build.sh              # compile et installe dans /Applications
./build.sh --no-install # ou laisse ScannerDiapo.app dans le dossier
```

## Mon scanner est-il compatible ?

Brancher le scanner, puis dans le Terminal :

```
system_profiler SPCameraDataType
```

Si une caméra `VendorID_3141 ProductID_25446` apparaît (soit `0C45:6366` en hexadécimal), c'est bon.
Pour un autre scanner qui se présente aussi comme une caméra USB, il suffit de changer `scannerVID` / `scannerPID` en haut de `main.swift` ; l'appli peut alors marcher, mais ce n'est pas testé.

## Limites connues

- **Le bouton physique du scanner ne marche pas sur Mac.** Il passe par un canal de la caméra que le pilote UVC de macOS garde pour lui. D'où le scan automatique et le clap.
- L'exposition est gérée par le scanner lui-même : macOS ne permet pas de la régler sur ce type de caméra. Le curseur d'exposition agit sur l'image.
- La résolution est celle du capteur (2592×1680, un peu moins une fois rognée).

## Pour les curieux

- `main.swift` : toute l'appli (SwiftUI + AVFoundation + Core Image)
- `icon.swift` : génère l'icône (`swift icon.swift && iconutil -c icns AppIcon.iconset`)
- `test/harness.swift` : applique le traitement de l'appli à une image brute, pratique pour régler les couleurs sans scanner :
  ```
  swiftc -O -parse-as-library -D TEST main.swift test/harness.swift -o test/harness
  test/harness brut.jpg sortie.jpg negatifCouleur   # ou positif, positifNB, negatifNB
  ```

## Licence

MIT, voir [LICENSE](LICENSE).
