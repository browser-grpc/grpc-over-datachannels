// VoxelSeed's own WebGPU engine: hand-written WGSL, instanced
// cube rendering, zero dependencies. One static cube geometry,
// per-chunk instance buffers (offset + color), one uniform block
// (view-projection, camera position, fog). Two pipelines share
// the shader: opaque blocks and translucent water.
// Interface mirrors engine-three.js:
//   addChunk(key, solidCells, waterCells)  cells: [x, y, z, hex]
//   removeChunk(key), setView(pos, yaw, pitch, radiusChunks), render()

const WGSL = /* wgsl */ `
struct Globals {
  viewProj: mat4x4f,
  camPos: vec3f,
  fogNear: f32,
  fogColor: vec3f,
  fogFar: f32,
}
@group(0) @binding(0) var<uniform> G: Globals;

struct VSIn {
  @location(0) pos: vec3f,
  @location(1) nrm: vec3f,
  @location(2) iPos: vec3f,
  @location(3) iColor: vec3f,
}
struct VSOut {
  @builtin(position) clip: vec4f,
  @location(0) color: vec3f,
  @location(1) nrm: vec3f,
  @location(2) dist: f32,
}

@vertex
fn vs(in: VSIn) -> VSOut {
  let world = in.pos + in.iPos;
  var out: VSOut;
  out.clip = G.viewProj * vec4f(world, 1.0);
  out.color = in.iColor;
  out.nrm = in.nrm;
  out.dist = length(world - G.camPos);
  return out;
}

fn shade(in: VSOut, alpha: f32) -> vec4f {
  let lightDir = normalize(vec3f(0.5, 0.8, 0.3));
  let diff = max(dot(normalize(in.nrm), lightDir), 0.0);
  let lit = in.color * (0.55 + 0.5 * diff);
  let f = smoothstep(G.fogNear, G.fogFar, in.dist);
  return vec4f(mix(lit, G.fogColor, f), alpha);
}

@fragment
fn fs(in: VSOut) -> @location(0) vec4f {
  return shade(in, 1.0);
}

@fragment
fn fsWater(in: VSOut) -> @location(0) vec4f {
  return shade(in, 0.65);
}
`;

// unit cube: 24 vertices (4 per face) with normals, 36 indices
function cubeGeometry() {
  const F = [
    // [normal, four corners] per face
    [[0, 0, 1], [[-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]]],
    [[0, 0, -1], [[0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5]]],
    [[1, 0, 0], [[0.5, -0.5, 0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5]]],
    [[-1, 0, 0], [[-0.5, -0.5, -0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5]]],
    [[0, 1, 0], [[-0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]]],
    [[0, -1, 0], [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]]],
  ];
  const verts = [];
  const idx = [];
  F.forEach(([n, corners], f) => {
    for (const c of corners) verts.push(...c, ...n);
    const b = f * 4;
    idx.push(b, b + 1, b + 2, b, b + 2, b + 3);
  });
  return { verts: new Float32Array(verts), idx: new Uint16Array(idx) };
}

// minimal column-major mat4 helpers (only what the camera needs)
const M = {
  mul(a, b) {
    const o = new Float32Array(16);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
      o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
    }
    return o;
  },
  perspective(fovY, aspect, near, far) {
    const f = 1 / Math.tan(fovY / 2);
    const o = new Float32Array(16);
    o[0] = f / aspect; o[5] = f;
    o[10] = far / (near - far); o[11] = -1;
    o[14] = (far * near) / (near - far);
    return o;
  },
  rotX(a) {
    const c = Math.cos(a), s = Math.sin(a);
    const o = new Float32Array(16);
    o[0] = 1; o[5] = c; o[6] = s; o[9] = -s; o[10] = c; o[15] = 1;
    return o;
  },
  rotY(a) {
    const c = Math.cos(a), s = Math.sin(a);
    const o = new Float32Array(16);
    o[0] = c; o[2] = -s; o[5] = 1; o[8] = s; o[10] = c; o[15] = 1;
    return o;
  },
  translate(x, y, z) {
    const o = new Float32Array(16);
    o[0] = 1; o[5] = 1; o[10] = 1; o[15] = 1;
    o[12] = x; o[13] = y; o[14] = z;
    return o;
  },
};

export async function createWebGPUEngine(container, { onError } = {}) {
  if (!navigator.gpu) throw new Error("WebGPU not available (navigator.gpu missing)");
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
  if (!adapter) throw new Error("WebGPU: no adapter");
  const device = await adapter.requestDevice();
  device.addEventListener("uncapturederror", (e) => onError?.(e.error.message));
  device.lost.then((info) => { if (info.reason !== "destroyed") onError?.("device lost: " + info.message); });

  const canvas = document.createElement("canvas");
  canvas.style.display = "block";
  container.appendChild(canvas);
  const ctx = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({ device, format, alphaMode: "opaque" });

  const module = device.createShaderModule({ label: "voxelseed", code: WGSL });
  const compile = await module.getCompilationInfo();
  const errs = compile.messages.filter((m) => m.type === "error");
  if (errs.length) throw new Error("WGSL: " + errs.map((m) => `${m.lineNum}:${m.linePos} ${m.message}`).join("; "));

  const { verts, idx } = cubeGeometry();
  const geoBuf = device.createBuffer({ label: "cube", size: verts.byteLength, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(geoBuf, 0, verts);
  const idxBuf = device.createBuffer({ label: "cube-idx", size: idx.byteLength, usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(idxBuf, 0, idx);

  const uniformBuf = device.createBuffer({ label: "globals", size: 96, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bindLayout = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } }],
  });
  const bindGroup = device.createBindGroup({ layout: bindLayout, entries: [{ binding: 0, resource: { buffer: uniformBuf } }] });
  const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [bindLayout] });

  const vertex = {
    module, entryPoint: "vs",
    buffers: [
      { arrayStride: 24, attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }, { shaderLocation: 1, offset: 12, format: "float32x3" }] },
      { arrayStride: 24, stepMode: "instance", attributes: [{ shaderLocation: 2, offset: 0, format: "float32x3" }, { shaderLocation: 3, offset: 12, format: "float32x3" }] },
    ],
  };
  const mkPipeline = (entryPoint, blend, depthWrite) => device.createRenderPipeline({
    label: entryPoint,
    layout: pipelineLayout,
    vertex,
    fragment: {
      module, entryPoint,
      targets: [{ format, ...(blend ? { blend: { color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha" }, alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" } } } : {}) }],
    },
    primitive: { topology: "triangle-list", cullMode: "back" },
    depthStencil: { format: "depth24plus", depthWriteEnabled: depthWrite, depthCompare: "less" },
  });
  const solidPipe = mkPipeline("fs", false, true);
  const waterPipe = mkPipeline("fsWater", true, false);

  const chunkBufs = new Map(); // key -> {solid:{buf,n}|null, water:{buf,n}|null}
  const hexRgb = (hex) => [((hex >> 16) & 255) / 255, ((hex >> 8) & 255) / 255, (hex & 255) / 255];
  const upload = (cells) => {
    if (!cells.length) return null;
    const data = new Float32Array(cells.length * 6);
    cells.forEach(([x, y, z, hex], i) => {
      const [r, g, b] = hexRgb(hex);
      data.set([x + 0.5, y + 0.5, z + 0.5, r, g, b], i * 6);
    });
    const buf = device.createBuffer({ size: data.byteLength, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(buf, 0, data);
    return { buf, n: cells.length };
  };

  let depthTex = null;
  function resize() {
    const w = Math.max(1, Math.floor(container.clientWidth * Math.min(devicePixelRatio, 2)));
    const h = Math.max(1, Math.floor(container.clientHeight * Math.min(devicePixelRatio, 2)));
    if (canvas.width === w && canvas.height === h && depthTex) return;
    canvas.width = w; canvas.height = h;
    canvas.style.width = "100%"; canvas.style.height = "100%";
    depthTex?.destroy();
    depthTex = device.createTexture({ size: [w, h], format: "depth24plus", usage: GPUTextureUsage.RENDER_ATTACHMENT });
  }
  new ResizeObserver(resize).observe(container);
  resize();

  const view = { pos: { x: 8, y: 18, z: 24 }, yaw: Math.PI, pitch: 0.1, radius: 4 };
  const uni = new Float32Array(24); // 96 bytes of globals

  return {
    name: "VoxelSeed WebGPU (hand-rolled)",
    canvas,
    addChunk(key, solidCells, waterCells) {
      this.removeChunk(key);
      chunkBufs.set(key, { solid: upload(solidCells), water: upload(waterCells) });
    },
    removeChunk(key) {
      const c = chunkBufs.get(key);
      if (!c) return;
      c.solid?.buf.destroy();
      c.water?.buf.destroy();
      chunkBufs.delete(key);
    },
    setView(pos, yaw, pitch, radiusChunks) {
      view.pos = pos; view.yaw = yaw; view.pitch = pitch; view.radius = radiusChunks;
    },
    render() {
      resize();
      const far = view.radius * 16;
      const proj = M.perspective((72 * Math.PI) / 180, canvas.width / canvas.height, 0.1, far * 1.6);
      // camera world = Ry(yaw) * Rx(-pitch); view = Rx(pitch) * Ry(-yaw) * T(-pos)
      const v = M.mul(M.rotX(view.pitch), M.mul(M.rotY(-view.yaw), M.translate(-view.pos.x, -view.pos.y, -view.pos.z)));
      const vp = M.mul(proj, v);
      uni.set(vp, 0);
      uni[16] = view.pos.x; uni[17] = view.pos.y; uni[18] = view.pos.z; uni[19] = far * 0.5;
      uni[20] = 0.53; uni[21] = 0.81; uni[22] = 0.92; uni[23] = far * 0.98;
      device.queue.writeBuffer(uniformBuf, 0, uni);
      const enc = device.createCommandEncoder({ label: "frame" });
      const pass = enc.beginRenderPass({
        colorAttachments: [{
          view: ctx.getCurrentTexture().createView(),
          clearValue: { r: 0.53, g: 0.81, b: 0.92, a: 1 },
          loadOp: "clear", storeOp: "store",
        }],
        depthStencilAttachment: { view: depthTex.createView(), depthClearValue: 1, depthLoadOp: "clear", depthStoreOp: "store" },
      });
      pass.setBindGroup(0, bindGroup);
      pass.setVertexBuffer(0, geoBuf);
      pass.setIndexBuffer(idxBuf, "uint16");
      pass.setPipeline(solidPipe);
      for (const c of chunkBufs.values()) {
        if (!c.solid) continue;
        pass.setVertexBuffer(1, c.solid.buf);
        pass.drawIndexed(36, c.solid.n);
      }
      pass.setPipeline(waterPipe);
      for (const c of chunkBufs.values()) {
        if (!c.water) continue;
        pass.setVertexBuffer(1, c.water.buf);
        pass.drawIndexed(36, c.water.n);
      }
      pass.end();
      device.queue.submit([enc.finish()]);
    },
    destroy() {
      for (const k of [...chunkBufs.keys()]) this.removeChunk(k);
      depthTex?.destroy();
      device.destroy();
      canvas.remove();
    },
  };
}
