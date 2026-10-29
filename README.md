# menkh — voxelbasierter Materialabtrag auf Apple Silicon

Aktueller, gesicherter Funktionsumfang und bekannte Grenzen: [Stand-Dokumentation](docs/STATUS.md).

Ausführbarer erster Stand: Simulationskern und CLI in **Zig 0.15.2**, skalare Referenz, blockweise optimierter CPU-Abtrag, PPM-Höhenbild, gerastertes OBJ-Mesh, JSON-Berichte und separater nativer macOS-Viewer. Keine externen Pakete im Kern. Die 25-µm-Konfiguration wurde tatsächlich ausgeführt und voxelgenau gegen die Referenz geprüft.

![Tatsächlich gerenderter 25-µm-Bestand](docs/preview-25um.png)

## Neue hochauflösende Demo: exakt 4096³

[**Neue Animation ansehen**](docs/drill-4096.mp4) · [Details, Messungen und Bedienung](docs/VOXEL-4096.md)

```sh
./scripts/drill-4096.sh
```

Echtes **4096 × 4096 × 4096**-Blockgitter im 60-mm-Würfel, **14,648 µm Voxelgröße**; anfangs 2,16 Milliarden belegte Voxel im mittig platzierten Zylinder. CPU-Abtrag mit umkehrbarer Schnitthistorie und direkter Metal-Voxeldarstellung. Blau-orange Ansicht entsprechend den drei neuesten Referenzvideos, Pause/Zeitschieber, Orbit, Pan und Oberflächenfokus per Doppelklick. Die optionale Normalenmittelung ändert ausschließlich die Beleuchtung.

Tatsächlich gemessen: **3,160 s mediane Generierungszeit** über drei Läufe nach Warm-up, rund **648 MB maximale Prozess-RSS**. **17/17 Tests** in Debug und ReleaseFast bestehen; der große Verlauf wurde vorwärts, bytegenau zurück zum Anfang und erneut vorwärts geprüft. Dieser neue Modus erzeugt keinen vollständigen Oberflächenmesh pro Schritt. Der bisherige Mesh-Viewer und die ursprünglichen Demos bleiben erhalten.

## Animierte Spiralbohrer-Demo

[**Video ansehen: Vom Zylinder zum Spiralbohrer**](docs/drill-demo.mp4) — 22,75 Sekunden, 960 × 960, H.264.

```sh
./scripts/drill-demo.sh
```

Das erzeugt die Demo und öffnet den interaktiven Player mit **Abspielen/Pause, Neustart, Zeitschieber, Drehen und Zoom**. Bereits erzeugte Daten lassen sich direkt öffnen:

```sh
zig-out/bin/menkh-viewer out/drill/animation.json
```

Ein Zylinder (Ø 12 × 60 mm, Raster 0,25 mm) erhält zwei helikale Spannuten und eine facettierte Spitze. **225 echte Voxelzustände** werden von Zig sequenziell berechnet und anschließend abgespielt. Der orange, halbtransparente Fräskopf bleibt als Positionsanzeige auch auf der Rückseite sichtbar. Das ist eine idealisierte Geometriedemo; Schneidenfreistellung, reale Maschinenkinematik und ein produktionsfähiger Bohrer sind damit nicht nachgewiesen. [Details und Reproduktion](docs/DRILL-DEMO.md).

## Schnellstart auf diesem Mac

```sh
./zig version
./zig build                         # Debug, CLI nach zig-out/bin/menkh
./zig build test                    # Debug-Tests
./zig build demo -- --voxel 0.25 --out out/demo

./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh demo --voxel 0.025 --out out/fine
./zig build bench -Doptimize=ReleaseFast -- --voxel 0.025 --out out/bench-fine --repeats 7
```

`./zig` ist ein kleiner Projekt-Wrapper um die lokale, unveränderte Zig-Distribution. Nach einem frischen Checkout zunächst `./scripts/bootstrap-zig.sh` ausführen. Das lädt die offizielle aarch64-macos-Distribution ausschließlich nach `.tools/` und prüft ihren fest hinterlegten SHA-256. Es verändert weder globale Pakete noch den Shell-Suchpfad dauerhaft.

Voraussetzung: vorhandene Apple Command Line Tools und ein kompatibles macOS-SDK. Auf dieser Maschine wird das bereits installierte `MacOSX15.4.sdk` verwendet. Das aktuelle SDK bietet seine Systembibliotheken nur als `arm64e-macos` an; Zig 0.15.2 kann damit seinen Build-Runner nicht linken. Der Wrapper lenkt **nur seine eigenen** `xcrun --sdk macosx --show-sdk-path`-Abfragen auf das ältere SDK um. Ein anderer vorhandener kompatibler SDK-Pfad kann mit `MENKH_SDK=/pfad/MacOSX.sdk ./zig build` gesetzt werden. Es werden keine Systemeinstellungen geändert. Zig-Version, SDK und Compiler-CPU-Modell sind in der [Messdokumentation](docs/BENCHMARKS.md) beschrieben.

## CLI

```sh
# Demo und Export führen dasselbe feste Beispielszenario aus.
./zig build demo -- --voxel 0.1 --out out/demo-100um
./zig build export -Doptimize=ReleaseFast -- --voxel 0.05 --out out/export-50um
zig-out/bin/menkh export --voxel 0.025 --out out/export-25um

# Ohne Mesh, oder explizit mit skalarer Referenz:
zig-out/bin/menkh demo --voxel 0.025 --out out/image-only --no-mesh
zig-out/bin/menkh demo --voxel 0.25 --out out/reference --reference

# Beide Implementierungen, 1 Warm-up + N Wiederholungen je Implementierung:
./zig build bench -Doptimize=ReleaseFast -- --voxel 0.025 --out out/bench --repeats 7
./scripts/benchmark-all.sh
```

Ausgaben im gewählten Verzeichnis:

- `height.ppm`: binäres P6-Bild, ein Pixel pro XY-Voxelspalte, +X nach rechts und +Y nach oben. Grauwert ist die höchste belegte Zelloberkante relativ zur Rasterhöhe; leer = 0. Im Beispiel: Rohteiloberseite 255, Nutboden 153. Ein Höhenbild zeigt keine verdeckten Hohlräume.
- `surface.obj`: sämtliche freiliegenden Voxelgrenzflächen als zusammengefasste Quads, mm, äußere Orientierung, keine Glättung. Entfällt mit `--no-mesh`.
- `report.json`: Konfiguration, Bestand, Rastervolumen, Block-/Poolstatistik, tatsächliche Pufferkapazitäten, Prozess-RSS und getrennte Phasenzeiten.
- `benchmark.json`: stattdessen bei `bench`; Referenzvergleich und je Implementierung Min/Median/Max aller Phasen. Bilder und Mesh entsprechen der letzten Wiederholung.

Bestehende gleichnamige Ausgaben werden überschrieben. Für verschiedene Konfigurationen eigene Verzeichnisse verwenden. `export` ist ein erneuter Simulationslauf mit Export. Für die 4096³-Demo gibt es separate wiederladbare Voxel- und Historiedateien; ein allgemeines Importkommando für die klassische CLI ist noch nicht vorhanden. Die CLI bietet bewusst das feste Beispielszenario; andere Quader und Folgen von XY-Schnitten sind über `Grid.init` und `Grid.cut` im Zig-Kern möglich.

## Viewer

```sh
# Völlig unabhängig vom CLI-Build; benötigt die vorhandene Apple-Swift-Toolchain:
./scripts/build-viewer.sh
# Alternativ:
./zig build viewer

zig-out/bin/menkh-viewer out/fine/surface.obj
# Ohne Dateipfad öffnet sich eine Dateiauswahl:
zig-out/bin/menkh-viewer
# Reproduzierbares Renderbild:
zig-out/bin/menkh-viewer out/fine/surface.obj --snapshot out/fine/view.png
```

Ziehen dreht die Kamera, Scrollen zoomt; **R** oder der Button setzt die Kamera zurück. Die orange Beispielbahn kann ausgeblendet werden. Sie ist zur Vermeidung von Z-Fighting um 0,08 mm über den Nutboden angehoben; die Abtragsberechnung benutzt unverändert Z = 6 mm. Kamera und Bahnmarkierung sind auf das Beispielszenario abgestimmt.

Der Viewer ist ein kleiner **Swift/AppKit/SceneKit**-Begleiter, kein Bestandteil des Zig-Kerns. Er lädt das OBJ in einen gemeinsamen Geometriepuffer mit expliziten ebenen Normalen, nicht einen Drawcall pro Voxel. Er braucht weder eine laufende CLI noch deren Build. Umgekehrt haben CLI-Build und Tests keine Swift-/Viewer-Abhängigkeit. Er verwendet nur vorhandene Apple-Systemframeworks. SceneKit ist allerdings [von Apple in den Wartungsmodus versetzt](https://developer.apple.com/videos/play/wwdc2025/288/); der schnell verfügbare Viewer ist deshalb ein Prototyp, keine langfristige Rendering-Plattformentscheidung.

Der reale 25-µm-Mesh wurde geladen und als PNG gerendert. Eine manuelle Maus-/Trackpad-Bedienprüfung und belastbare FPS-Messung sind noch offen. Der Viewer akzeptiert den kleinen OBJ-Teilumfang dieses Exporters (`v` und Quad-`f`), keinen allgemeinen OBJ-/CAD-Import.

## Geometrie und Genauigkeit

Rohteil: **40 × 30 × 10 mm**. Fräserradius 3 mm, Schneidenlänge 10 mm; Unterkante bewegt sich von (10,15,6) nach (30,15,6). Das überstrichene Volumen ist eine XY-Kapsel × geschlossenes axiales Intervall. Die Nut ist 4 mm tief, der 6-mm-Boden bleibt bestehen.

Der einzige Materialbestand ist das Block-Voxelgitter. Belegung und Abtrag werden an **Voxelmittelpunkten** ausgewertet. Geschlossener Werkzeugkontakt entfernt das Voxel; der Radius und beide Z-Grenzen werden um eine feste numerische Toleranz von **1e-10 mm** erweitert. Alle Prädikate verwenden `f64`, lokale Werkstückkoordinaten und deterministisch geordnete Streckenendpunkte. Z-Änderungen werden mit `UnsupportedMotion` abgelehnt. Es gibt keine diskreten Werkzeugstempel.

Volumen ist **belegte Voxel × h³**, eine Rasterapproximation. Auch die Rohteilaußengrenze wird am Mittelpunkt abgetastet: Rasterzellen können bei nicht ganzzahligen Abmessungen über die ideale Grenze hinausragen oder vorher enden. Im Beispiel passen alle vier Rasterweiten exakt zu den Rohteilmaßen. 25 µm Rasterweite sind **keine garantierte maximale Oberflächenabweichung**. Es findet keinerlei geometrische Glättung statt. Architektur, Koordinatenabfragen, Speichergrenzen und Fehlerverhalten: [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Prüfungen und Messungen

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
python3 scripts/validate-exports.py out/fine
```

Die unabhängige Exportprüfung benötigt nur die Python-Standardbibliothek und prüft das feste Beispiel: PPM-Pixelwerte, abgetragenes Volumen sowie das orientierte Volumen des OBJ. Sie ist keine Laufzeitabhängigkeit der CLI.

Tatsächliche Messwerte aller vier Rasterweiten, mit Warm-up und sieben Wiederholungen, stehen in [BENCHMARKS.md](docs/BENCHMARKS.md); unveränderte JSON-Messdaten liegen in [benchmarks/](benchmarks/). Explizites SIMD, mehrere Worker, GPU-Abtrag, Octree und PS3-Portierung sind nicht implementiert. Der gemessene erste Stand benötigt einen Worker.
