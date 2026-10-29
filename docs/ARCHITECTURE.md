# Architektur und Verträge

## Datenfluss

`main.zig` → `core.Grid.init` → `Grid.cut` → Statistik → `surface.generate` → PPM/OBJ/JSON. Der Viewer liest ausschließlich exportierte Geometrie. Rendering verändert keinen Materialbestand.

- `src/core.zig`: Allocator-basiertes Blockgitter, Geometrieprädikate, Referenz und optimierter Abtrag.
- `src/surface.zig`: sichtbare Rastergrenzflächen, blockweises Greedy-Merging, Bild-/Mesh-Ausgabe.
- `src/main.zig`: CLI, festes Beispielszenario, Validierung und Benchmark-Zeitnahme.
- `src/tests.zig`: 17 Testgruppen einschließlich randomisierter Folgen und Allokationsfehler.
- `viewer/main.swift`: optionaler eigenständiger macOS-Viewer.

## Bestand und Speicher

Ein flaches Array von `u32`-Deskriptoren adressiert Blöcke in X-schnellster Reihenfolge: `(bz * nby + by) * nbx + bx`. `0xffffffff` bedeutet leer, `0xfffffffe` voll; andere Werte sind Indizes in einen zusammenhängenden `ArrayList([8]u64)`-Pool. Ein gemischter Block belegt 64 Byte. Wort `z` enthält die XY-Schicht; Bit `y * 8 + x` das lokale Voxel. Keine Pointer pro Voxel, keine Allokationen in den Voxelschleifen.

„Voll“ bedeutet: **alle gültigen Mittelpunktvoxel** des Blocks sind belegt. Nicht existierende Randvoxel werden weder gezählt noch exportiert. Randmasken werden bei Bedarf erzeugt, ohne dafür einen Poolslot zu belegen. Der Initialquader braucht nur das Deskriptorarray. Statistik verwendet bei gemischten Blöcken `popCount`, bei vollen Blöcken die tatsächliche Ausdehnung.

Vor jeder Operation zählt ein lesender Durchlauf exakt die vollen Blöcke, die gemischt werden. Danach wird die Poolkapazität reserviert, erst anschließend mutiert der zweite Durchlauf den Bestand. Schlägt die Reservierung fehl, bleibt die Belegung vollständig unverändert. Auch die Referenz benutzt diese Vorbereitung; sie versteckt somit keine günstigeren Allokationsbedingungen im Vergleich. Nach der Reservierung gibt es im gesamten schreibenden Schnittdurchlauf keine Allokation.

Ein einmal materialisierter Block wird durch reinen Abtrag nie wieder voll. Slots inzwischen leerer Blöcke bleiben bis `deinit` im Pool; sie werden nicht wiederverwendet. Damit ist der Pool monoton und maximal durch die Zahl der jemals gemischten Blöcke begrenzt. `pool_used_bytes` zählt diesen Hochwasserstand einschließlich solcher Slots; `mixed_blocks` nur die aktuell gemischten Blöcke. Kapazität wird exakt angefordert. Kein unbemerktes Abschneiden bei Platzmangel.

Alle Allocators werden explizit übergeben. Dimensionsprodukte und Kapazitätssummen sind geprüft; Allokatoren prüfen zusätzlich ihre Bytegrößen. Höchstens 2³¹−1 Voxel je Achse und weniger als `0xfffffffe` Blöcke/Poolslots werden akzeptiert. Größenfehler ergeben `GridTooLargeOrEmpty`, `PoolTooLarge` oder `Overflow`, Speichermangel `OutOfMemory`. Das ist ein begrenzter Quader-Simulator, kein unbeschränktes Weltgitter.

## Koordinaten und numerische Regeln

- Ursprung = untere linke Rohteilecke (0,0,0), Z nach oben, alles in mm.
- Mittelpunkt des globalen Voxelindex `(i,j,k)` = `((i+0.5)h,(j+0.5)h,(k+0.5)h)`.
- Ein Anfangsvoxel existiert genau dann, wenn sein Mittelpunkt im halboffenen idealen Quader `[0,Lx) × [0,Ly) × [0,Lz)` liegt. Die aus Division ermittelte Dimensionszahl wird gegen das tatsächliche Mittelpunktprädikat korrigiert.
- Indexabfragen `occupied` außerhalb des Rasterarrays ergeben `false`. Räumliche `query`-Abfragen verwenden `floor(p/h)` und die Grenzen des **repräsentierten Rasters** `[0,nx*h) × …`, nicht nachträglich die idealen Rohteilmaße. Damit stimmen Abfrage, Mesh und Volumen auch an nichtganzzahligen Rohteilgrenzen überein. Negative, nicht endliche und zu große Koordinaten ergeben `false`.
- Positive endliche Voxelgröße, positive endliche Rohteilmaße und Werkzeugabmessungen sind erforderlich. Ein Raster ohne Mittelpunktvoxel wird abgelehnt. Rohteilmaße, Werkzeugmaße und der Betrag der Bewegungskoordinaten sind auf 10⁶ mm begrenzt. Die Anwendung soll trotzdem kleine werkstücklokale Koordinaten verwenden.
- Die Werkzeugposition ist die Mitte der unteren flachen Stirnfläche. Radius und Schneidenlänge sind positiv. Beide Bewegungsenden müssen **exakt dasselbe Z** besitzen; Z wird nicht stillschweigend korrigiert. Stationäre Bewegungen sind zulässig.
- Endpunkte werden lexikographisch nach XY geordnet. Die umgekehrte Strecke durchläuft somit identische Gleitkommarechnungen.
- `t = clamp(dot(p-a,b-a)/|b-a|²,0,1)`; die Stationärvariante verwendet `t=0`. Entfernt wird, wenn `distance² <= (radius+1e-10)²` und `a.z-1e-10 <= p.z <= a.z+length+1e-10`. Die Toleranz ist absolut in mm, keine Prozentzahl und keine Rasterglättung. Es wird kein Fast-Math-Modus aktiviert.

## Referenz und Optimierung

Die skalare Referenz wertet für jedes gültige Voxel in den konservativ begrenzten Kandidatenblöcken das vollständige 3D-Prädikat aus. Sie benutzt dieselbe Belegungsrepräsentation und Transaktionsvorbereitung. Zusätzlich zu diesem Vergleich prüfen randomisierte Tests **alle** Rastervoxel ohne Bounding-Box gegen eine separate boolesche Sollbelegung. Dadurch werden auch gemeinsame Fehler der Kandidatenbegrenzung erkennbar.

Die optimierte Variante:

1. Begrenzt die Kapsel-AABB konservativ auf Blockbereiche; die darin enthaltenen gültigen Voxel sind durch die Blockausdehnungen begrenzt. Die AABB erhält bewusst eine zusätzliche Voxelpolsterung gegen Rundungsfehler.
2. Überspringt leere Blöcke; außerhalb der Kandidatenbereiche wird kein Material gelesen oder verändert.
3. Prüft die vier extremalen **Mittelpunkte** des XY-Rechtecks. Liegen sie mit zusätzlichem Abstand von 1e-8 mm innerhalb der konvexen Kapsel, sind alle XY-Mittelpunkte eingeschlossen. Ein einzelner Blockmittelpunkt wird niemals als Einschlussbeweis verwendet. Grenzfälle gehen durch die Einzelpunktprüfung.
4. Berechnet sonst höchstens 64 XY-Prädikate pro Block und verwendet die resultierende Maske für sämtliche axial betroffenen Z-Schichten. Randvoxel bleiben maskiert.
5. Entfernt Material wortweise mit `before & ~cutMask`. Ein vollständig verschwindender Block wird direkt leer, ohne ein Bitfeld zu materialisieren; unveränderte Blöcke werden nicht umgeschrieben.

Die Schnittzeit umfasst Vorprüfung und Poolreservierung. Die Optimierung verändert ausschließlich den Rechenweg, nicht das belegte Volumen. Explizites `@Vector` und Threading sind nicht enthalten. Nach der gemessenen Baseline ist derzeit die Oberfläche/Serialisierung deutlich teurer als der Schnitt; weitere CPU-Komplexität im Abtrag ist für diesen ersten Stand nicht nötig.

## Oberflächen und Darstellung

Vollständig volle Blöcke brauchen nur ihre äußeren sechs Blockseiten zu prüfen. Ein voller Nachbar verbirgt eine solche Seite vollständig. Gemischte Blöcke prüfen alle entsprechenden inneren und äußeren Voxelgrenzflächen gegen die tatsächliche Nachbarbelegung. Je Ebene werden gleichgerichtete sichtbare Flächen mit 8×8-Masken zu Rechtecken zusammengefasst. Merging erfolgt innerhalb eines Blocks, nicht global; es können T-Verzweigungen an koplanaren Rechteckkanten entstehen.

Das exportierte Mesh ist exakt die Grenze der repräsentierten Voxelvereinigung. Keine geglätteten Positionen, keine Höhenfeld-Ersatzrepräsentation des Materialbestands, keine versteckten Voxelwürfel. Auch verdeckte Hohlraumgrenzen sind in einem allgemeinen Schnittbestand enthalten; das PPM kann dagegen nur die jeweils höchste belegte Zelle zeigen. Der Viewer erzeugt explizite flache Normalen und zwei Dreiecke je Quad.

Die Oberfläche wird bei einem Export vollständig neu erzeugt; es gibt noch keinen inkrementellen Mesh-Cache oder Live-Simulationsstream. Für die einzelne Demooperation wird sie einmal erzeugt. Die GUI arbeitet auf einem unveränderlichen Mesh und benötigt beim Drehen/Zoomen keine erneute Simulation oder Oberflächenerzeugung.

## Verbleibende Grenzen

Kein Auffüllen des Bestands, keine schräge Werkzeugachse, keine Z-Bewegungen, keine Rund-/Kugelfräser, keine Bögen oder G-Code-Interpretation. Kein allgemeines Zustandsimportkommando für die klassische CLI, keine fertige macOS-App-Bundle-Verteilung. Die CLI ist auf das Beispielszenario zugeschnitten. Der Viewer verwendet derzeit ein von Apple nur noch gewartetes Framework; ein späterer Metal-/RealityKit-Viewer kann über denselben Export angebunden werden.

## Erweiterung: exaktes 4096³-Gitter

Der zusätzliche `drill --grid 4096`-Pfad (`src/fine.zig`) hält dasselbe Blockformat, exportiert aber den Voxelbestand und umkehrbare Blockänderungen statt Meshes pro Schritt. `viewer/VoxelView.swift` und `viewer/Voxel.metal` stellen diese Daten direkt mit Metal dar. Dieser Renderer verwendet kein SceneKit. CPU-Abtrag und GPU-Darstellung sind weiterhin getrennt. Details zu konservativer Blockklassifikation, Dateiformat, Referenzdarstellung, Tests und tatsächlich ausgeführten 4096³-Läufen: [VOXEL-4096.md](VOXEL-4096.md).
