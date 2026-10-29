# Gesicherter Projektstand

Dieser erste Projektstand umfasst den Zig-Simulationskern, reproduzierbare Messdaten und zwei animierte Bohrerdemos einschließlich einer tatsächlich ausgeführten 4096³-Konfiguration. Quellcode, Build-/Startskripte, Dokumentation, kleine Demo-Videos und Messberichte werden gemeinsam versioniert. Die bisherigen lokalen Dateien bleiben erhalten.

## Enthalten

| Einstieg | Funktionsumfang |
|---|---|
| `./zig build demo` / `export` | Quader, senkrechter Schaftfräser, kontinuierlich überstrichene XY-Kapsel bei konstantem Z; skalare Referenz und blockweise Optimierung; PPM, OBJ und JSON |
| `./zig build bench -Doptimize=ReleaseFast` | Referenzvergleich, Warm-up, Wiederholungen und getrennte Phasenmessungen |
| `./scripts/drill-demo.sh` | Zylindrischer Rohling, zwei helikale Nuten und vereinfachte Spitzen-Facettierung; 225 gerasterte Meshzustände mit animiertem Werkzeug |
| `./scripts/drill-4096.sh` | Exakt 4096 × 4096 × 4096 Rasterzellen im 60-mm-Würfel; 14,6484375 µm große Voxel; CPU-Abtrag, umkehrbare Blockänderungen und direkte Metal-Darstellung |
| Viewer | Pause, Neustart, Historienregler, Drehen, Zoom; im Metal-Modus zusätzlich Pan und Oberflächenfokus per Doppelklick |

Materialbestand: kompakte Deskriptoren für 8³-Blöcke und ein zusammenhängender Pool aus 512-Bit-Belegungsfeldern. CPU-Geometrieprädikate verwenden `f64`; der Renderer benutzt `f32`. Der Metal-Shader liest den Bestand, er berechnet keinen Materialabtrag. Weder ein Octree noch explizite SIMD- oder Mehrworker-Optimierungen sind enthalten.

## Wiederherstellen und starten

Zielplattform ist ausschließlich macOS auf Apple Silicon. Verwendet wurden Zig **0.15.2**, Apple Command Line Tools, das bereits installierte macOS-15.4-SDK für Zig und Apple Swift für die Viewer. Der projektspezifische SDK-Wrapper ist in der [README](../README.md) erklärt.

```sh
./scripts/bootstrap-zig.sh        # Toolchain nur lokal nach .tools/, mit SHA-256-Prüfung
./zig build
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./zig build -Doptimize=ReleaseFast
./scripts/drill-4096.sh
```

Die Toolchain, Compiler-Caches, Binärdateien und großen regenerierbaren Simulationsdaten in `.tools/`, `.zig-cache/`, `zig-out/` und `out/` sind bewusst nicht Bestandteil der Git-Historie. Die Skripte erzeugen sie erneut. Es wurden keine globalen Abhängigkeiten installiert. Bestehende macOS-SDKs/Systemframeworks sind Voraussetzungen, nicht mitgelieferte Pakete.

## Validierung und Belege

Vor dem Einchecken erneut ausgeführt:

- **17/17 Testgruppen in Debug und ReleaseFast erfolgreich**.
- ReleaseFast-CLI und nativer Viewer erfolgreich gebaut.
- Zig-Formatprüfung und Syntaxprüfung der Shellskripte erfolgreich.

Bereits während der Implementierung tatsächlich ausgeführt und dokumentiert:

- 25-µm-Quaderlauf und Benchmarks aller vier ursprünglichen Rasterweiten, voxelgenau gegen die Referenz geprüft.
- Unabhängige PPM-/OBJ-Prüfung einschließlich orientiertem Meshvolumen.
- Exakte 4096³-Demo: 2.159.116.288 anfänglich belegte Voxel und 1.333.399.870 nach den Schnitten.
- Am großen Datensatz vorwärts, zurück und erneut vorwärts abgespielt; Initialdeskriptoren und ursprüngliche Bitfelder nach Rücklauf bytegenau identisch.
- Beide Demo-Videos tatsächlich gerendert, vollständig decodiert und anhand von Zwischen-/Endbildern geprüft.

Messungen sind im [Benchmarkbericht](BENCHMARKS.md) und [4096³-Bericht](VOXEL-4096.md) beschrieben; Rohdaten liegen unter [`benchmarks/`](../benchmarks/). Der 4096³-Bericht trennt Gesamtgenerierung, CPU-Abtrag, Dateiexport und reine GPU-Renderzeit. Historische Messergebnisse werden nicht als bei jedem Checkout erneut erzielte Garantien ausgegeben.

## Bekannte Grenzen

- Mittelpunktbelegung und Volumen `Voxelanzahl × h³` sind Rasterapproximationen. Rasterweite ist keine garantierte maximale Oberflächenabweichung.
- Der Bohrer ist eine idealisierte Geometriedemo, keine produktionsgeprüfte Schneidengeometrie oder NC-Ausgabe. Halterkollisionen und Maschinenkinematik fehlen.
- Die Animation spielt vorberechnete Materialzustände bzw. Blockänderungen ab; sie ist noch keine laufende Kopplung von Simulation und Renderthread.
- Im Metal-Modus ist die optionale Normalenmittelung reine Beleuchtung. Sie verändert weder Belegung noch Konturen; sie ist im Viewer abschaltbar.
- Keine zugesicherte interaktive FPS-Zahl, kein allgemeiner CAD-/G-Code-Import und noch kein signiertes macOS-App-Bundle.
- Der ältere Mesh-Viewer verwendet SceneKit; der neue Voxelrenderer verwendet direkt Metal/MetalKit.

Die [Architekturdokumentation](ARCHITECTURE.md) beschreibt Koordinaten, Speicherverwaltung, konservative Geometrieprüfungen und Fehlerverhalten. Die PR-Beschreibung fasst diesen Stand für die Erstbegutachtung zusammen.
