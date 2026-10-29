# Vom Zylinder zum Spiralbohrer

Die neue Demo zeigt zeitlich fortschreitenden **echten Voxelabtrag**, nicht eine Überblendung zwischen zwei fertigen Modellen. Der Zig-Prozess hält genau einen Materialbestand und führt die Schnitte nacheinander aus. Für jeden Animationsschritt wird dessen unverfälschte Rasteroberfläche exportiert. Der separate Player lädt diese Zustände bedarfsgerecht; Pause und Zurückspulen wiederholen keinen Materialabtrag.

## Anschauen

- [Fertige MP4-Animation](drill-demo.mp4): 273 Videoframes bei 12 fps, 22,75 s, 960 × 960, H.264. 1 s Anfangsansicht, 225 Materialzustände, 3 s Schlussansicht.
- Interaktiv: `./scripts/drill-demo.sh` erzeugt die Daten und startet den Viewer. Pause/Abspielen, Neu starten, Zeitschieber, Kamera zurücksetzen; Maus dreht und Scrollen zoomt.
- Vorhandene Animation direkt öffnen: `zig-out/bin/menkh-viewer out/drill/animation.json`.

## Geometrie

Zylindrischer Rohling Ø 12 × 60 mm, Achse Z, Mittelpunkt XY = (6,6), Raster 0,25 mm. Die Initialisierung entfernt alle Voxelmittelpunkte außerhalb des Radius 6 aus dem begrenzten Blockgitter. Die Darstellung bleibt sichtbar gerastert.

Zwei um 180° versetzte Bahnen mit Helixradius 5,4 mm und Steigung 32 mm/Umdrehung werden von Z = 16 bis Z = 62 abgefahren. Jede Helix besteht aus 96 geraden **räumlichen** Segmenten. Ein idealisierter kugelförmiger Fräskopf mit Radius 3,3 mm entfernt je Segment die komplette überstrichene 3D-Kapsel. Es gibt keine isolierten Kugelstempel mit Lücken zwischen den Werkzeugpositionen. Die Helix selbst ist eine Polygonzugapproximation; die Sehnenabweichung beträgt bei diesen Parametern ungefähr 0,006 mm, zusätzlich zur Voxelapproximation.

Danach erzeugen 32 nacheinander angewendete geneigte Halbebenen die facettierte Spitze. Für Winkel α entfernt ein Pass die Mittelpunkte mit

```text
(x−6) cos(α) + (y−6) sin(α) > 60−z + 1e−10
```

Das ergibt eine vereinfachte Spitze mit ungefähr 90° eingeschlossenem Winkel. Es sind **keine** fertigen Span-/Freiwinkel, keine Querschneidenkorrektur und keine funktionsgeprüfte Bohrergeometrie modelliert. Die Spitzenoperation ist eine idealisierte ebene Formbearbeitung; die eingeblendete orange Platte ist ihre Positions-/Orientierungsanzeige, keine validierte endliche Werkzeug-/Haltergeometrie. Auch bei den Kugelbahnen werden Halterkollisionen nicht simuliert.

Die Kugel und die Platte werden transparent ohne Tiefenverdeckung gezeichnet, damit die aktuelle Werkzeugposition auch bei rückseitigem Abtrag erkennbar bleibt. Diese Anzeige verändert das Material nicht.

Die zuvor implementierte `Grid.cut`-API für senkrechte Schaftfräser und konstantes Z bleibt unverändert und lehnt Z-Bewegungen weiterhin ab. Die neuen, ausdrücklich anderen Demooperationen liegen separat in `src/drill.zig`; es wird keine räumliche Bewegung heimlich auf die alte XY-Kapsel reduziert.

## Daten und Ablauf

`animation.json` beschreibt Rasterweite, Werkzeugradius, Abspielrate und jeden Schritt mit Werkzeugposition, belegten Voxeln, Phase und Dateiname. Die `frame-NNNN.mq`-Dateien enthalten nur zusammengefasste sichtbare Quads: 12 Byte pro Quad, fünf little-endian u16 (x, y, z, Breite, Höhe), ein Achsenbyte, ein Vorzeichenbyte. Diese Meshes sind abgeleitete Renderdaten; der einzig maßgebliche Simulationsbestand bleibt das Block-Voxelgitter. Der Viewer hält nur einen kleinen benachbarten Framecache, nicht sämtliche Meshes im GPU-Speicher.

Poolkapazität wird vor jeder Operation als konservative Obergrenze vorbereitet. Allokationsfehler verändern keine Belegung; während der Voxelprüfung wird nicht alloziert. Kapsel-AABBs begrenzen die zu bearbeitenden Blöcke. Die Oberflächen werden pro Animationszustand vollständig erzeugt. Die Demo ist vorab berechnet, keine Live-Kopplung des Renderthreads mit dem Simulationskern.

Der CLI-Parameter `--voxel` erlaubt für diese bewusst begrenzte Demo 0,1 bis 0,5 mm. Das erste Video verwendet 0,25 mm und ist keine 25-µm-Demo. Die vier ursprünglichen Quaderbenchmarks und ihr 25-µm-Modus bleiben verfügbar.

## Reproduktion

```sh
./zig build drill -Doptimize=ReleaseFast -- --voxel 0.25 --out out/drill
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/drill/animation.json

# Einzelnen Animationszustand rendern:
zig-out/bin/menkh-viewer out/drill/animation.json --frame 224 --snapshot out/drill/final.png

# Video exportieren; der Zielname muss neu sein:
zig-out/bin/menkh-viewer out/drill/animation.json --movie out/drill/new-demo.mp4

./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
```

Der MP4-Export benutzt die vorhandenen Apple-Systemframeworks AVFoundation und SceneKit. Keine neue globale Abhängigkeit wurde installiert. Das bereits vorhandene FFmpeg wurde nur zur unabhängigen Prüfung des fertigen Videos eingesetzt.

## Ausgeführt und geprüft

- 225 Materialzustände tatsächlich erzeugt; erste gemessene Generierung einschließlich aller Meshdateien und finalem OBJ: 1,95 s auf dem M5 Max, ReleaseFast, ein Worker. Einzelmessung, kein Benchmarkmedian.
- Endbestand: 267.344 Voxel; 2.587,75 mm³ abgetragen. Der Bestand nimmt zwischen den Zuständen niemals zu.
- 14/14 Testgruppen erfolgreich in Debug und ReleaseFast, einschließlich der bisherigen Kernprüfungen. Neu: räumliche Kapsel gegen vollständige Mittelpunktprüfung, Idempotenz, Umkehrung, ungültige Werkzeuge, Allocation-Failure-Injektion sowie Erhalt von Schaft/Kern und Abtrag an Nuten/Spitze.
- Endgeometrie und ein Zwischenbild aus der tatsächlich encodierten MP4 visuell geprüft. Die komplette MP4 wurde unabhängig fehlerfrei decodiert; Format, Auflösung, Bildzahl und Dauer wurden ausgelesen.
