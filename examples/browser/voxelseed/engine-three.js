// Fallback engine: three.js WebGL, used only when WebGPU is
// unavailable. Same interface as engine-webgpu.js:
//   addChunk(key, solidCells, waterCells)  cells: [x, y, z, hex]
//   removeChunk(key), setView(pos, yaw, pitch, radiusChunks), render()
import * as THREE from "three";

export function createThreeEngine(container) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(container.clientWidth, container.clientHeight);
  container.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x87ceeb);
  const camera = new THREE.PerspectiveCamera(72, container.clientWidth / container.clientHeight, 0.1, 900);
  scene.add(new THREE.AmbientLight(0xffffff, 0.8));
  const sun = new THREE.DirectionalLight(0xffffff, 1.5);
  sun.position.set(60, 90, 30);
  scene.add(sun);
  const boxGeo = new THREE.BoxGeometry(1, 1, 1);
  const solidMat = new THREE.MeshLambertMaterial({ color: 0xffffff });
  const waterMat = new THREE.MeshLambertMaterial({ color: 0x2f6fd0, transparent: true, opacity: 0.65, depthWrite: false });
  const chunkMeshes = new Map();
  addEventListener("resize", () => {
    camera.aspect = container.clientWidth / container.clientHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(container.clientWidth, container.clientHeight);
  });

  function fill(cells, mat, cap) {
    if (!cells.length) return null;
    const mesh = new THREE.InstancedMesh(boxGeo, mat, Math.min(cells.length, cap));
    const m = new THREE.Matrix4();
    const color = new THREE.Color();
    cells.slice(0, cap).forEach(([x, y, z, hex], i) => {
      mesh.setMatrixAt(i, m.makeTranslation(x + 0.5, y + 0.5, z + 0.5));
      if (mat === solidMat) mesh.setColorAt(i, color.setHex(hex));
    });
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    scene.add(mesh);
    return mesh;
  }

  return {
    name: "three.js WebGL (fallback)",
    canvas: renderer.domElement,
    addChunk(key, solidCells, waterCells) {
      this.removeChunk(key);
      const meshes = [fill(solidCells, solidMat, 8192), fill(waterCells, waterMat, 2048)].filter(Boolean);
      chunkMeshes.set(key, meshes);
    },
    removeChunk(key) {
      for (const mesh of chunkMeshes.get(key) || []) { scene.remove(mesh); mesh.dispose(); }
      chunkMeshes.delete(key);
    },
    setView(pos, yaw, pitch, radiusChunks) {
      camera.position.set(pos.x, pos.y, pos.z);
      camera.rotation.set(0, 0, 0);
      camera.rotateY(yaw);
      camera.rotateX(-pitch);
      const far = radiusChunks * 16;
      scene.fog = new THREE.Fog(0x87ceeb, far * 0.5, far * 0.98);
      camera.far = far * 1.6;
      camera.updateProjectionMatrix();
    },
    render() { renderer.render(scene, camera); },
    destroy() {
      for (const k of [...chunkMeshes.keys()]) this.removeChunk(k);
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}
