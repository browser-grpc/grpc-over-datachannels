// VoxelSeed dashboard: a procgen terrain explorer. Infinite
// voxel worlds are generated chunk-by-chunk around the camera
// from a seed + generator parameters; an autopilot flies through
// them, and every dashboard control re-shapes the world live.
// No server, no multiplayer — this page is the whole instrument.
import * as THREE from "three";

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
// scene + infinite chunk streaming (one InstancedMesh per chunk per
// material class; per-instance colors carry the block palette)
// ---------------------------------------------------------------------------
const CHUNK = 16;
let renderer, scene, camera;
const chunks = new Map(); // "cx,cz" -> {group, meshes:[...]}
const buildQueue = [];
let boxGeo, solidMat, waterMat;

function initThree() {
  renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize($("view").clientWidth, $("view").clientHeight);
  $("view").appendChild(renderer.domElement);
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x87ceeb);
  camera = new THREE.PerspectiveCamera(72, $("view").clientWidth / $("view").clientHeight, 0.1, 900);
  camera.position.set(8, 16, 8);
  scene.add(new THREE.AmbientLight(0xffffff, 0.8));
  const sun = new THREE.DirectionalLight(0xffffff, 1.5);
  sun.position.set(60, 90, 30);
  scene.add(sun);
  boxGeo = new THREE.BoxGeometry(1, 1, 1);
  solidMat = new THREE.MeshLambertMaterial({ color: 0xffffff });
  waterMat = new THREE.MeshLambertMaterial({ color: BLOCK_COLORS[WATER], transparent: true, opacity: 0.65, depthWrite: false });
  updateFog();
  addEventListener("resize", () => {
    camera.aspect = $("view").clientWidth / $("view").clientHeight;
    camera.updateProjectionMatrix();
    renderer.setSize($("view").clientWidth, $("view").clientHeight);
  });
}
function updateFog() {
  if (!scene) return;
  const far = P.radius * CHUNK;
  scene.fog = new THREE.Fog(0x87ceeb, far * 0.5, far * 0.98);
  camera.far = far * 1.6;
  camera.updateProjectionMatrix();
}

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
  const m = new THREE.Matrix4();
  const color = new THREE.Color();
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
        (b === WATER ? water : solid).push([x, y, z, b]);
      }
  const group = new THREE.Group();
  const meshes = [];
  const fill = (cells, mat, cap) => {
    if (!cells.length) return;
    const mesh = new THREE.InstancedMesh(boxGeo, mat, Math.min(cells.length, cap));
    cells.slice(0, cap).forEach(([x, y, z, b], i) => {
      mesh.setMatrixAt(i, m.makeTranslation(x + 0.5, y + 0.5, z + 0.5));
      if (mat === solidMat) mesh.setColorAt(i, color.setHex(BLOCK_COLORS[b]));
    });
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    group.add(mesh);
    meshes.push(mesh);
  };
  fill(solid, solidMat, 8192);
  fill(water, waterMat, 2048);
  scene.add(group);
  chunks.set(cx + "," + cz, { group, meshes });
}
function dropChunk(k) {
  const c = chunks.get(k);
  if (!c) return;
  for (const mesh of c.meshes) { scene.remove(mesh); mesh.dispose(); }
  scene.remove(c.group);
  chunks.delete(k);
}
function clearChunks() {
  for (const k of [...chunks.keys()]) dropChunk(k);
  buildQueue.length = 0;
}
// keep the ring of chunks around the camera; build nearest-first,
// a few per frame so flight never hitches on generation
function updateChunks() {
  const ccx = Math.floor(camera.position.x / CHUNK);
  const ccz = Math.floor(camera.position.z / CHUNK);
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
  pos: new THREE.Vector3(8, 18, 24),
  yaw: Math.PI, pitch: -0.12, // start looking north-ish, slightly down
  autopilot: true, t: 0, heading: Math.PI,
};
const keys = new Set();

function groundAhead(dist) {
  const fx = -Math.sin(cam.heading), fz = -Math.cos(cam.heading);
  let g = 0;
  for (const d of [dist * 0.4, dist * 0.7, dist]) {
    const x = Math.floor(cam.pos.x + fx * d), z = Math.floor(cam.pos.z + fz * d);
    g = Math.max(g, heightAt(x, z));
  }
  return g;
}
function stepCamera(dt) {
  if (cam.autopilot) {
    cam.t += dt;
    // gentle sinusoidal wander: the world scrolls by forever
    cam.heading += Math.sin(cam.t * 0.13) * 0.22 * dt + Math.sin(cam.t * 0.041) * 0.1 * dt;
    const fx = -Math.sin(cam.heading), fz = -Math.cos(cam.heading);
    cam.pos.x += fx * P.speed * dt;
    cam.pos.z += fz * P.speed * dt;
    const targetY = groundAhead(26) + P.altitude;
    cam.pos.y += (targetY - cam.pos.y) * Math.min(1, dt * 1.6);
    cam.yaw = cam.heading;
    // look a little below the horizon line of travel
    const lookY = groundAhead(30) + P.altitude * 0.35;
    cam.pitch = Math.atan2(cam.pos.y - lookY, 30);
  } else {
    // cam.pitch measures downward tilt (see rotateX(-pitch) below)
    const look = 2.2 * dt;
    if (keys.has("ArrowLeft")) cam.yaw += look;
    if (keys.has("ArrowRight")) cam.yaw -= look;
    if (keys.has("ArrowUp")) cam.pitch = Math.max(-1.5, cam.pitch - look);
    if (keys.has("ArrowDown")) cam.pitch = Math.min(1.5, cam.pitch + look);
    const fwd = new THREE.Vector3(0, 0, -1).applyEuler(new THREE.Euler(-cam.pitch, cam.yaw, 0, "YXZ"));
    const right = new THREE.Vector3(1, 0, 0).applyEuler(new THREE.Euler(0, cam.yaw, 0));
    const move = new THREE.Vector3();
    const sp = (keys.has("ShiftLeft") ? 26 : 11) * dt;
    if (keys.has("KeyW")) move.add(fwd);
    if (keys.has("KeyS")) move.sub(fwd);
    if (keys.has("KeyD")) move.add(right);
    if (keys.has("KeyA")) move.sub(right);
    if (keys.has("Space")) move.y += 1;
    if (keys.has("KeyC")) move.y -= 1;
    if (move.lengthSq() > 0) cam.pos.addScaledVector(move.normalize(), sp);
    if (cam.pos.y < 1.5) cam.pos.y = 1.5;
  }
  camera.position.copy(cam.pos);
  camera.rotation.set(0, 0, 0);
  camera.rotateY(cam.yaw);
  camera.rotateX(-cam.pitch);
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
  cam.pos.set(8, heightAt(8, 8) + P.altitude + 4, 24);
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
bindRange("radius", "radius-out", (v) => v + "", (v) => { P.radius = v; updateFog(); }, false);
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
  renderer.domElement.requestPointerLock();
});
$("view").addEventListener("click", () => {
  if (!cam.autopilot && !document.pointerLockElement) renderer.domElement.requestPointerLock();
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
// go
// ---------------------------------------------------------------------------
initThree();
regen();
const clock = new THREE.Clock();
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.05);
  stepCamera(dt);
  updateChunks();
  renderer.render(scene, camera);
  frames++;
});
