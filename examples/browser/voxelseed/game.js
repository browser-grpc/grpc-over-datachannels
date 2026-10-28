// VoxelSeed dashboard: a procgen terrain explorer. Infinite
// voxel worlds are generated chunk-by-chunk around the camera
// from a seed + generator parameters; an autopilot flies through
// them, and every dashboard control re-shapes the world live.
// No server, no multiplayer — this page is the whole instrument.
import { createWebGPUEngine } from "./engine-webgpu.js";

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// generator parameters (the dashboard edits these)
// ---------------------------------------------------------------------------
const MODE_EASY = 0, MODE_COMPLEX = 1, MODE_BIOMES = 2;
const MODE_NAMES = ["easy", "complex", "biomes"];
const P = {
  seed: 1337,
  mode: MODE_COMPLEX,
  amp: 1.0,        // terrain height scale
  sea: 3,          // lake level (biomes mode)
  treeMul: 1,      // tree density multiplier
  biomeScale: 22,  // biome noise cell size
  caves: true,
  speed: 14,       // autopilot m/s
  altitude: 9,     // autopilot clearance above terrain
  radius: 5,       // view distance in chunks
};

// ---------------------------------------------------------------------------
// noise + terrain (pure functions of world coordinates => infinite)
// ---------------------------------------------------------------------------
const MAXY = 15;
const AIR = 0, GRASS = 1, DIRT = 2, STONE = 3, WOOD = 4, LEAF = 5, PLANK = 6, SAND = 7, SNOW = 8, WATER = 9;
const BLOCK_COLORS = { [GRASS]: 0x58a83c, [DIRT]: 0x8a5a2b, [STONE]: 0x7d7d7d, [WOOD]: 0x6b4423, [LEAF]: 0x2f7a2e, [PLANK]: 0xb08d57, [SAND]: 0xe0d29a, [SNOW]: 0xf2f7f7, [WATER]: 0x2f6fd0 };

function hash2(x, z, s) {
  let h = (x * 374761393 + z * 668265263 + s * 974634211) | 0;
  h = Math.imul(h ^ (h >> 13), 1274126177);
  return ((h ^ (h >> 16)) >>> 0) / 4294967296;
}
function hash3(x, y, z, s) {
  let h = (x * 374761393 + y * 1103515245 + z * 668265263 + s * 974634211) | 0;
  h = Math.imul(h ^ (h >> 13), 1274126177);
  return ((h ^ (h >> 16)) >>> 0) / 4294967296;
}
function smoothNoise(x, z, cell, s) {
  const gx = x / cell, gz = z / cell;
  const x0 = Math.floor(gx), z0 = Math.floor(gz);
  const fx = gx - x0, fz = gz - z0;
  const sx = fx * fx * (3 - 2 * fx), sz = fz * fz * (3 - 2 * fz);
  const a = hash2(x0, z0, s), b = hash2(x0 + 1, z0, s), c = hash2(x0, z0 + 1, s), d = hash2(x0 + 1, z0 + 1, s);
  return a + (b - a) * sx + (c - a) * sz + (a - b - c + d) * sx * sz;
}
function noise3(x, y, z, cell, s) {
  const gx = x / cell, gy = y / cell, gz = z / cell;
  const x0 = Math.floor(gx), y0 = Math.floor(gy), z0 = Math.floor(gz);
  const fx = gx - x0, fy = gy - y0, fz = gz - z0;
  const sm = (t) => t * t * (3 - 2 * t);
  const sx = sm(fx), sy = sm(fy), sz = sm(fz);
  const L = (a, b, t) => a + (b - a) * t;
  return L(
    L(L(hash3(x0, y0, z0, s), hash3(x0 + 1, y0, z0, s), sx), L(hash3(x0, y0 + 1, z0, s), hash3(x0 + 1, y0 + 1, z0, s), sx), sy),
    L(L(hash3(x0, y0, z0 + 1, s), hash3(x0 + 1, y0, z0 + 1, s), sx), L(hash3(x0, y0 + 1, z0 + 1, s), hash3(x0 + 1, y0 + 1, z0 + 1, s), sx), sy),
    sz);
}
function heightAt(x, z) {
  if (P.mode === MODE_EASY) {
    const n = smoothNoise(x, z, 14, P.seed) * 0.65 + smoothNoise(x, z, 6, P.seed + 7) * 0.35;
    return 3 + Math.floor(n * 2.2 * P.amp); // 3..5 at amp 1
  }
  const base = smoothNoise(x, z, 17, P.seed) * 0.55 + smoothNoise(x, z, 8, P.seed + 7) * 0.25;
  const ridge = 1 - Math.abs(smoothNoise(x, z, 6, P.seed + 31) * 2 - 1);
  const n = Math.min(1, base + ridge * ridge * 0.3);
  return Math.min(12, 1 + Math.floor(n * (4 + 8 * P.amp)));
}
const biomeCache = new Map();
function biomeAt(x, z) {
  const k = x + "," + z;
  let b = biomeCache.get(k);
  if (b === undefined) {
    const n = smoothNoise(x, z, P.biomeScale, P.seed + 555);
    b = n < 0.32 ? "desert" : n < 0.56 ? "plains" : n < 0.79 ? "forest" : "snow";
    if (biomeCache.size > 20000) biomeCache.clear();
    biomeCache.set(k, b);
  }
  return b;
}
function treeProb(x, z) {
  if (P.mode === MODE_EASY) return 0.005;
  if (P.mode === MODE_BIOMES) {
    const b = biomeAt(x, z);
    return b === "forest" ? 0.07 : b === "plains" ? 0.02 : b === "snow" ? 0.01 : 0;
  }
  return 0.022;
}
function treeAt(x, z, H) {
  return hash2(x, z, P.seed + 99) < treeProb(x, z) * P.treeMul && H(x, z) + 4 <= MAXY;
}
// H is a height function so chunk builders can pass a cached one.
function terrainBlock(x, y, z, H) {
  if (y < 0) return AIR;
  if (y === 0) return STONE;
  const h = H(x, z);
  if (P.mode === MODE_BIOMES && y > h && y <= P.sea) return WATER;
  if (P.caves && P.mode !== MODE_EASY && y >= 2 && y <= h - 3 && noise3(x, y, z, 5, P.seed + 77) > 0.68) return AIR;
  if (y < h - 2) return STONE;
  if (y < h) return P.mode === MODE_BIOMES && biomeAt(x, z) === "desert" ? SAND : DIRT;
  if (y === h) {
    if (P.mode !== MODE_EASY) {
      if (P.mode === MODE_BIOMES) {
        const b = biomeAt(x, z);
        if (b === "desert") return SAND;
        if (b === "snow") return SNOW;
        if (h <= P.sea + 1) return SAND; // shorelines
      } else if (h <= 3) return SAND;
      const steep = Math.max(
        Math.abs(h - H(x + 1, z)), Math.abs(h - H(x - 1, z)),
        Math.abs(h - H(x, z + 1)), Math.abs(h - H(x, z - 1)));
      if (steep >= 2) return STONE;
    }
    return GRASS;
  }
  if (P.mode === MODE_BIOMES && biomeAt(x, z) === "desert") {
    return y === h + 1 && hash2(x, z, P.seed + 55) < 0.015 ? WOOD : AIR; // cactus stub
  }
  if (treeAt(x, z, H)) {
    if (y > h && y <= h + 3) return WOOD;
    if (y === h + 4) return LEAF;
  }
  if (y === h + 3) {
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]) {
      if (treeAt(x + dx, z + dz, H)) return LEAF;
    }
  }
  return AIR;
}
const blockAt = (x, y, z) => terrainBlock(x, y, z, heightAt);

// ---------------------------------------------------------------------------
// infinite chunk streaming: cells are computed here; an engine
// (engine-webgpu.js, or engine-three.js as fallback) owns the GPU
// ---------------------------------------------------------------------------
const CHUNK = 16;
let engine = null;
const chunks = new Map(); // "cx,cz" -> {solid, water} cell lists (kept for engine swaps)
const buildQueue = [];

function buildChunk(cx, cz) {
  // local height cache: terrain queries dominate chunk cost
  const hcache = new Map();
  const H = (x, z) => {
    const k = x + "," + z;
    let v = hcache.get(k);
    if (v === undefined) { v = heightAt(x, z); hcache.set(k, v); }
    return v;
  };
  const B = (x, y, z) => terrainBlock(x, y, z, H);
  const solid = [], water = [];
  for (let x = cx * CHUNK; x < cx * CHUNK + CHUNK; x++)
    for (let z = cz * CHUNK; z < cz * CHUNK + CHUNK; z++)
      for (let y = 0; y <= MAXY; y++) {
        const b = B(x, y, z);
        if (b === AIR) continue;
        const exposed = (nx, ny, nz) => {
          const nb = B(nx, ny, nz);
          return b === WATER ? nb === AIR : nb === AIR || nb === WATER;
        };
        if (!(exposed(x + 1, y, z) || exposed(x - 1, y, z) || exposed(x, y + 1, z) ||
              exposed(x, y - 1, z) || exposed(x, y, z + 1) || exposed(x, y, z - 1))) continue;
        (b === WATER ? water : solid).push([x, y, z, BLOCK_COLORS[b]]);
      }
  const key = cx + "," + cz;
  chunks.set(key, { solid, water });
  engine?.addChunk(key, solid, water);
}
function dropChunk(k) {
  if (!chunks.delete(k)) return;
  engine?.removeChunk(k);
}
function clearChunks() {
  for (const k of [...chunks.keys()]) dropChunk(k);
  buildQueue.length = 0;
}
// keep the ring of chunks around the camera; build nearest-first,
// inside a per-frame time budget so flight never hitches
function updateChunks() {
  const ccx = Math.floor(cam.pos.x / CHUNK);
  const ccz = Math.floor(cam.pos.z / CHUNK);
  const R = P.radius;
  for (const k of [...chunks.keys()]) {
    const [cx, cz] = k.split(",").map(Number);
    if (Math.max(Math.abs(cx - ccx), Math.abs(cz - ccz)) > R + 1) dropChunk(k);
  }
  const wanted = [];
  for (let dx = -R; dx <= R; dx++) for (let dz = -R; dz <= R; dz++) {
    const k = (ccx + dx) + "," + (ccz + dz);
    if (!chunks.has(k) && !buildQueue.includes(k)) wanted.push([Math.max(Math.abs(dx), Math.abs(dz)), k]);
  }
  wanted.sort((a, b) => a[0] - b[0]);
  for (const [, k] of wanted) buildQueue.push(k);
  // build by time budget (always at least one) so flight stays smooth
  const t0 = performance.now();
  let built = 0;
  while (buildQueue.length && (built === 0 || performance.now() - t0 < 7)) {
    const k = buildQueue.shift();
    if (chunks.has(k)) continue;
    const [cx, cz] = k.split(",").map(Number);
    if (Math.max(Math.abs(cx - ccx), Math.abs(cz - ccz)) > R + 1) continue;
    buildChunk(cx, cz);
    built++;
  }
}

// ---------------------------------------------------------------------------
// camera: autopilot wander + manual free-fly
// ---------------------------------------------------------------------------
const cam = {
  pos: { x: 8, y: 18, z: 24 },
  yaw: Math.PI, pitch: 0.12, // pitch = downward tilt
  autopilot: true, t: 0, heading: Math.PI,
};
const keys = new Set();

function groundAhead(dist) {
  const fx = -Math.sin(cam.heading), fz = -Math.cos(cam.heading);
  let g = 0;
  for (const d of [dist * 0.4, dist * 0.7, dist]) {
    g = Math.max(g, heightAt(Math.floor(cam.pos.x + fx * d), Math.floor(cam.pos.z + fz * d)));
  }
  return g;
}
function stepCamera(dt) {
  if (cam.autopilot) {
    cam.t += dt;
    // gentle sinusoidal wander: the world scrolls by forever
    cam.heading += Math.sin(cam.t * 0.13) * 0.22 * dt + Math.sin(cam.t * 0.041) * 0.1 * dt;
    cam.pos.x += -Math.sin(cam.heading) * P.speed * dt;
    cam.pos.z += -Math.cos(cam.heading) * P.speed * dt;
    const targetY = groundAhead(26) + P.altitude;
    cam.pos.y += (targetY - cam.pos.y) * Math.min(1, dt * 1.6);
    cam.yaw = cam.heading;
    // look a little below the horizon line of travel
    const lookY = groundAhead(30) + P.altitude * 0.35;
    cam.pitch = Math.atan2(cam.pos.y - lookY, 30);
  } else {
    const look = 2.2 * dt;
    if (keys.has("ArrowLeft")) cam.yaw += look;
    if (keys.has("ArrowRight")) cam.yaw -= look;
    if (keys.has("ArrowUp")) cam.pitch = Math.max(-1.5, cam.pitch - look);
    if (keys.has("ArrowDown")) cam.pitch = Math.min(1.5, cam.pitch + look);
    const cp = Math.cos(cam.pitch);
    const fwd = { x: -Math.sin(cam.yaw) * cp, y: -Math.sin(cam.pitch), z: -Math.cos(cam.yaw) * cp };
    const right = { x: Math.cos(cam.yaw), y: 0, z: -Math.sin(cam.yaw) };
    const move = { x: 0, y: 0, z: 0 };
    const add = (v, s) => { move.x += v.x * s; move.y += v.y * s; move.z += v.z * s; };
    if (keys.has("KeyW")) add(fwd, 1);
    if (keys.has("KeyS")) add(fwd, -1);
    if (keys.has("KeyD")) add(right, 1);
    if (keys.has("KeyA")) add(right, -1);
    if (keys.has("Space")) move.y += 1;
    if (keys.has("KeyC")) move.y -= 1;
    const len = Math.hypot(move.x, move.y, move.z);
    if (len > 0) {
      const sp = (keys.has("ShiftLeft") ? 26 : 11) * dt / len;
      cam.pos.x += move.x * sp; cam.pos.y += move.y * sp; cam.pos.z += move.z * sp;
    }
    if (cam.pos.y < 1.5) cam.pos.y = 1.5;
  }
}

// ---------------------------------------------------------------------------
// telemetry
// ---------------------------------------------------------------------------
let frames = 0, fpsShown = 0, lastFpsT = performance.now();
setInterval(() => {
  const now = performance.now();
  fpsShown = Math.round(frames * 1000 / (now - lastFpsT));
  frames = 0; lastFpsT = now;
  $("st-fps").textContent = fpsShown;
  $("st-chunks").textContent = chunks.size + (buildQueue.length ? ` (+${buildQueue.length} queued)` : "");
  $("st-pos").textContent = `${cam.pos.x.toFixed(0)}, ${cam.pos.y.toFixed(0)}, ${cam.pos.z.toFixed(0)}`;
  $("st-biome").textContent = P.mode === MODE_BIOMES
    ? biomeAt(Math.floor(cam.pos.x), Math.floor(cam.pos.z))
    : MODE_NAMES[P.mode];
  $("st-ground").textContent = heightAt(Math.floor(cam.pos.x), Math.floor(cam.pos.z)) + " m";
}, 400);

// ---------------------------------------------------------------------------
// dashboard wiring
// ---------------------------------------------------------------------------
function regen() {
  biomeCache.clear();
  clearChunks();
  cam.pos = { x: 8, y: heightAt(8, 8) + P.altitude + 4, z: 24 };
  cam.t = 0;
}
function bindRange(id, out, fmt, apply, structural) {
  const el = $(id);
  const show = () => { $(out).textContent = fmt(Number(el.value)); };
  el.addEventListener("input", () => { apply(Number(el.value)); show(); });
  el.addEventListener("change", () => { if (structural) regen(); });
  apply(Number(el.value)); show();
}
bindRange("amp", "amp-out", (v) => v.toFixed(2) + "×", (v) => (P.amp = v), true);
bindRange("sea", "sea-out", (v) => "y=" + v, (v) => (P.sea = v), true);
bindRange("trees", "trees-out", (v) => v.toFixed(2) + "×", (v) => (P.treeMul = v), true);
bindRange("biome", "biome-out", (v) => v + " m", (v) => (P.biomeScale = v), true);
bindRange("speed", "speed-out", (v) => v + " m/s", (v) => (P.speed = v), false);
bindRange("alt", "alt-out", (v) => "+" + v + " m", (v) => (P.altitude = v), false);
bindRange("radius", "radius-out", (v) => v + "", (v) => (P.radius = v), false);
$("caves").addEventListener("change", (e) => { P.caves = e.target.checked; regen(); });
$("gen-mode").addEventListener("change", (e) => { P.mode = Number(e.target.value); regen(); });
$("seed").addEventListener("change", (e) => { P.seed = Number(e.target.value) | 0; regen(); });
$("dice").addEventListener("click", () => {
  P.seed = (Math.random() * 1e9) | 0;
  $("seed").value = P.seed;
  regen();
});
$("regen").addEventListener("click", regen);
function setAutopilot(on) {
  cam.autopilot = on;
  if (on) { cam.heading = cam.yaw; document.exitPointerLock?.(); }
  $("fly-toggle").textContent = on ? "Pause autopilot" : "Resume autopilot";
  $("badge").textContent = on ? "AUTOPILOT" : "MANUAL";
  $("badge").classList.toggle("manual", !on);
  $("manual-hint").hidden = on;
}
$("fly-toggle").addEventListener("click", () => setAutopilot(!cam.autopilot));
$("manual").addEventListener("click", () => {
  setAutopilot(false);
  engine.canvas.requestPointerLock();
});
$("view").addEventListener("click", () => {
  if (!cam.autopilot && !document.pointerLockElement) engine.canvas.requestPointerLock();
});
document.addEventListener("mousemove", (e) => {
  if (!document.pointerLockElement || cam.autopilot) return;
  cam.yaw -= e.movementX * 0.0024;
  cam.pitch = Math.max(-1.5, Math.min(1.5, cam.pitch + e.movementY * 0.0024));
});
document.addEventListener("keydown", (e) => {
  keys.add(e.code);
  if (e.code.startsWith("Arrow")) e.preventDefault();
  if (e.code === "KeyP") setAutopilot(!cam.autopilot);
});
document.addEventListener("keyup", (e) => keys.delete(e.code));

// ---------------------------------------------------------------------------
// engine boot: our WebGPU engine first, three.js fallback
// ---------------------------------------------------------------------------
async function startThree() {
  const { createThreeEngine } = await import("./engine-three.js");
  return createThreeEngine($("view"));
}
function showEngineWarn(text) {
  $("engine-warn-text").textContent = text;
  $("engine-warn").hidden = false;
}
$("engine-warn-close").addEventListener("click", () => { $("engine-warn").hidden = true; });
async function boot() {
  const forceThree = new URLSearchParams(location.search).get("engine") === "three";
  if (!forceThree) {
    try {
      engine = await createWebGPUEngine($("view"), {
        onError: async (why) => {
          console.warn("WebGPU engine failed, switching to fallback:", why);
          engine?.destroy();
          engine = await startThree();
          for (const [k, c] of chunks) engine.addChunk(k, c.solid, c.water);
          $("st-engine").textContent = engine.name + " (after WebGPU error)";
          showEngineWarn(`WebGPU hit an error (${why}) — switched to the WebGL fallback engine. The world still works; rendering may be slower.`);
        },
      });
    } catch (e) {
      console.warn("WebGPU unavailable, using fallback:", e.message);
      engine = null;
      showEngineWarn(`WebGPU is not available in this browser (${e.message}) — running the WebGL fallback engine. Try a current Chrome/Edge for the hand-rolled WebGPU renderer.`);
    }
  }
  if (!engine) engine = await startThree();
  if (forceThree) showEngineWarn("WebGL engine forced with ?engine=three — remove the parameter to use the WebGPU engine.");
  $("st-engine").textContent = engine.name;
  regen();
  let last = performance.now();
  function frame(now) {
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    stepCamera(dt);
    updateChunks();
    engine.setView(cam.pos, cam.yaw, cam.pitch, P.radius);
    engine.render();
    frames++;
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}
boot();
