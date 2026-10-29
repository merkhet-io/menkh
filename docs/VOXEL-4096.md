# Exakt 4096 × 4096 × 4096 Voxel

[**Neue Animation ansehen**](drill-4096.mp4) · [Vorschaubild](drill-4096.png)

Die hochauflösende Variante ist implementiert und tatsächlich ausgeführt. **Alle drei Rasterdimensionen betragen 4096**, nicht nur die Bohrerlänge. Das sind 68.719.476.736 adressierbare Rasterzellen in einem 60 × 60 × 60 mm großen Simulationsraum, mit **14,6484375 µm würfelförmiger Voxelgröße**. Der bisherige Zylinder Ø 12 × 60 mm steht bei XY = (30,30); der große Bereich um ihn herum ist leer. Anfangs sind **2.159.116.288 Voxel belegt**, nach den Schnitten **1.333.399.870**. Die Anzahl adressierbarer Zellen wird nicht als Anzahl belegter oder einzeln bearbeiteter Voxel ausgegeben.

## Starten und bedienen

```sh
./scripts/drill-4096.sh
```

Oder bereits vorhandene Daten direkt öffnen:

```sh
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting
```

- Ziehen: Kamera drehen; Scrollen: zoomen.
- **Doppelklick auf eine Oberfläche**: tatsächliches getroffenes Voxel als Kamerafokus setzen. Danach lässt sich bis auf einzelne Voxel hineinzoomen.
- Shift + Ziehen: Fokus verschieben.
- Zeitschieber: vorwärts und rückwärts durch die echte Schnitthistorie gehen.
- Pause/Abspielen, Neustart und Kamera zurücksetzen.
- „Normalen mitteln“: nur Beleuchtung umschalten. Konturen, Treffpunkte, Voxelbelegung und Volumen bleiben unverändert. Das Startskript aktiviert diese Darstellung; die Mittelung ist im Viewer ausdrücklich gekennzeichnet und abschaltbar.
- Optional dunkler Hintergrund.

Die Animation bleibt eine vorberechnete geometrische Demo. Die Wiedergabezeit ist keine Maschinen-Vorschubzeit. Kugelkopf, Helix-Polygonzüge und vereinfachte Spitzen-Facettierung entsprechen der [vorherigen Demo](DRILL-DEMO.md); die deutlich feinere Voxelauflösung macht daraus keine freigegebene Produktionsgeometrie.

## Bezug zu den gewünschten Videos

Als Darstellungsreferenz wurden **nur die drei neuesten Videos** auf [jstimpfles Profil](https://handmade.network/m/jstimpfle) herangezogen, jeweils anhand mehrerer Zeitpunkte:

1. [9. Oktober: Schnitthistorie](https://assets.media.handmade.network/52b4a944-b54a-484b-af96-2bfb08483204/JCut_Recording_2026-10-09_120752.mp4)
2. [9. Oktober: Detailstufen und Nahansicht](https://assets.media.handmade.network/c57e31b2-ac6d-4c26-aec7-73e409c82000/JCut_Recording_2026-10-09_114621.mp4)
3. [11. September: Oberfläche und Zoom](https://assets.media.handmade.network/cc886f5f-d0f6-4ca2-a1d1-c4b31757c928/Screen_Recording_2026-09-11_191224.mp4)

Übernommen wurden die visuelle Richtung (blaues Material auf orangefarbenem Hintergrund), Nahinspektion durch Drehen/Zoom und das Durchfahren des Schnittverlaufs. Die Geometrie und Implementierung stammen aus diesem Projekt. Es wird weder eine exakte Nachbildung noch die Übernahme der dort genannten Leistungswerte behauptet.

## Umsetzung

**Materialabtrag: Zig, CPU, ein Worker.** Das dichte Array kompakter 8³-Blockdeskriptoren bleibt erhalten, ebenso der zusammenhängende Bitfeldpool. Kein Octree, kein GPU-Abtrag. Die konstante-Z-Schaftfräser-API bleibt unverändert.

`src/fine.zig` ergänzt eine auf die Bohrerdemo zugeschnittene Blockklassifikation:

- Zylinderinitialisierung beschränkt sich auf die möglichen Materialblöcke im Würfel; außen bleiben die Deskriptoren leer.
- Ein-/Ausschlussprüfungen für den Zylinder verwenden minimale/maximale radiale Distanzen der Mittelpunktbox.
- Für die 3D-Kapsel beweisen alle acht Eckmittelpunkte mit Sicherheitsabstand vollständigen Einschluss; eine um den Blockradius vergrößerte Kapsel erlaubt konservativen Ausschluss.
- Für Spitzenebenen werden die extremalen Skalarprodukte des Blocks benutzt.
- Nur bei partieller Überdeckung werden die einzelnen belegten Voxelmittelpunkte ausgewertet. Alle geometrischen CPU-Prädikate benutzen `f64`.
- Pool- und Änderungsbufferkapazitäten werden vor dem schreibenden Durchlauf vorbereitet. Es gibt keine Allokationen in der inneren Voxelschleife.

**Darstellung: direkter Metal-Voxelrenderer** in `viewer/VoxelView.swift` und `viewer/Voxel.metal`. Er liest Blockdeskriptoren und Bitfelder. Strahlen überspringen leere Blöcke und gehen in gemischten Blöcken durch die Voxel. Es wird kein riesiges Mesh erzeugt und kein gröberes Ersatzgitter angezeigt. Vier Strahlen pro Ausgabepixel dienen der Kantenglättung. Optional wird ausschließlich die Beleuchtungsnormale aus einer 5³-Voxelumgebung gemittelt; die Oberflächenposition wird weiterhin durch den ersten belegten Voxel bestimmt. Shader- und Kamerarechnung verwenden `f32`, die Simulation `f64`. Das ist keine zertifizierte geometrische Fehlergrenze.

Der neue Renderer ist von SceneKit unabhängig und benutzt die vorhandenen macOS-Systemframeworks Metal/MetalKit. Der bisherige OBJ-/MQ-Viewer bleibt für die älteren Demos verfügbar. Keine globalen Abhängigkeiten wurden installiert. GPU-Daten werden während eines laufenden GPU-Zugriffs nicht geändert: CPU-Updates warten auf den vorherigen Command Buffer.

**Historie statt vollständiger Oberflächenkopien:** `initial.blocks` enthält das reale vollständige Deskriptorarray; `initial.pool` die anfänglichen Bitfelder. Jede `.delta`-Datei enthält pro geändertem Block seine ID, alten/neuen Deskriptor und nötigenfalls alte/neue 64-Byte-Bitfelder. Dadurch ist der Verlauf direkt umkehrbar. `voxel-animation.json` enthält Maße, belegte Voxel, Schritte, Dateigrößen, Speicher- und Zeitmessungen. Die spezifischen Zustandsdateien sind wiederladbar; es gibt weiterhin kein allgemeines CAD-/G-Code-Importformat.

## Tatsächlich gemessene Werte

M5 Max, 128 GB RAM, macOS 27.0.1; Zig 0.15.2, ReleaseFast, nativer CPU-Target, **ein Worker**. Ein vollständiger Warm-up, danach drei Wiederholungen in frischen CLI-Prozessen mit jeweils gleichem Initialbestand. Die Dateien wurden warm ins macOS-Dateisystem geschrieben, ohne `fsync`. Keine CPU-Affinität oder thermische Isolation. Die Summen der Phasenmediane müssen nicht dem Median der Gesamtlaufzeit entsprechen.

| Phase | Median | Min–Max |
|---|---:|---:|
| Zylindrischen Bestand aufbauen | 180,05 ms | 176,04–182,32 ms |
| Initiale Bestandsstatistik | 86,71 ms | 73,76–90,13 ms |
| Anfangsbestand exportieren | 80,49 ms | 70,59–80,95 ms |
| Alle 224 Schnittoperationen, einschließlich Vorbereitung | 2.705,94 ms | 2.677,67–2.942,38 ms |
| Alle Änderungsdateien exportieren | 49,84 ms | 48,78–51,65 ms |
| Gesamte Generierung einschließlich Abschlussprüfung | **3,160 s** | **3,155–3,405 s** |

Gemessene maximale RSS der drei CLI-Prozesse: **647.512.064–647.528.448 Byte**. Tatsächliche Blockdeskriptor-Allokation: **536.870.912 Byte (512 MiB)**. Bitfeldpool-Kapazität am Ende: **51.714.560 Byte**. Die gespeicherten Änderungen aller Schritte benötigen zusammen **126.358.276 Byte**. Eine theoretische voll materialisierte 4096³-Bitmap wurde nicht angelegt; diese Zahlen sind keine Schätzung ihres Speicherbedarfs.

Statische Metal-Nah-/Gesamtansicht bei **1280 × 900 Ausgabepixeln**, finalem 4096³-Bestand, vier Samples pro Pixel und gemittelten Beleuchtungsnormalen: nach drei Warm-ups zehn Messungen, GPU-Command-Dauer **1,872 ms Median**, **1,719–1,960 ms**. Das ist eine reine GPU-Zeit der statischen Ausgangskamera, **keine zugesagte interaktive FPS-Zahl**. Delta-Upload, CPU-Steuerung, Videoencoding und Display-VSync sind darin nicht enthalten; starkes Zoomen und volle Bildabdeckung können den Aufwand verändern.

Rohdaten: [CPU-Zusammenfassung](../benchmarks/4096/summary.json), [vollständige Simulation](../benchmarks/4096/simulation.json), [GPU-Messung](../benchmarks/4096/render.json), [Replay-Prüfung](../benchmarks/4096/replay.json), sowie die drei einzelnen Läufe im selben Ordner.

## Validierung

- **17/17 Testgruppen** in Debug und ReleaseFast erfolgreich.
- Neue Blockklassifikation gegen vollständige Mittelpunkt-Oracles geprüft; vorhandene Tests der ursprünglichen Schnitte bleiben erfolgreich.
- Neue Allokationsfehlerprüfungen bestätigen unveränderte Belegung bei Reservierungsfehlern.
- Kleine Testgitter: Vorwärts-/Rückwärts-/Vorwärtsänderungen ergeben dieselben Blockbits.
- **Am echten 4096³-Datensatz**: vorwärts bis zum Ende, zurück zum Anfang, erneut zum Ende. Anfangsdeskriptoren und sämtliche ursprünglichen Poolbits sind nach Rücklauf bytegenau identisch; beide Endläufe liefern 1.333.399.870 belegte Voxel.
- MP4 tatsächlich gerendert, vollständig mit dem bereits vorhandenen FFmpeg decodiert und ein Nahbild aus dem fertigen Video visuell geprüft.

## Reproduktion

```sh
./zig build drill -Doptimize=ReleaseFast -- --grid 4096 --out out/drill-4096
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting

./scripts/benchmark-4096.sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all

zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --verify-history out/drill-4096/replay.json
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --frame 224 --smooth-lighting --render-bench out/drill-4096/render.json
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --frame 224 --smooth-lighting --snapshot out/drill-4096/preview.png
# Videoziel muss noch nicht existieren:
zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting --movie out/drill-4096/new-video.mp4
```

`--grid` und `--voxel` sind gegenseitig ausgeschlossen. Das Gittermaß muss ein Vielfaches von acht zwischen 32 und 4096 sein; niedrigere Werte sind nur explizite Testoptionen. Der gezeigte Lauf verwendet tatsächlich 4096 auf jeder Achse. Der neue Videoexport hat **1280 × 900 Bildpixel**, 12 fps und 25,75 s Dauer: Bildauflösung und räumliche Gitterauflösung sind verschiedene Größen.
