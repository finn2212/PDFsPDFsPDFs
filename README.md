# PDFsPDFsPDFs

Native macOS-App (SwiftUI + PDFKit) — dein eigenes, komplett kostenloses PDF-Programm: unterschreiben, zusammenfügen, trennen, Seiten verwalten, Bilder ↔ PDF konvertieren. Alles läuft lokal auf deinem Mac — keine Uploads, kein Konto, keine Online-Tools mehr.

**Free & Open Source** · MIT-Lizenz · Auto-Updates via [Sparkle](https://sparkle-project.org)

## Features

### Start

Drei Wege hinein, ohne Suchen: **PDF öffnen**, **PDFs zusammenfügen**, **Bilder zu PDF** – oder Dateien einfach ins Fenster ziehen (ein PDF wird geöffnet, mehrere werden zusammengefügt, Bilder werden zu einem PDF).

### Zwei Ansichten

Oben in der Leiste wechselst du zwischen **Dokument** (unterschreiben und ausfüllen) und **Seiten** (alles, was ganze Seiten betrifft) – oder mit ⌘1 / ⌘2. **Speichern** überschreibt das Original, **Teilen** schickt eine unterschriebene Kopie per Mail, Nachrichten oder AirDrop und lässt das Original unangetastet.

### Dokument: unterschreiben und ausfüllen

- ✍️ **Unterschreiben** – gespeicherte Unterschriften und Initialen als große Kacheln; anklicken, die Unterschrift hängt halbtransparent am Mauszeiger, Klick setzt sie. **Initialen auf jeder Seite** mit einem Klick.
- Neue Unterschrift: **Zeichnen**, **Tippen** (in einer Schreibschrift) oder **Bild** (Weiß wird entfernt) – in einem einzigen Fenster, Name optional. Gespeichert nur lokal (`~/Library/Application Support/PDFsPDFsPDFs/`).
- 🔤 **Text** – Werkzeug an, irgendwo hinklicken, lostippen; Schriftgröße unten in der Leiste. Doppelklick öffnet einen Text wieder.
- 📅 **Datum** und ✓ **Ankreuzen** (✓ / ✗ / ●) für Formulare ohne Felder.
- Ausfüllbare Formulare (AcroForms) werden beim Öffnen erkannt und angekündigt – einfach in die Felder klicken.
- Ausgewähltes Element: Größe, Drehen und Löschen in der schwebenden Leiste unten; Ecken ziehen, blauer Griff dreht, rotes × löscht. Rückgängig/Wiederholen (⌘Z / ⇧⌘Z) für alles.
- Funktioniert auch auf gedrehten Seiten (quer gescannte Seiten): Unterschriften stehen aufrecht dort, wo man sie sieht.

### Seiten: sortieren, löschen, trennen, zusammenfügen

- Alle Seiten als Raster; Klick wählt, ⇧/⌘-Klick wählt mehrere, ⌫ löscht.
- **Ziehen zum Sortieren**, **PDFs oder Bilder ins Raster ziehen** fügt sie genau dort ein (Zusammenfügen).
- **Links/Rechts drehen**, **Löschen**, **Als PDF sichern** (Auswahl als neues PDF).
- **Trennen**: ✂ zwischen zwei Seiten klicken setzt einen Schnitt – „In 3 PDFs trennen“ schreibt die Teile; alternativ jede Seite als eigenes PDF.

### Konvertieren

- **Bilder → PDF**: JPEG, PNG, HEIC/HEIF, TIFF, GIF, BMP, WebP, AVIF und **SVG** (echter Vektor mit durchsuchbarem Text). Reihenfolge per Drag & Drop.
- **Mehrseitige TIFFs (Scanner, Fax) und animierte GIFs** werden zu je einer PDF-Seite pro Bild – kein stiller Datenverlust wie bei naiven Konvertern, die nur das erste Bild übernehmen.
- Seitengröße wählbar (**Auf A4/Letter einpassen**, Originalgröße nach DPI oder Pixel); **verlustfrei** (JPEG wird byte-genau durchgereicht) oder **kleinere Datei** mit JPEG-Qualitätsregler. EXIF-Drehung von Handyfotos wird korrekt berücksichtigt.
- **PDF → Bilder** (Ablage › Als Bilder exportieren): jede Seite als PNG, JPEG, TIFF, HEIC oder AVIF in 150/300/600 dpi.
- Alles rein nativ (CoreGraphics/ImageIO/PDFKit), **lokal, ohne Upload**.

### Speichern & Komfort

- PDF öffnen per Finder-Doppelklick („Öffnen mit“), Dock-Drop, Drag & Drop, „Zuletzt geöffnet“.
- **⌘S** überschreibt das Original – Unterschriften werden **fest eingebrannt** (geflattet). **⇧⌘S** = Speichern unter, **Kopie sichern…** lässt das Original unangetastet. Reine Seiten-Operationen werden verlustfrei gespeichert (Text/Links/Formulare bleiben erhalten).
- Werkzeuge per Tastatur: ⇧⌘U Unterschreiben, ⇧⌘T Text, ⇧⌘D Datum, ⇧⌘K Häkchen.
- Drucken (⌘P), Zoom (⌘ +/−/0), Deutsch + Englisch, hell und dunkel.

## Installation

Neueste Version: **[Releases](https://github.com/finn2212/PDFsPDFsPDFs/releases)** → **`PDFsPDFsPDFs.dmg`** laden, öffnen und die App im Fenster in den **Programme**-Ordner ziehen. (Alternativ gibt es weiterhin das Zip.)

> **Wichtig:** Die App muss in **/Programme** liegen, damit die Auto-Updates funktionieren — aus `~/Downloads` heraus gestartet, kann sich die App nicht selbst aktualisieren. Genau dafür ist das DMG da.

**Erster Start** (die App ist nicht Apple-notarisiert — sie ist kostenlos und Open Source; der Quellcode liegt hier im Repo):

- **macOS 15 (Sequoia) oder neuer**: App einmal öffnen (Meldung erscheint) → **Systemeinstellungen → Datenschutz & Sicherheit** → unten bei „PDFsPDFsPDFs“ auf **„Dennoch öffnen“** klicken.
- **macOS 13/14**: Rechtsklick auf die App → **Öffnen** → „Öffnen“ bestätigen.
- Alternative fürs Terminal: `xattr -d com.apple.quarantine /Applications/PDFsPDFsPDFs.app`

Danach aktualisiert sich die App selbst über das Menü **PDFsPDFsPDFs → Nach Updates suchen…** bzw. automatisch. Wichtig: Die App muss dafür in **/Programme** liegen (nicht aus ~/Downloads heraus starten).

## Selbst bauen

```bash
./build_app.sh              # baut dist/PDFsPDFsPDFs.app (inkl. Sparkle + App-Icon)
open dist/PDFsPDFsPDFs.app

./scripts/make_dmg.sh       # baut dist/PDFsPDFsPDFs.dmg (Drag-to-Programme-Installer)
```

Das DMG wird headless über [`dmgbuild`](https://pypi.org/project/dmgbuild/) erzeugt (`python3 -m pip install --user dmgbuild`) — kein Finder-Scripting nötig, läuft also auch in CI. Der Fensterhintergrund wird aus `scripts/make_dmg_background.swift` gerendert; Layout in `scripts/dmg_settings.py`.

## Release ausrollen (Maintainer)

```bash
./scripts/release.sh 1.1.0 --publish
```

Baut die App, zippt sie, signiert das Update mit dem Sparkle-EdDSA-Schlüssel (Keychain), erzeugt `appcast.xml`, baut das Installer-DMG und veröffentlicht alles als GitHub-Release. Alternativ vollautomatisch: Tag pushen (`git tag v1.1.0 && git push --tags`) — die GitHub-Action baut und veröffentlicht (benötigt einmalig das Repo-Secret `SPARKLE_ED_PRIVATE_KEY`, siehe [.github/workflows/release.yml](.github/workflows/release.yml)).

Die App findet Updates über `SUFeedURL` → `releases/latest/download/appcast.xml`, d. h. jedes neue Release ist automatisch der Update-Feed. Der Update-Kanal läuft bewusst weiter über das **Zip** — das DMG wird nach dem Appcast gebaut und ist nur der Erstinstall-Download für Menschen.

## Selbsttest

```bash
swift build
DYLD_FRAMEWORK_PATH=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 \
  "$(swift build --show-bin-path)/EasyPDF" --selftest
```

Verifiziert headless auf Pixelebene: Stempel-Flattening, Merge, Seitenbereichs-Parser, Extraktion, Einzelseiten-Split, Seitenlöschung + verlustfreies Schreiben, 90°-Rotation, Text-/Stroke-Rendering, die Konvertierung (A4-MediaBox statt Letter, EXIF-Orientierung, mehrseitiges TIFF → mehrere Seiten, Ablehnung von PDF-Eingaben, PDF→Bild-Export) sowie die Seiten-Ansicht: Verschieben/Löschen/Drehen/Einfügen mit Rückgängig und Wiederholen, Mehrfachauswahl, Trennen an Schnitten, Initialen auf gedrehten Seiten und der Teilen-Export ohne Platzier-Vorschau.

### Oberfläche als Bilder rendern (Debug-Builds)

```bash
swift build
DYLD_FRAMEWORK_PATH=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 \
  "$(swift build --show-bin-path)/EasyPDF" --snapshot /tmp/ui beispiel.pdf zweites.pdf
```

Klick-Test mit echten Maus- und Tastatur-Ereignissen (Text setzen, mit +/− und Eckgriff vergrößern/verkleinern, anklicken, per Doppelklick bearbeiten, Unterschrift mit Vorschau setzen, löschen, Rückgängig) – prüft nach jedem Schritt den Zustand und legt pro Schritt ein Bild ab:

```bash
DYLD_FRAMEWORK_PATH=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 \
  "$(swift build --show-bin-path)/EasyPDF" --uitest /tmp/uitest beispiel.pdf
```

Der Snapshot-Modus rendert Startbildschirm, Dokument- und Seiten-Ansicht, Unterschriften-Editor und Konverter in festen Zuständen (hell und dunkel) als PNG – die Fenster liegen außerhalb des Bildschirms, nichts blitzt auf. `SNAPSHOT_ONLY=<teil-des-namens>` rendert nur passende Zustände. UX-Analyse und Zielstruktur: [docs/ux/analysis.md](docs/ux/analysis.md).

## Projektstruktur

- `Sources/EasyPDF/EasyPDFApp.swift` – App-Einstieg, Menüs, Sparkle-Updater, Finder-Open-Handler
- `Sources/EasyPDF/ContentView.swift` – Fenster: Startbildschirm oder Dokument, Toolbar (Ansicht, Speichern, Teilen), alle Sheets und Dialoge
- `Sources/EasyPDF/StartView.swift` – Startbildschirm mit Drop-Zone und „Zuletzt geöffnet“
- `Sources/EasyPDF/DocumentWorkspace.swift` – Ansicht „Dokument“: Werkzeugleiste, Seitenleiste, Kontextleiste
- `Sources/EasyPDF/PagesView.swift` – Ansicht „Seiten“: Raster, Auswahl, Drag & Drop, Schnitte
- `Sources/EasyPDF/Signatures.swift` – Unterschriften-Auswahl (Popover) und -Editor (Zeichnen/Tippen/Bild)
- `Sources/EasyPDF/Components.swift` – gemeinsame Bausteine (Werkzeug-Buttons, Kontextleiste, Drop-Hervorhebung)
- `Sources/EasyPDF/DocumentModel.swift` – Dokumentzustand, Stempel, Undo, Flattening, Platzier-Vorschau
- `Sources/EasyPDF/DocumentModel+Pages.swift` – Seiten-Operationen auf Auswahlen (verschieben, löschen, drehen, einfügen, trennen)
- `Sources/EasyPDF/DocumentModel+Files.swift` – Öffnen, Zusammenfügen, Drops, Teilen, Datei-Dialoge
- `Sources/EasyPDF/Convert/` – Konverter: `ConvertTypes`, `ImageToPDF`, `PDFToImage`, `ConvertSheets` (UI)
- `Sources/EasyPDF/PDFTools.swift` – Merge, Split, Extract, Range-Parser
- `Sources/EasyPDF/PDFViewRepresentable.swift` – interaktive PDF-Ansicht (Auswahl-Widget, Inline-Text, Vorschau)
- `Sources/EasyPDF/ImageUtils.swift` – Stroke-/Text-/Schreibschrift-Rendering, Weiß-Entfernung
- `Sources/EasyPDF/SelfTest.swift`, `Snapshot*.swift`, `UITest.swift` – Selbsttest, UI-Renderer und Klick-Test (die beiden letzten nur in Debug-Builds)
- `Sources/EasyPDF/Resources/{de,en}.lproj/` – Übersetzungen
- `assets/` – Logo + AppIcon, `scripts/` – Release-Tooling, `docs/ux/` – UX-Analyse
