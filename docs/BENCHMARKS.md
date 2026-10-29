# Gemessene Benchmarks

Messung am 29./30. Oktober 2026 auf **MacBook Pro Mac17,6, Apple M5 Max, 18 CPU-Kerne (6 Super + 12 Performance), 128 GB RAM, macOS 27.0.1**. Native aarch64-macos-Binärdatei, Zig **0.15.2**, **ReleaseFast**, **ein Worker**. `-mcpu=native` wird von dieser Zig-Version auf dieser Hardware als `apple_m1` mit nativen Featureflags aufgelöst. Das ist die Compiler-Erkennung, keine Behauptung über die tatsächlich verbaute CPU. SDK für Zig: vorhandenes macOS 15.4; Swift-Viewer mit Apple Swift 6.3.2.

Alle Zahlen stammen aus tatsächlich ausgeführten Läufen. Rohdaten: [`../benchmarks/`](../benchmarks/), Hardware-/Buildangaben in [`environment.json`](../benchmarks/environment.json). Die Tabelle enthält die letzte vollständige Messserie des finalen Kernstands; vorläufige Zahlen aus der Entwicklungsphase können davon abweichen.

## Messverfahren

Festes Rohteil 40 × 30 × 10 mm; Fräserradius 3 mm, Schneidenlänge 10 mm, Strecke (10,15,6) → (30,15,6). Jede Wiederholung initialisiert einen neuen, identischen Rohteilbestand. Zuerst erfolgt ein zusätzlicher ungemessener **voxelgenauer Vergleich aller Blockbits** zwischen Referenz und Optimierung. Danach je Implementierung ein vollständiger Warm-up und sieben gemessene Wiederholungen. Referenz zuerst, Optimierung danach; identische Szenarien, Speicherstruktur, Poolvorbereitung, Oberfläche und Export. Keine Thread-Affinität, keine isolierte Maschine, keine garantierte Temperatur-/Taktkonstanz.

Monotone Nanosekunden-Zeitnahme mit `std.time.Timer`; die Phasen sind getrennt. Der Schnitt enthält auch Poolvorbereitung und Reservierung. Statistik, Oberflächenerzeugung und PPM/OBJ-Export liegen außerhalb der Schnittzeit. Export enthält PPM-Erzeugung und Textserialisierung sowie Dateischreiben, aber **kein fsync**; gemessen wird der warme macOS-Dateisystempfad, nicht die dauerhafte SSD-Persistierung. JSON-Serialisierung, analytische Validierung und Ressourcenabfrage liegen außerhalb dieser Phasentimer. Der Benchmark validiert den entfernten Voxelbestand jeder Wiederholung zusätzlich gegen eine vollständige XY-Spaltenzählung des Beispiels und vergleicht alle Wiederholungen mit dem Warm-up. Rückgabewerte werden geprüft und ausgegeben, nicht wegoptimiert.

## Materialabtrag

Alle Zeiten in ms; Streuung als Min–Max. Beide Implementierungen laufen skalar in einem Worker, ohne explizites `@Vector`. Die Referenz ist bereits auf Kandidatenblöcke begrenzt; dies ist kein Vergleich mit einem künstlich über das gesamte Rohteil laufenden Abtrag.

| Raster mm | Referenz Median (Min–Max) | Blockmasken Median (Min–Max) | gemessener Medianquotient |
|---:|---:|---:|---:|
| 0.25 | 0.263 (0.263–0.275) | 0.032 (0.031–0.035) | 8.23× |
| 0.1 | 2.823 (2.808–2.901) | 0.207 (0.204–0.233) | 13.62× |
| 0.05 | 20.439 (20.307–20.546) | 1.102 (1.097–1.155) | 18.54× |
| 0.025 | 154.280 (152.902–155.228) | 7.186 (7.090–7.371) | 21.47× |

Diese Quotienten gelten ausschließlich für dieses Szenario und diese Messreihe. Es wird kein allgemeiner Geschwindigkeitsvorteil für beliebige Bahnfolgen oder Hardware zugesichert.

## Getrennte Phasen der optimierten Variante

Mediane in ms; Min/Max jeder einzelnen Phase stehen vollständig in den JSON-Dateien.

| Raster mm | Initialisierung | Abtrag | Statistik | Oberfläche | PPM + OBJ Export |
|---:|---:|---:|---:|---:|---:|
| 0.25 | 0.002 | 0.032 | 0.003 | 0.538 | 0.989 |
| 0.1 | 0.012 | 0.207 | 0.051 | 7.491 | 5.628 |
| 0.05 | 0.067 | 1.102 | 0.393 | 15.233 | 20.041 |
| 0.025 | 0.477 | 7.186 | 3.107 | 79.688 | 80.127 |

Oberfläche und Export dominieren den 25-µm-Lauf. Das spricht für spätere inkrementelle Oberflächenpflege oder effizientere Mesh-Serialisierung, bevor SIMD oder CPU-Worker im Abtrag ergänzt werden. Die Baseline wurde vor solchen Erweiterungen gemessen; diese Erweiterungen sind hier nicht implementiert.

## Speicher

Die folgenden Gitter-/Meshzahlen werden aus den tatsächlich angelegten Pufferlängen und Kapazitäten des laufenden Programms erfasst. Sie sind **keine Prozess-RSS-Schätzung**. Allocator-Seitenrundung, Stack, Code, Laufzeit und Bildpuffer sind darin nicht enthalten. Einheiten: Byte, nicht MiB.

| Raster mm | logische Anfangsvoxel | Deskriptoren | Poolkapazität | Gitter gesamt | Meshkapazität | aktuell gemischte Blöcke |
|---:|---:|---:|---:|---:|---:|---:|
| 0.25 | 768,000 | 6,000 | 1,280 | 7,280 | 76,560 | 20 |
| 0.1 | 12,000,000 | 98,800 | 32,512 | 131,312 | 388,224 | 508 |
| 0.05 | 96,000,000 | 750,000 | 26,880 | 776,880 | 1,966,128 | 420 |
| 0.025 | 768,000,000 | 6,000,000 | 128,000 | 6,128,000 | 6,636,048 | 2,000 |

Separater 25-µm-Demoprozess mit PPM, OBJ und JSON: **19.349.504 Byte maximale RSS**, erfasst sowohl mit `getrusage` als auch `/usr/bin/time -l`; **18.776.448 Byte peak memory footprint** laut macOS. Reale Prozesszeit **0,17 s**, ein einzelner Lauf, kein Median. Siehe [`demo-0.025-time.txt`](../benchmarks/demo-0.025-time.txt) und [`demo-0.025.json`](../benchmarks/demo-0.025.json). RSS der Benchmarkberichte ist der bisherige Prozesshöchststand einschließlich vorheriger Validierung/Warm-ups, keine isolierte RAM-Messung einer Wiederholung.

Die 25-µm-Oberfläche besteht aus **112.024 Quads / 224.048 Dreiecken**. Der separate Viewer lud und baute dieses OBJ in einem tatsächlich ausgeführten Snapshot-Lauf in **0,874 s** auf. Dies ist eine einzelne Ladezeit inklusive Scene-Aufbau, **keine Renderzeit oder FPS-Messung**. Der PNG-Snapshot wurde erzeugt und visuell geprüft. Viewer-RAM und interaktive Bildraten wurden nicht vermessen.

## Volumengenauigkeit

Analytisch: `(2 r L + π r²) × Tiefe = (2 × 3 × 20 + π × 9) × 4 = 593,0973355292325 mm³`. Numerisch: entfernte Voxel × h³. Vorzeichenbehafteter Fehler = Rasterabtrag minus analytischer Abtrag.

| Raster mm | belegte Voxel danach | abgetragen mm³ | Fehler mm³ | relativer Fehler % |
|---:|---:|---:|---:|---:|
| 0.25 | 730,112 | 592.000000 | -1.097335529 | -0.185018 |
| 0.1 | 11,406,880 | 593.120000 | +0.022664471 | +0.003821 |
| 0.05 | 91,255,680 | 593.040000 | -0.057335529 | -0.009667 |
| 0.025 | 730,040,960 | 593.110000 | +0.012664471 | +0.002135 |

Die Fehler wechseln das Vorzeichen und konvergieren **nicht monoton**: 0,05 mm hat hier einen größeren Absolutfehler als 0,1 mm. Das wurde nicht korrigiert oder verschwiegen. Ein kleiner Volumenfehler ist keine Schranke für lokale Oberflächenfehler. 25 µm sind die Rasterweite, nicht eine zugesicherte geometrische Genauigkeit.

## Reproduktion und Prüfung

```sh
./zig build test --summary all
./zig build test -Doptimize=ReleaseFast --summary all
./scripts/benchmark-all.sh
python3 scripts/validate-exports.py out/bench-0.025
./zig build -Doptimize=ReleaseFast
/usr/bin/time -l zig-out/bin/menkh demo --voxel 0.025 --out out/demo-0.025
./scripts/build-viewer.sh
zig-out/bin/menkh-viewer out/demo-0.025/surface.obj --snapshot out/demo-0.025/view.png
```

Ausgeführt: **11/11 Testgruppen in Debug und ReleaseFast erfolgreich**, darunter 35 deterministische Zufallsszenarien mit jeweils acht Schnitten, Mittelpunktoracle ohne AABB, exakte Referenzgleichheit, Allocation-Failure-Injektion, Randblöcke, stationäre/umgekehrte/geteilte Bahnen, Idempotenz, monotone Materialabnahme und Oberfläche. PPM und orientiertes OBJ-Volumen wurden für **alle vier** Rasterweiten zusätzlich mit dem unabhängigen Python-Skript geprüft. Keine globalen Abhängigkeiten wurden installiert.
