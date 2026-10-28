// grpc-dc voxel demo: a Minecraft-style world where the session
// host's browser runs the generated Game service (grpc-dc Server)
// and guests run the generated GameClient — both over one
// RTCDataChannel ("grpc"). Signaling is manual: SDP+ICE payloads
// travel as base64url codes inside links, so no signaling server
// exists anywhere. STUN finds the NAT mapping; an optional TURN
// server (bring your own coturn) relays pairs STUN cannot punch.
import * as THREE from "three";
import { createPeer } from "../../../js/index.js";
import { GameClient, createGameService } from "./gen/game_grpc_dc.js";
import { JoinRequest, JoinResponse, ClientMsg, Pos, BlockEdit, ServerMsg, PlayerState } from "./gen/game_pb.js";

const $ = (id) => document.getElementById(id);
const logEl = $("log");
function log(msg) {
  logEl.textContent += msg + "\n";
  logEl.scrollTop = logEl.scrollHeight;
  $("status").textContent = msg;
}

// ---------------------------------------------------------------------------
// tiny async queue + two-source merge (host Play stream plumbing)
// ---------------------------------------------------------------------------
class Queue {
  constructor() { this.items = []; this.waiters = []; this.closed = false; }
  push(v) {
    if (this.closed) return;
    const w = this.waiters.shift();
    if (w) w({ value: v, done: false }); else this.items.push(v);
  }
  close() {
    this.closed = true;
    for (const w of this.waiters.splice(0)) w({ value: undefined, done: true });
  }
  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this.items.length) return Promise.resolve({ value: this.items.shift(), done: false });
        if (this.closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((r) => this.waiters.push(r));
      },
    };
  }
}

async function* merged(a, b) {
  const ia = a[Symbol.asyncIterator](), ib = b[Symbol.asyncIterator]();
  let pa = ia.next(), pb = ib.next();
  for (;;) {
    const r = await Promise.race([
      pa.then((v) => ({ src: "a", v })),
      pb.then((v) => ({ src: "b", v })),
    ]);
    if (r.v.done) return;
    yield { src: r.src, v: r.v.value };
    if (r.src === "a") pa = ia.next(); else pb = ib.next();
  }
}

// ---------------------------------------------------------------------------
// world: deterministic terrain from a seed + an edits overlay
// ---------------------------------------------------------------------------
const SIZE = 48, MAXY = 15;
const AIR = 0, GRASS = 1, DIRT = 2, STONE = 3, WOOD = 4, LEAF = 5, PLANK = 6, SAND = 7;
const BLOCK_COLORS = { [GRASS]: 0x58a83c, [DIRT]: 0x8a5a2b, [STONE]: 0x7d7d7d, [WOOD]: 0x6b4423, [LEAF]: 0x2f7a2e, [PLANK]: 0xb08d57, [SAND]: 0xe0d29a };
const HOTBAR = [GRASS, DIRT, STONE, PLANK];

// Terrain generation modes (the value travels in JoinResponse.mode):
//   0 "easy"    gentle plains, effortless to walk and build on
//   1 "complex" Mojang-style procgen: mountains, stone slopes,
//               sand lowlands, caves, denser forests
const MODE_EASY = 0, MODE_COMPLEX = 1;
let genMode = MODE_COMPLEX;

let seed = 1337;
const edits = new Map(); // "x,y,z" -> block (AIR removes)
const key = (x, y, z) => `${x},${y},${z}`;

function hash2(x, z, s) {
  let h = (x * 374761393 + z * 668265263 + s * 974634211) | 0;
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
function hash3(x, y, z, s) {
  let h = (x * 374761393 + y * 1103515245 + z * 668265263 + s * 974634211) | 0;
  h = Math.imul(h ^ (h >> 13), 1274126177);
  return ((h ^ (h >> 16)) >>> 0) / 4294967296;
}
// trilinear value noise for cave carving (complex mode)
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
  if (genMode === MODE_EASY) {
    // gentle: +/-1 around a flat plain — walk anywhere, build anywhere
    const n = smoothNoise(x, z, 14, seed) * 0.65 + smoothNoise(x, z, 6, seed + 7) * 0.35;
    return 3 + Math.floor(n * 2.2); // 3..5
  }
  // complex: broad mountains + ridged detail, 1..12
  const base = smoothNoise(x, z, 17, seed) * 0.55 + smoothNoise(x, z, 8, seed + 7) * 0.25;
  const ridge = 1 - Math.abs(smoothNoise(x, z, 6, seed + 31) * 2 - 1); // sharp crests
  return 1 + Math.floor(Math.min(1, base + ridge * ridge * 0.3) * 11);
}
function treeAt(x, z) {
  if (x < 2 || z < 2 || x >= SIZE - 2 || z >= SIZE - 2) return false;
  const density = genMode === MODE_EASY ? 0.995 : 0.978;
  return hash2(x, z, seed + 99) > density && heightAt(x, z) + 4 <= MAXY;
}
function terrainBlock(x, y, z) {
  if (x < 0 || z < 0 || x >= SIZE || z >= SIZE || y < 0) return AIR;
  if (y === 0) return STONE;
  const h = heightAt(x, z);
  // caves (complex): carve mid-depth pockets, never the surface or floor
  if (genMode === MODE_COMPLEX && y >= 2 && y <= h - 3 && noise3(x, y, z, 5, seed + 77) > 0.68) return AIR;
  if (y < h - 2) return STONE;
  if (y < h) return DIRT;
  if (y === h) {
    if (genMode === MODE_COMPLEX) {
      if (h <= 3) return SAND; // lowland beaches
      // steep faces shed their grass: exposed stone on cliffs
      const steep = Math.max(
        Math.abs(h - heightAt(x + 1, z)), Math.abs(h - heightAt(x - 1, z)),
        Math.abs(h - heightAt(x, z + 1)), Math.abs(h - heightAt(x, z - 1)));
      if (steep >= 2) return STONE;
    }
    return GRASS;
  }
  if (treeAt(x, z)) {
    if (y > h && y <= h + 3) return WOOD;
    if (y === h + 4) return LEAF;
  }
  if (y === h + 3) {
    // leaf canopy ring around any trunk top within reach
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]) {
      if (treeAt(x + dx, z + dz)) return LEAF;
    }
  }
  return AIR;
}
function spawnY() { return heightAt(SIZE / 2, SIZE / 2) + 3; }
function blockAt(x, y, z) {
  const e = edits.get(key(x, y, z));
  return e !== undefined ? e : terrainBlock(x, y, z);
}
function applyEdit(edit, rebuild = true) {
  edits.set(key(edit.x, edit.y, edit.z), edit.block);
  if (rebuild) rebuildMesh();
}

// ---------------------------------------------------------------------------
// three.js scene
// ---------------------------------------------------------------------------
let renderer, scene, camera, worldGroup, started = false;
const typeMeshes = new Map();
const avatars = new Map(); // playerId -> THREE.Group

function initThree() {
  renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize($("view").clientWidth, $("view").clientHeight);
  $("view").appendChild(renderer.domElement);
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x87ceeb);
  scene.fog = new THREE.Fog(0x87ceeb, 30, 90);
  camera = new THREE.PerspectiveCamera(75, $("view").clientWidth / $("view").clientHeight, 0.1, 200);
  scene.add(new THREE.AmbientLight(0xffffff, 0.75));
  const sun = new THREE.DirectionalLight(0xffffff, 1.6);
  sun.position.set(30, 50, 20);
  scene.add(sun);
  worldGroup = new THREE.Group();
  scene.add(worldGroup);
  const geo = new THREE.BoxGeometry(1, 1, 1);
  for (const [type, color] of Object.entries(BLOCK_COLORS)) {
    const mesh = new THREE.InstancedMesh(geo, new THREE.MeshLambertMaterial({ color }), 20000);
    mesh.count = 0;
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    worldGroup.add(mesh);
    typeMeshes.set(Number(type), mesh);
  }
}

function rebuildMesh() {
  if (!started) return;
  const lists = new Map([...typeMeshes.keys()].map((t) => [t, []]));
  const m = new THREE.Matrix4();
  for (let x = 0; x < SIZE; x++) for (let z = 0; z < SIZE; z++) {
    for (let y = 0; y <= MAXY; y++) {
      const b = blockAt(x, y, z);
      if (b === AIR) continue;
      if (blockAt(x + 1, y, z) && blockAt(x - 1, y, z) && blockAt(x, y + 1, z) &&
          blockAt(x, y - 1, z) && blockAt(x, y, z + 1) && blockAt(x, y, z - 1)) continue;
      lists.get(b)?.push([x, y, z]);
    }
  }
  for (const [type, mesh] of typeMeshes) {
    const cells = lists.get(type) || [];
    cells.forEach(([x, y, z], i) => mesh.setMatrixAt(i, m.makeTranslation(x + 0.5, y + 0.5, z + 0.5)));
    mesh.count = cells.length;
    mesh.instanceMatrix.needsUpdate = true;
  }
}

// ---------------------------------------------------------------------------
// local player: AABB physics against the voxel grid
// ---------------------------------------------------------------------------
const player = {
  pos: new THREE.Vector3(SIZE / 2, 12, SIZE / 2), // feet (snapped to terrain in startGame)
  vel: new THREE.Vector3(),
  yaw: 0, pitch: 0, onGround: false,
};
const keys = new Set();
let selectedBlock = GRASS;

function solidAt(x, y, z) { return blockAt(Math.floor(x), Math.floor(y), Math.floor(z)) !== AIR; }
function collides(p) {
  const r = 0.3, h = 1.8;
  for (let x = Math.floor(p.x - r); x <= Math.floor(p.x + r); x++)
    for (let y = Math.floor(p.y); y <= Math.floor(p.y + h); y++)
      for (let z = Math.floor(p.z - r); z <= Math.floor(p.z + r); z++)
        if (blockAt(x, y, z) !== AIR) return true;
  return false;
}
function moveAxis(axis, amount) {
  if (amount === 0) return;
  player.pos[axis] += amount;
  if (collides(player.pos)) {
    // step back to the boundary of the offending cell
    const step = Math.sign(amount) * 0.01;
    while (collides(player.pos)) player.pos[axis] -= step;
    player.pos[axis] -= step * 2;
    if (axis === "y") { if (amount < 0) player.onGround = true; player.vel.y = 0; }
  } else if (axis === "y") player.onGround = false;
}
function stepPlayer(dt) {
  // arrow keys look around (trackpads / accessibility / no mouse)
  const look = 2.4 * dt;
  if (keys.has("ArrowLeft")) player.yaw += look;
  if (keys.has("ArrowRight")) player.yaw -= look;
  if (keys.has("ArrowUp")) player.pitch = Math.min(1.5, player.pitch + look);
  if (keys.has("ArrowDown")) player.pitch = Math.max(-1.5, player.pitch - look);
  const speed = 6;
  const fwd = new THREE.Vector3(-Math.sin(player.yaw), 0, -Math.cos(player.yaw));
  const right = new THREE.Vector3(-fwd.z, 0, fwd.x);
  const wish = new THREE.Vector3();
  if (keys.has("KeyW")) wish.add(fwd);
  if (keys.has("KeyS")) wish.sub(fwd);
  if (keys.has("KeyD")) wish.add(right);
  if (keys.has("KeyA")) wish.sub(right);
  if (wish.lengthSq() > 0) wish.normalize().multiplyScalar(speed * dt);
  moveAxis("x", wish.x);
  moveAxis("z", wish.z);
  player.vel.y -= 22 * dt;
  if (keys.has("Space") && player.onGround) { player.vel.y = 8; player.onGround = false; }
  moveAxis("y", player.vel.y * dt);
  if (player.pos.y < -10) { player.pos.set(SIZE / 2, spawnY(), SIZE / 2); player.vel.set(0, 0, 0); }
  camera.position.set(player.pos.x, player.pos.y + 1.62, player.pos.z);
  camera.rotation.set(0, 0, 0);
  camera.rotateY(player.yaw);
  camera.rotateX(player.pitch);
}

// voxel raycast (Amanatides & Woo DDA), up to 6 m
function raycastVoxel() {
  const dir = new THREE.Vector3(0, 0, -1).applyEuler(new THREE.Euler(player.pitch, player.yaw, 0, "YXZ"));
  const o = camera.position.clone();
  let x = Math.floor(o.x), y = Math.floor(o.y), z = Math.floor(o.z);
  const stepX = Math.sign(dir.x), stepY = Math.sign(dir.y), stepZ = Math.sign(dir.z);
  const td = (s, c, d) => (d === 0 ? Infinity : Math.abs(1 / d) * (s > 0 ? Math.ceil(c) - c || 1 : c - Math.floor(c) || 1));
  let tmx = td(stepX, o.x, dir.x), tmy = td(stepY, o.y, dir.y), tmz = td(stepZ, o.z, dir.z);
  const dtx = dir.x === 0 ? Infinity : Math.abs(1 / dir.x);
  const dty = dir.y === 0 ? Infinity : Math.abs(1 / dir.y);
  const dtz = dir.z === 0 ? Infinity : Math.abs(1 / dir.z);
  let nx = 0, ny = 0, nz = 0, t = 0;
  for (let i = 0; i < 128; i++) {
    if (blockAt(x, y, z) !== AIR && t > 0) return { x, y, z, nx, ny, nz };
    if (tmx < tmy && tmx < tmz) { x += stepX; t = tmx; tmx += dtx; nx = -stepX; ny = 0; nz = 0; }
    else if (tmy < tmz) { y += stepY; t = tmy; tmy += dty; nx = 0; ny = -stepY; nz = 0; }
    else { z += stepZ; t = tmz; tmz += dtz; nx = 0; ny = 0; nz = -stepZ; }
    if (t > 6) return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// remote player avatars
// ---------------------------------------------------------------------------
function nameSprite(name, color) {
  const c = document.createElement("canvas");
  c.width = 256; c.height = 64;
  const g = c.getContext("2d");
  g.font = "bold 36px sans-serif";
  g.textAlign = "center";
  g.fillStyle = "rgba(0,0,0,0.45)";
  g.fillRect(0, 6, 256, 50);
  g.fillStyle = color;
  g.fillText(name.slice(0, 16), 128, 44);
  const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(c) }));
  sp.scale.set(1.6, 0.4, 1);
  sp.position.y = 2.15;
  return sp;
}
function ensureAvatar(id, name) {
  if (avatars.has(id)) return avatars.get(id);
  const hue = (id * 0.37) % 1;
  const color = new THREE.Color().setHSL(hue, 0.65, 0.55);
  const grp = new THREE.Group();
  const mat = new THREE.MeshLambertMaterial({ color });
  const body = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.1, 0.35), mat);
  body.position.y = 0.85;
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.42, 0.42), new THREE.MeshLambertMaterial({ color: 0xe8c39e }));
  head.position.y = 1.62;
  grp.add(body, head, nameSprite(name || `player ${id}`, `#${color.getHexString()}`));
  scene.add(grp);
  avatars.set(id, grp);
  return grp;
}
function dropAvatar(id) {
  const grp = avatars.get(id);
  if (grp) { scene.remove(grp); avatars.delete(id); }
}

// ---------------------------------------------------------------------------
// networking: host service + guest client over one RTCDataChannel
// ---------------------------------------------------------------------------
const players = new Map(); // id -> {name, pos:Vector3, yaw} (host: all; guest: remotes)
let myId = 0;
let guestOut = null; // guest -> Queue<ClientMsg>
let guestClient = null;
let guestConn = null; // {sendPos...} markers for loop

function myPosMsg() {
  return new Pos({ x: player.pos.x, y: player.pos.y, z: player.pos.z, yaw: player.yaw });
}
function myEditMsg(edit) {
  return new BlockEdit({ x: edit.x, y: edit.y, z: edit.z, block: edit.block });
}

// ---- host side: authoritative world; guests are thin callers ----
const hostConns = new Set(); // {playerId, out:Queue<ServerMsg>}
let nextPlayerId = 1;

function broadcast(msg, exceptConn = null) {
  for (const c of hostConns) if (c !== exceptConn) c.out.push(msg);
}
const stateMsg = (id, name, pos) => new ServerMsg({ player: new PlayerState({ id, name, pos }) });

function hostService() {
  return createGameService({
    async join(req) {
      const id = nextPlayerId++;
      players.set(id, { name: req.name || `player ${id}`, pos: new THREE.Vector3(SIZE / 2, spawnY(), SIZE / 2), yaw: 0 });
      log(`guest joined: ${req.name} (#${id})`);
      return new JoinResponse({
        playerId: id,
        seed,
        mode: genMode,
        edits: [...edits.entries()].map(([k, block]) => {
          const [x, y, z] = k.split(",").map(Number);
          return new BlockEdit({ x, y, z, block });
        }),
      });
    },
    async *play(requests) {
      const conn = { playerId: 0, out: new Queue() };
      hostConns.add(conn);
      try {
        for await (const { src, v } of merged(requests, conn.out)) {
          if (src === "b") { yield v; continue; }
          if (!conn.playerId && v.playerId) {
            conn.playerId = v.playerId;
            players.get(conn.playerId) && (players.get(conn.playerId).conn = conn);
          }
          if (v.pos) {
            const p = players.get(conn.playerId);
            if (p) { p.pos.set(v.pos.x, v.pos.y, v.pos.z); p.yaw = v.pos.yaw; }
            broadcast(stateMsg(conn.playerId, p?.name || "", v.pos), conn);
          } else if (v.edit) {
            applyEdit(v.edit);
            broadcast(new ServerMsg({ edit: v.edit }), null); // authoritative echo to everyone
          }
        }
      } finally {
        hostConns.delete(conn);
        if (conn.playerId) {
          players.delete(conn.playerId);
          dropAvatar(conn.playerId);
          broadcast(new ServerMsg({ left: conn.playerId }), null);
          log(`player #${conn.playerId} left`);
        }
      }
    },
  });
}

// host position ticker: guests learn about player 0 (the host) here;
// guest->guest positions ride the relay in play() above.
setInterval(() => {
  if (!hostConns.size) return;
  const state = stateMsg(0, $("name").value || "host", myPosMsg());
  broadcast(state, null);
}, 150);

// ---- guest side ----
async function guestJoinAndPlay(channel) {
  guestClient = new GameClient(channel);
  const name = $("name").value || "player";
  const resp = await guestClient.join(new JoinRequest({ name }));
  myId = resp.playerId;
  seed = resp.seed;
  genMode = resp.mode;
  edits.clear();
  for (const e of resp.edits) edits.set(key(e.x, e.y, e.z), e.block);
  rebuildMesh();
  log(`joined session as #${myId} (seed ${seed}, ${resp.mode === MODE_EASY ? "easy" : "complex"} terrain, ${resp.edits.length} edits)`);
  guestOut = new Queue();
  const stream = await guestClient.play(guestOut);
  guestConn = stream;
  (async () => {
    try {
      for await (const msg of stream) {
        if (msg.player) {
          if (msg.player.id === myId) continue;
          const p = players.get(msg.player.id) || { name: msg.player.name, pos: new THREE.Vector3(), yaw: 0 };
          p.name = msg.player.name || p.name;
          if (msg.player.pos) p.pos.set(msg.player.pos.x, msg.player.pos.y, msg.player.pos.z);
          p.yaw = msg.player.pos?.yaw || 0;
          players.set(msg.player.id, p);
        } else if (msg.edit) {
          applyEdit(msg.edit);
        } else if (msg.left) {
          players.delete(msg.left);
          dropAvatar(msg.left);
          log(`player #${msg.left} left`);
        }
      }
    } catch (e) { log(`play stream ended: ${e.message || e}`); }
  })();
  setInterval(() => {
    guestOut?.push(new ClientMsg({ playerId: myId, pos: myPosMsg() }));
  }, 100);
}

function localEdit(edit) {
  applyEdit(edit);
  if (guestOut) guestOut.push(new ClientMsg({ playerId: myId, edit: myEditMsg(edit) }));
  else if (hostConns.size || isHost) broadcast(new ServerMsg({ edit: myEditMsg(edit) }), null);
}

// ---------------------------------------------------------------------------
// manual signaling: base64url(JSON{sdp}) codes in URL fragments
// ---------------------------------------------------------------------------
const encCode = (obj) => {
  const bytes = new TextEncoder().encode(JSON.stringify(obj));
  let bin = "";
  bytes.forEach((b) => (bin += String.fromCharCode(b)));
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
};
const decCode = (code) => {
  const bin = atob(code.replaceAll("-", "+").replaceAll("_", "/"));
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0))));
};
function extractCode(text, marker) {
  const t = (text || "").trim();
  const i = t.indexOf(marker);
  return decCode(i >= 0 ? t.slice(i + marker.length).split(/[\s#]/)[0] : t);
}
function iceServers() {
  const out = [];
  const stun = $("stun").value.trim();
  if (stun) out.push({ urls: stun });
  const turn = $("turn-url").value.trim();
  if (turn) out.push({ urls: turn, username: $("turn-user").value, credential: $("turn-pass").value });
  return out;
}
function waitIce(pc) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((r) => {
    const t = setTimeout(r, 3000);
    pc.addEventListener("icegatheringstatechange", () => {
      if (pc.iceGatheringState === "complete") { clearTimeout(t); r(); }
    });
  });
}

let isHost = false;
let pendingHostPc = null;

async function hostCreateInvite() {
  const pc = new RTCPeerConnection({ iceServers: iceServers() });
  pendingHostPc = pc;
  const dc = pc.createDataChannel("grpc");
  dc.onopen = () => {
    const peer = createPeer(dc); // host created the channel: odd stream ids
    peer.server.addService(hostService());
    log("guest connected — grpc-dc server live on this browser");
  };
  dc.onclose = () => log("guest data channel closed");
  pc.onconnectionstatechange = () => log(`host peer: ${pc.connectionState}`);
  await pc.setLocalDescription(await pc.createOffer());
  await waitIce(pc);
  const link = `${location.origin}${location.pathname}#i=${encCode({ t: pc.localDescription.type, s: pc.localDescription.sdp })}`;
  $("invite-out").value = link;
  $("host-ui").hidden = false;
  log("invite ready — send the link, then paste the answer below");
}

async function hostAcceptAnswer() {
  if (!pendingHostPc) return log("create an invite first");
  try {
    const ans = extractCode($("answer-in").value, "#a=");
    await pendingHostPc.setRemoteDescription({ type: ans.t, sdp: ans.s });
    log("answer accepted — connecting…");
  } catch (e) { log(`bad answer code: ${e.message}`); }
}

async function guestAnswer(invite) {
  const pc = new RTCPeerConnection({ iceServers: iceServers() });
  pc.ondatachannel = (ev) => {
    const dc = ev.channel;
    dc.onopen = async () => {
      log("connected to host — joining game…");
      try {
        const peer = createPeer(dc, { parity: "even" }); // answering peer
        await guestJoinAndPlay(peer.channel);
        startGame();
      } catch (e) { log(`join failed: ${e.message || e}`); }
    };
    dc.onclose = () => log("data channel closed");
  };
  pc.onconnectionstatechange = () => log(`guest peer: ${pc.connectionState}`);
  await pc.setRemoteDescription({ type: invite.t, sdp: invite.s });
  await pc.setLocalDescription(await pc.createAnswer());
  await waitIce(pc);
  $("answer-out").value = `${location.origin}${location.pathname}#a=${encCode({ t: pc.localDescription.type, s: pc.localDescription.sdp })}`;
  $("guest-ui").hidden = false;
  log("answer ready — send the link back to the host");
}

// ---------------------------------------------------------------------------
// game bootstrap + loop + input
// ---------------------------------------------------------------------------
function startGame() {
  if (started) return;
  started = true;
  player.pos.y = spawnY();
  initThree();
  rebuildMesh();
  $("stage").scrollIntoView({ behavior: "smooth" });
  const clock = new THREE.Clock();
  renderer.setAnimationLoop(() => {
    const dt = Math.min(clock.getDelta(), 0.05);
    stepPlayer(dt);
    for (const [id, p] of players) {
      if (id === myId || id === 0 && isHost) continue;
      const a = ensureAvatar(id, p.name);
      a.position.lerp(new THREE.Vector3(p.pos.x, p.pos.y, p.pos.z), 0.5);
      a.rotation.y = -(p.yaw || 0);
    }
    renderer.render(scene, camera);
  });
  const view = $("view");
  view.addEventListener("click", () => renderer.domElement.requestPointerLock());
  document.addEventListener("pointerlockchange", () => {
    log(document.pointerLockElement ? "mouse locked — play! (Esc to release)" : "mouse released");
  });
  document.addEventListener("mousemove", (e) => {
    if (!document.pointerLockElement) return;
    player.yaw -= e.movementX * 0.0025;
    player.pitch = Math.max(-1.5, Math.min(1.5, player.pitch - e.movementY * 0.0025));
  });
  document.addEventListener("keydown", (e) => {
    keys.add(e.code);
    if (e.code.startsWith("Arrow")) e.preventDefault();
    const n = ["Digit1", "Digit2", "Digit3", "Digit4"].indexOf(e.code);
    if (n >= 0) { selectedBlock = HOTBAR[n]; renderHotbar(); }
  });
  document.addEventListener("keyup", (e) => keys.delete(e.code));
  const doBreak = () => {
    const hit = raycastVoxel();
    if (hit && hit.y > 0) localEdit({ ...hit, block: AIR });
  };
  const doPlace = () => {
    const hit = raycastVoxel();
    if (!hit) return;
    const t = { x: hit.x + hit.nx, y: hit.y + hit.ny, z: hit.z + hit.nz, block: selectedBlock };
    if (t.y <= MAXY) localEdit(t);
  };
  renderer.domElement.addEventListener("mousedown", (e) => {
    if (!document.pointerLockElement) return;
    if (e.button === 0) doBreak();
    else if (e.button === 2) doPlace();
  });
  document.addEventListener("keydown", (e) => {
    if (e.code === "KeyF") doBreak(); // keyboard-only play (no pointer lock needed)
    if (e.code === "KeyR") doPlace();
  });
  renderer.domElement.addEventListener("contextmenu", (e) => e.preventDefault());
  renderHotbar();
}
function renderHotbar() {
  const names = { [GRASS]: "grass", [DIRT]: "dirt", [STONE]: "stone", [PLANK]: "plank" };
  $("hotbar").textContent = " block: " + HOTBAR.map((b, i) => `${i + 1}:${names[b]}${b === selectedBlock ? "*" : ""}`).join(" ");
}

// ---------------------------------------------------------------------------
// lobby wiring
// ---------------------------------------------------------------------------
$("host-btn").onclick = async () => {
  isHost = true;
  myId = 0;
  genMode = Number($("gen-mode").value);
  seed = (Math.random() * 1e9) | 0;
  startGame();
  log(`hosting with seed ${seed} (${genMode === MODE_EASY ? "easy" : "complex"} terrain)`);
  await hostCreateInvite();
};
$("more-btn").onclick = () => hostCreateInvite();
$("accept-btn").onclick = () => hostAcceptAnswer();
$("solo-btn").onclick = () => { genMode = Number($("gen-mode").value); seed = (Math.random() * 1e9) | 0; startGame(); log(`solo world (${genMode === MODE_EASY ? "easy" : "complex"} terrain) — invite a friend any time with Host`); };
$("copy-invite").onclick = () => { $("invite-out").select(); navigator.clipboard.writeText($("invite-out").value); };
$("copy-answer").onclick = () => { $("answer-out").select(); navigator.clipboard.writeText($("answer-out").value); };

if (location.hash.startsWith("#i=")) {
  try {
    const invite = decCode(location.hash.slice(3));
    log("invite link detected — building your answer…");
    guestAnswer(invite);
  } catch (e) { log(`could not read invite link: ${e.message}`); }
} else {
  log("host a session, join from an invite link, or play solo");
}
