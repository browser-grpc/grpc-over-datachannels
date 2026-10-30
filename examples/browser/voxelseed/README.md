# VoxelSeed — procgen terrain dashboard

An infinite voxel-world generator that runs entirely in your
browser, with a settings dashboard and an autopilot that flies
through the worlds it makes. Tune the generator and the world
re-shapes around you, chunk by chunk, forever.

Play it: <https://voxelseed.lunchgamer.com/>

## The instrument

- **Seed** — every world is a pure function of its seed
  (plus the knobs below). Type one, or roll the dice.
- **Generator** — three terrain programs:
  - *Easy*: gentle plains (heights 3–5, rare trees).
  - *Complex*: multi-octave ridged mountains (1–12), exposed
    stone on steep faces, sand lowlands, 3D-noise caves.
  - *Biomes*: complex + a low-frequency biome map (desert with
    cacti, plains, dense forest, snow caps) and lakes below
    sea level.
- **Sliders** — terrain height, sea level, tree density,
  biome size, and a caves toggle. Structural changes
  regenerate the world in place.
- **Flight** — autopilot on/off (or `P`), fly speed, altitude
  clearance, and view distance in chunks. *Free-fly* hands you
  the camera: WASD + Space/C to move, mouse (pointer lock) or
  arrow keys to look, Shift for speed.
- **Telemetry** — FPS, loaded chunk count, camera position,
  biome under the camera, ground height.

## How it works

Terrain is a pure function of world coordinates (seeded value
noise, trilinear 3D noise for caves), so the world is
infinite: 16×16 chunks stream in around the camera
(nearest-first, built within a per-frame time budget) and
drop behind it. Each chunk is one `InstancedMesh` with
per-instance colors for solid blocks plus one for translucent
water — a few hundred draw calls at any view distance, no
assets, no server.

## Rendering engines

Two engines sit behind one interface (`addChunk`,
`removeChunk`, `setView`, `render`); Telemetry names the one
in use:

- **`engine-webgpu.js`** — our own hand-rolled WebGPU engine:
  WGSL pipelines (opaque + translucent water), instanced cube
  rendering from per-chunk GPU buffers, zero dependencies.
  This is the default where WebGPU exists.
- **`engine-three.js`** — the three.js WebGL build, loaded
  only as a fallback (no WebGPU, adapter failure, or a
  runtime GPU error — the swap re-uploads every chunk).
  Force it with `?engine=three`.

`game.js` is the world engine (noise, chunker, autopilot,
dashboard). `index.html` carries the panel and the AdSense
loader, injected after page load on the public lunchgamer host
only, so ad latency can never stall the page.

## Deploy (Cloudflare Pages, lunchgamer)

The page is five static files (the fallback's three.js comes from a CDN):

```
wrangler pages deploy <dir with index.html, style.css, game.js> \
  --project-name lunchgamer-minecraft
```

Custom domain `voxelseed.lunchgamer.com` (CNAME to
`lunchgamer-minecraft.pages.dev`) is attached to that project;
the old `minecraft.lunchgamer.com` subdomain 301-redirects to
it (zone-level proxied AAAA `100::` + Single Redirect rule).

## History

VoxelSeed began as a multiplayer grpc-dc demo (browser-hosted
gRPC game server, base64 invite links). The generator outgrew
the game, so the page became the dashboard above; the
multiplayer version lives in git history (`bce2c45`).
