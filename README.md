# PDFsPDFsPDFs

Native macOS-App (SwiftUI + PDFKit) — dein eigenes, komplett kostenloses PDF-Programm: unterschreiben, zusammenfügen, trennen, Seiten verwalten, Bilder ↔ PDF konvertieren. Alles läuft lokal auf deinem Mac — keine Uploads, kein Konto, keine Online-Tools mehr.

**Free & Open Source** · MIT-Lizenz · Auto-Updates via [Sparkle](https://sparkle-project.org)

## Features

### Werkzeugleiste (links)

Adobe-artige Icon-Leiste; jedes Werkzeug öffnet ein eigenes Panel:

- ✍️ **Signieren** — Personenverwaltung mit gespeicherten Unterschriften & Initialen
- 📄 **Seiten** — große Seitenvorschau; Rechtsklick: drehen, verschieben, exportieren, löschen
- ➕ **Zusammenfügen** — mehrere PDFs sortieren und mergen
- ✂️ **Trennen** — Seitenbereich („1-3, 5“) extrahieren oder alle Seiten einzeln speichern
- 🔤 **Text & Datum** — Text-Werkzeug im Acrobat-Stil: aktivieren, in die Seite klicken, direkt lostippen
- 🔄 **Konvertieren** — Bilder → PDF und PDF → Bilder, komplett offline

### Text schreiben

Text-Werkzeug einschalten, an die gewünschte Stelle klicken und tippen — der Text erscheint sofort dort, wo er später steht. Die Schriftgröße lässt sich **während des Tippens** oben in der Leiste ändern, Enter übernimmt, Esc bricht ab. Ein **Doppelklick** auf einen eingefügten Text öffnet ihn wieder zum Bearbeiten. Das heutige Datum gibt es als Ein-Klick-Button.

### Konvertieren

- **Bilder → PDF**: JPEG, PNG, HEIC/HEIF, TIFF, GIF, BMP, WebP, AVIF und **SVG** (echter Vektor mit durchsuchbarem Text). Mehrere Bilder werden per Drag & Drop sortiert und zu einem PDF zusammengefügt.
- **Mehrseitige TIFFs (Scanner, Fax) und animierte GIFs** werden zu je einer PDF-Seite pro Bild — kein stiller Datenverlust wie bei naiven Konvertern, die nur das erste Bild übernehmen.
- Seitengröße wählbar (**Auf A4/Letter einpassen**, Originalgröße nach DPI oder Pixel); **verlustfrei** (JPEG wird byte-genau durchgereicht) oder **kleinere Datei** mit JPEG-Qualitätsregler. EXIF-Drehung von Handyfotos wird korrekt berücksichtigt.
- **PDF → Bilder**: jede Seite als PNG, JPEG, TIFF, HEIC oder AVIF in 150/300/600 dpi.
- Alles rein nativ (CoreGraphics/ImageIO/PDFKit), **lokal, ohne Upload**.

### Unterschreiben

- Beliebig viele Personen; pro Person **Unterschrift** und **Initialen**, dauerhaft gespeichert (`~/Library/Application Support/PDFsPDFsPDFs/`).
- Erfassung per *Zeichnen* (Maus/Trackpad) oder *Bildimport* (optional mit automatischer Weiß-Entfernung).
- Platzieren per Klick; danach Auswahl-Widget direkt an der Unterschrift: **Ecken ziehen = Größe**, **blauer Griff unten = frei drehen** (Shift rastet in 15°-Schritten; alternativ die Drehen-Buttons in der Leiste), **rotes × = löschen**, Ziehen = verschieben.
- **Rückgängig/Wiederholen** (Cmd+Z / Cmd+Shift+Z) für alles.
- Formularfelder (AcroForms) füllt PDFKit direkt aus.

### Speichern & Komfort

- PDF öffnen per Finder-Doppelklick („Öffnen mit“), Dock-Drop, Drag & Drop, „Zuletzt geöffnet“.
- **Cmd+S** überschreibt das Original — Unterschriften werden **fest eingebrannt** (geflattet). **Cmd+Shift+S** = Speichern unter. Reine Seiten-Operationen werden verlustfrei gespeichert (Text/Links/Formulare bleiben erhalten).
- Drucken (Cmd+P), Zoom (Cmd +/−/0), Deutsch + Englisch.

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
swift build && .build/debug/EasyPDF --selftest
```

Verifiziert headless auf Pixelebene: Stempel-Flattening, Merge, Seitenbereichs-Parser, Extraktion, Einzelseiten-Split, Seitenlöschung + verlustfreies Schreiben, 90°-Rotation, Text-/Stroke-Rendering sowie die Konvertierung (A4-MediaBox statt Letter, EXIF-Orientierung, mehrseitiges TIFF → mehrere Seiten, Ablehnung von PDF-Eingaben, PDF→Bild-Export).

## Projektstruktur

- `Sources/EasyPDF/EasyPDFApp.swift` – App-Einstieg, Menüs, Sparkle-Updater, Finder-Open-Handler
- `Sources/EasyPDF/ContentView.swift` – Layout mit Werkzeug-Rail, Toolbar, Startbildschirm
- `Sources/EasyPDF/ToolRail.swift` – Icon-Leiste + Panel-Container
- `Sources/EasyPDF/ToolPanels.swift` – Panels: Zusammenfügen, Trennen, Text & Datum
- `Sources/EasyPDF/Convert/` – Konverter: `ConvertTypes` (Optionen/Fehler/Warnungen), `ImageToPDF`, `PDFToImage`, `ConvertPanel` (UI)
- `Sources/EasyPDF/Sidebar.swift` – Personen-Panel + Personen-Editor
- `Sources/EasyPDF/ThumbnailSidebar.swift` – Seiten-Panel
- `Sources/EasyPDF/SignatureCapture.swift` – Zeichenfläche + Bildimport
- `Sources/EasyPDF/DocumentModel.swift` – Dokumentzustand, Stempel, Undo, Flattening, Seiten-Ops
- `Sources/EasyPDF/PDFTools.swift` – Merge, Split, Extract, Range-Parser
- `Sources/EasyPDF/PDFViewRepresentable.swift` – interaktive PDF-Ansicht (Auswahl-Widget)
- `Sources/EasyPDF/ImageUtils.swift` – Stroke-/Text-Rendering, Weiß-Entfernung
- `Sources/EasyPDF/Resources/{de,en}.lproj/` – Übersetzungen
- `assets/` – Logo + AppIcon, `scripts/` – Release-Tooling
