// Video builder: narration script (video/scripts/<id>.json) ->
// slides + live demo capture + Drama 3 narration -> captioned MP4.
// Runs INSIDE the CI image (Dockerfile.ci: Node + Playwright + ffmpeg);
// the only host commands are the docker invocations in the Makefile
// `video-*` targets. The Drama 3 server runs in its own container
// (Dockerfile.video) on the `grpc-dc-video` docker network.
//
//   node video/build.mjs video/scripts/grpc-dc.json [--no-tts]
//
// Env:
//   TTS_URL   Drama 3 server base (default http://drama3:8000)
//   VIDEO_OUT output root (default video/out)
//
// --no-tts renders a silent preview (estimated scene durations) so
// framing/captions can be checked before the GPU server is up. It is
// labelled PREVIEW and must never be uploaded as a final video.
//
// Outputs (video/out/<id>/): <id>.mp4, <id>.srt, <id>-thumbnail.png,
// <id>-youtube.txt (title/description/tags), plus intermediates.

import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../browser-test/', import.meta.url));
const { chromium } = require('playwright');

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const scriptPath = args.find((a) => a.endsWith('.json'));
const NO_TTS = args.includes('--no-tts');
if (!scriptPath) {
  console.error('usage: node video/build.mjs video/scripts/<id>.json [--no-tts]');
  process.exit(2);
}
const spec = JSON.parse(await readFile(scriptPath, 'utf8'));
const OUT = path.join(process.env.VIDEO_OUT ?? path.join(ROOT, 'video/out'), spec.id);
const TTS_URL = (process.env.TTS_URL ?? 'http://drama3:8000').replace(/\/$/, '');
await mkdir(OUT, { recursive: true });

const run = (cmd, argv, opts = {}) =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, argv, { cwd: ROOT, ...opts });
    let out = '';
    child.stdout?.on('data', (d) => (out += d));
    child.stderr?.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) =>
      code === 0 ? resolve(out) : reject(new Error(`${cmd} ${argv.join(' ')} exited ${code}\n${out.slice(-2000)}`)),
    );
  });

const probeDuration = async (file) => {
  const out = await run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]);
  return Number.parseFloat(out.trim());
};

// Spoken-text -> caption text: drop [direction] cues and <tags>, and
// undo the spelled-out forms the narration uses for the TTS voice.
const CAPTION_FIXES = [
  ['H T T P slash two', 'HTTP/2'],
  ['g R P C', 'gRPC'],
  ['grpcdc kafka version one', 'grpcdc.kafka.v1.Kafka'],
  ['T C P', 'TCP'],
  ['U D P', 'UDP'],
  ['D T L S', 'DTLS'],
  ['S C T P', 'SCTP'],
  ['S D P', 'SDP'],
  ['C I ', 'CI '],
];
const captionText = (say) => {
  let text = say
    .replace(/\[[^\]]*\]\s*/g, '')
    .replace(/<\/?[a-z]+>/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
  for (const [spoken, written] of CAPTION_FIXES) text = text.split(spoken).join(written);
  return text;
};

// Rough speaking rate for silent previews (~150 wpm).
const estimateDuration = (say) => Math.max(2.5, captionText(say).split(/\s+/).length / 2.5);

// ---- TTS (Fish Audio Drama 3 on SGLang-Omni, OpenAI-compatible) ----
async function ttsModel() {
  const res = await fetch(`${TTS_URL}/v1/models`);
  if (!res.ok) throw new Error(`TTS GET /v1/models -> ${res.status}`);
  const body = await res.json();
  return body.data[0].id;
}

async function speak(model, text, file, voice) {
  const res = await fetch(`${TTS_URL}/v1/audio/speech`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, input: text, response_format: 'wav', ...(voice ? { voice } : {}) }),
  });
  if (!res.ok) throw new Error(`TTS POST /v1/audio/speech -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
  await writeFile(file, Buffer.from(await res.arrayBuffer()));
}

// Voice locking: a script may pin narration to a reference take
// (spec.voice: {name, refAudio, refText}) — e.g. the take the user
// picked at 1:55 of the grpc-dc video. The reference is uploaded to
// the Drama 3 server once (uploaded voices persist server-side) and
// every scene is then generated with that voice, so character cannot
// drift between slides the way pure direction-based casting can.
// The reference is synthetic speech we generated ourselves; no real
// person is cloned.
const VOICE_CONSENT =
  'Synthetic AI-generated project narration created by us; no identifiable real person is being cloned.';
async function ensureVoice(specVoice) {
  const list = await (await fetch(`${TTS_URL}/v1/audio/voices`)).json();
  const names = list.uploaded_voice_names ?? list.voices ?? [];
  if (names.some((n) => String(n).toLowerCase() === specVoice.name.toLowerCase())) {
    console.log(`-- voice '${specVoice.name}' already on TTS server`);
    return specVoice.name;
  }
  const audio = await readFile(path.join(ROOT, specVoice.refAudio));
  const form = new FormData();
  form.append('audio_sample', new Blob([audio], { type: 'audio/wav' }), path.basename(specVoice.refAudio));
  form.append('consent', VOICE_CONSENT);
  form.append('name', specVoice.name);
  if (specVoice.refText) form.append('ref_text', specVoice.refText);
  const res = await fetch(`${TTS_URL}/v1/audio/voices`, { method: 'POST', body: form });
  if (!res.ok) throw new Error(`TTS POST /v1/audio/voices -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
  console.log(`-- uploaded reference voice '${specVoice.name}' from ${specVoice.refAudio}`);
  return specVoice.name;
}

// ---- Live demo captures (real runs, trimmed for the terminal slide) ----
const trimLines = (text, max = 16) =>
  text
    .split('\n')
    .map((l) => (l.length > 118 ? `${l.slice(0, 60)}...${l.slice(-40)}` : l))
    .filter((l, i, a) => l.trim() !== '' || (i > 0 && a[i - 1].trim() !== ''))
    .slice(-max)
    .join('\n');

async function captureDirectEcho() {
  const server = spawn('node', ['examples/direct/server.mjs'], { cwd: ROOT });
  let serverOut = '';
  try {
    const addr = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no MULTIADDR in:\n${serverOut}`)), 30000);
      server.stdout.on('data', (d) => {
        serverOut += d;
        const m = serverOut.match(/MULTIADDR\s+(\S+)/);
        if (m) {
          clearTimeout(timer);
          resolve(m[1]);
        }
      });
      server.on('exit', () => reject(new Error(`server exited:\n${serverOut}`)));
    });
    const clientOut = await run('node', ['examples/direct/client.mjs', addr]);
    return trimLines(`$ node examples/direct/server.mjs\n${serverOut}$ node examples/direct/client.mjs '${addr}'\n${clientOut}`);
  } finally {
    server.kill('SIGTERM');
  }
}

async function captureKafkaRoundtrip() {
  const tmp = await run('mktemp', ['-d']);
  const dir = tmp.trim();
  const props = path.join(dir, 'kafka.properties');
  await writeFile(
    props,
    [
      'process.roles=broker,controller',
      'node.id=1',
      'listeners=PLAINTEXT://127.0.0.1:19092,CONTROLLER://127.0.0.1:19094',
      'advertised.listeners=PLAINTEXT://127.0.0.1:19092',
      'controller.listener.names=CONTROLLER',
      'controller.quorum.voters=1@127.0.0.1:19094',
      `log.dirs=${dir}/logs`,
      'offsets.topic.replication.factor=1',
      'transaction.state.log.replication.factor=1',
      'transaction.state.log.min.isr=1',
      'group.initial.rebalance.delay.ms=0',
      'num.partitions=1',
      '',
    ].join('\n'),
  );
  const waitPort = async (port, label, tries = 120) => {
    for (let i = 0; i < tries; i++) {
      try {
        await run('bash', ['-c', `exec 3<>/dev/tcp/127.0.0.1/${port}`]);
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 1000));
      }
    }
    throw new Error(`${label} did not open port ${port}`);
  };
  const procs = [];
  try {
    const cid = await run('/opt/kafka/bin/kafka-storage.sh', ['random-uuid']);
    await run('/opt/kafka/bin/kafka-storage.sh', ['format', '-t', cid.trim(), '-c', props, '--ignore-formatted']);
    procs.push(spawn('/opt/kafka/bin/kafka-server-start.sh', [props], { cwd: ROOT, detached: true }));
    await waitPort(19092, 'kafka');
    await run('cargo', ['build', '--features', 'kafka-tls', '--example', 'kafka_proxy'], { cwd: path.join(ROOT, 'rust') });
    procs.push(
      spawn(path.join(ROOT, 'rust/target/debug/examples/kafka_proxy'), ['--tcp', '127.0.0.1:50201', '--broker', '127.0.0.1:19092'], {
        cwd: ROOT,
        detached: true,
      }),
    );
    await waitPort(50201, 'kafka_proxy');
    const testOut = await run(
      'node',
      ['--test', '--test-name-pattern', 'roundtrip|per-partition|offset resume', 'test/kafka.test.js'],
      { cwd: path.join(ROOT, 'js'), env: { ...process.env, KAFKA_E2E_PROXY_ADDR: '127.0.0.1:50201' } },
    );
    const lines = testOut.split('\n').filter((l) => /^(✔|ok|# (pass|fail)|kafka)/.test(l.trim()) || l.includes('pass'));
    return trimLines(
      `$ kafka_proxy --tcp 127.0.0.1:50201 --broker 127.0.0.1:19092  (Apache Kafka)\n$ node --test test/kafka.test.js   # generated JS client\n${lines.join('\n')}`,
    );
  } finally {
    for (const p of procs) {
      try {
        process.kill(-p.pid, 'SIGTERM');
      } catch {
        p.kill('SIGTERM');
      }
    }
  }
}

async function captureTracingDemo() {
  const out = await run('node', ['examples/tracing_nested_demo.mjs'], { cwd: path.join(ROOT, 'js') });
  return trimLines(`$ node js/examples/tracing_nested_demo.mjs\n${out}`);
}

async function captureEventbusDemo() {
  const out = await run('node', ['examples/eventbus_demo.js'], { cwd: path.join(ROOT, 'js') });
  return trimLines(`$ node js/examples/eventbus_demo.js\n${out}`);
}

const DEMOS = {
  'direct-echo': captureDirectEcho,
  'kafka-roundtrip': captureKafkaRoundtrip,
  'tracing-demo': captureTracingDemo,
  'eventbus-demo': captureEventbusDemo,
};

// ---- Slides (HTML -> Playwright screenshot, 1920x1080) ----
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function slideHtml(scene, index, total) {
  const base = `
    * { margin: 0; box-sizing: border-box; }
    body { width: 1920px; height: 1080px; overflow: hidden; background: #0b1020; color: #e8ecf6;
      font-family: 'DejaVu Sans', system-ui, sans-serif; padding: 110px 130px; display: flex; flex-direction: column; }
    .kicker { color: #6ea8ff; font-size: 30px; letter-spacing: 4px; text-transform: uppercase; margin-bottom: 34px; }
    h1 { font-size: 96px; line-height: 1.08; font-weight: 800; }
    h2 { font-size: 64px; line-height: 1.15; font-weight: 750; margin-bottom: 44px; }
    .sub { font-size: 42px; color: #aab6d3; margin-top: 36px; line-height: 1.4; }
    ul { list-style: none; } li { font-size: 44px; line-height: 1.35; padding: 20px 0 20px 52px; position: relative; color: #d6def2; }
    li::before { content: ''; position: absolute; left: 0; top: 42px; width: 18px; height: 18px; border-radius: 4px; background: #6ea8ff; }
    pre { background: #060a16; border: 1px solid #22304f; border-radius: 16px; padding: 40px 44px;
      font-family: 'DejaVu Sans Mono', monospace; font-size: 27px; line-height: 1.45; color: #9fe8a9; white-space: pre-wrap; word-break: break-all; }
    .foot { margin-top: auto; display: flex; justify-content: space-between; color: #5f6f92; font-size: 26px; }
    .preview { color: #ffb454; }`;
  const foot = `<div class="foot"><span>browser-grpc</span><span>${index + 1} / ${total}</span></div>`;
  if (scene.kind === 'title') {
    return `<!doctype html><style>${base}</style><div class="kicker">${esc(spec.id)}</div><h1>${esc(scene.heading)}</h1><div class="sub">${esc(scene.sub ?? '')}</div>${foot}`;
  }
  if (scene.kind === 'demo') {
    return `<!doctype html><style>${base}</style><div class="kicker">Live demo</div><h2>${esc(scene.heading)}</h2><pre>${esc(scene.terminal ?? '')}</pre>${foot}`;
  }
  const items = (scene.bullets ?? []).map((b) => `<li>${esc(b)}</li>`).join('');
  return `<!doctype html><style>${base}</style><div class="kicker">${esc(spec.id)}</div><h2>${esc(scene.heading)}</h2><ul>${items}</ul>${foot}`;
}

async function renderSlides() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  for (let i = 0; i < spec.scenes.length; i++) {
    await page.setContent(slideHtml(spec.scenes[i], i, spec.scenes.length), { waitUntil: 'load' });
    await page.screenshot({ path: path.join(OUT, `frame-${String(i).padStart(2, '0')}.png`) });
  }
  await browser.close();
}

// ---- Main flow ----
const srtTime = (s) => {
  const ms = Math.round((s % 1) * 1000);
  const t = Math.floor(s);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(Math.floor(t / 3600))}:${p(Math.floor((t / 60) % 60))}:${p(t % 60)},${String(ms).padStart(3, '0')}`;
};

console.log(`== ${spec.id}: ${spec.scenes.length} scenes, out=${OUT}, tts=${NO_TTS ? 'PREVIEW(no-tts)' : TTS_URL}`);

// 1. Demo captures first (slides embed their terminal output).
for (const scene of spec.scenes) {
  if (scene.kind === 'demo') {
    console.log(`-- capturing demo: ${scene.demo}`);
    scene.terminal = await DEMOS[scene.demo]();
    await writeFile(path.join(OUT, `demo-${scene.demo}.txt`), scene.terminal);
  }
}

// 2. Narration per SENTENCE -> scene wavs + true caption timings.
// Scene-length Drama 3 takes garbled and drifted: sampling at
// temperature 1.0 occasionally loops or mumbles, and caption timing
// could only be estimated by splitting the scene duration evenly.
// Sentence-length takes are far more reliable, each bad take is
// re-rolled on its own, and caption cues use measured durations.
// The script's `direction` rides on every take; the locked reference
// voice (spec.voice) anchors the character across all of them.
const model = NO_TTS ? null : await ttsModel();
console.log(`-- TTS model: ${model ?? '(none, preview)'}`);
const voice = !NO_TTS && spec.voice ? await ensureVoice(spec.voice) : null;
if (voice) console.log(`-- locked voice: ${voice}`);
const SENTENCE_GAP = 0.18;
const gapWav = path.join(OUT, 'gap.wav');
if (!NO_TTS) {
  await run('ffmpeg', ['-y', '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=mono', '-t', String(SENTENCE_GAP), gapWav]);
}
const splitSentences = (say) => (say.match(/[^.!?]+[.!?]+/g) ?? [say]).map((s) => s.trim()).filter(Boolean);
const durations = [];
const captionCues = [];
let sceneClock = 0;
for (let i = 0; i < spec.scenes.length; i++) {
  const sentences = splitSentences(spec.scenes[i].say);
  const sceneWav = path.join(OUT, `scene-${String(i).padStart(2, '0')}.wav`);
  let offset = 0;
  if (NO_TTS) {
    for (const s of sentences) {
      const dur = estimateDuration(s);
      captionCues.push({ start: sceneClock + offset, end: sceneClock + offset + dur, text: captionText(s) });
      offset += dur + SENTENCE_GAP;
    }
  } else {
    const concatList = [];
    for (let j = 0; j < sentences.length; j++) {
      const sentWav = path.join(OUT, `sent-${String(i).padStart(2, '0')}-${String(j).padStart(2, '0')}.wav`);
      const spoken = spec.direction ? `${spec.direction} ${sentences[j]}` : sentences[j];
      const expected = estimateDuration(sentences[j]);
      let dur = 0;
      for (let attempt = 1; attempt <= 4; attempt++) {
        await speak(model, spoken, sentWav, voice);
        dur = await probeDuration(sentWav);
        if (dur >= expected * 0.5 && dur <= expected * 2.2) break;
        console.log(`   scene ${i} sentence ${j}: take ${attempt} is ${dur.toFixed(1)}s vs ~${expected.toFixed(1)}s expected, re-rolling`);
        if (attempt === 4) throw new Error(`scene ${i} sentence ${j}: TTS kept producing implausible durations (last ${dur.toFixed(1)}s)`);
      }
      captionCues.push({ start: sceneClock + offset, end: sceneClock + offset + dur, text: captionText(sentences[j]) });
      offset += dur;
      concatList.push(`file '${sentWav}'`);
      if (j < sentences.length - 1) {
        concatList.push(`file '${gapWav}'`);
        offset += SENTENCE_GAP;
      }
    }
    const listFile = path.join(OUT, `scene-${String(i).padStart(2, '0')}.concat.txt`);
    await writeFile(listFile, concatList.join('\n'));
    await run('ffmpeg', ['-y', '-f', 'concat', '-safe', '0', '-i', listFile, '-c:a', 'pcm_s16le', sceneWav]);
  }
  durations.push(offset + 0.4);
  sceneClock += offset + 0.4;
  console.log(`   scene ${i}: ${durations[i].toFixed(1)}s (${sentences.length} sentences)`);
}

// 3. Slides.
await renderSlides();

// 4. Captions (SRT from measured sentence timings).
{
  let n = 1;
  const blocks = captionCues.map(
    (c) => `${n++}\n${srtTime(c.start)} --> ${srtTime(c.end)}\n${c.text}\n`,
  );
  await writeFile(path.join(OUT, `${spec.id}.srt`), blocks.join('\n'));
}

// 5. Per-scene segments, then concat + burned captions + loudness norm.
const segList = [];
for (let i = 0; i < spec.scenes.length; i++) {
  const seg = path.join(OUT, `seg-${String(i).padStart(2, '0')}.mp4`);
  const frame = path.join(OUT, `frame-${String(i).padStart(2, '0')}.png`);
  const dur = durations[i].toFixed(3);
  const audioIn = NO_TTS
    ? ['-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo']
    : ['-i', path.join(OUT, `scene-${String(i).padStart(2, '0')}.wav`)];
  await run('ffmpeg', [
    '-y', '-loop', '1', '-i', frame, ...audioIn,
    '-c:v', 'libx264', '-tune', 'stillimage', '-pix_fmt', 'yuv420p', '-r', '30',
    '-c:a', 'aac', '-b:a', '160k', '-af', 'apad', '-t', dur, seg,
  ]);
  segList.push(`file '${seg}'`);
}
await writeFile(path.join(OUT, 'concat.txt'), segList.join('\n'));
const srtEscaped = path.join(OUT, `${spec.id}.srt`).replace(/'/g, "'\\''").replace(/:/g, '\\:');
await run('ffmpeg', [
  '-y', '-f', 'concat', '-safe', '0', '-i', path.join(OUT, 'concat.txt'),
  '-vf', `subtitles='${srtEscaped}':force_style='FontSize=22,PrimaryColour=&HFFFFFF,OutlineColour=&H80000000,Outline=1.5,MarginV=36'`,
  '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11',
  '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-c:a', 'aac', '-b:a', '160k',
  path.join(OUT, `${spec.id}.mp4`),
]);

// 6. Upload sidecar files.
await copyFile(path.join(OUT, 'frame-00.png'), path.join(OUT, `${spec.id}-thumbnail.png`));
await writeFile(
  path.join(OUT, `${spec.id}-youtube.txt`),
  `TITLE:\n${spec.youtube.title}\n\nDESCRIPTION:\n${spec.youtube.description}\n\nTAGS:\n${spec.youtube.tags.join(', ')}\n\nSOURCE BLOG POST:\n${spec.source}\n`,
);
console.log(`== done: ${path.join(OUT, `${spec.id}.mp4`)}${NO_TTS ? '  (SILENT PREVIEW — re-run without --no-tts for final)' : ''}`);

