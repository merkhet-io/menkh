# Reviewed pocket-milling demonstration

The previous `general-demo.sh` launched a diagnostic fixture: eight whole-operation jumps, target colors enabled, no visible cutter, and an end-camera move that cropped the stock. Only still images had been inspected for that milestone. That was insufficient presentation validation.

The script now generates one coherent three-depth pocket job with 325 real cutting states, 100 µm spacing, and an analytically rendered flat cylindrical cutter plus separate shank/holder. Each increment invokes the actual fixed-orientation sweep; geometry is not interpolated between meshes. Target colors and normal averaging are off by default. The diagnostic fixture, including intentional collisions, remains available as `examples/general.json`.

```sh
./scripts/general-demo.sh
# Encode a new video; destination must not exist:
./scripts/general-demo.sh --movie out/pocket-demo/new-video.mp4
```

[Delivered video](general-demo.mp4): H.264, 1280 × 900, 12 fps, 374 frames, 31.166667 seconds. This is geometric playback, not physical feed timing. The ideal cutter has no modeled flute details or spinning decoration. Occupancy stays visibly rasterized; lighting does not alter geometry.

The encoded video was fully decoded with the existing FFmpeg installation. Decoded frames were visually inspected across the passes and retract, including a final full-resolution frame. That review found and corrected a cropped final holder. The final report has 2,667,022 occupied voxels, zero shank/holder occupied-center contact, and successful forward/backward/forward history validation. Both Debug and ReleaseFast still pass 35 tests.

The older benchmark records describe the preceding engine checkpoint, not a new performance claim for this presentation change. The viewer remains simple: 12 fps recorded cutting states, flat lighting, no shadows, and no claim of cinematic rendering.
