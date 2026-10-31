# YouTube videos from blog posts

Generated explainer videos for the project blog posts. Narration is
synthesized locally by **Fish Audio Drama 3** running on a DGX Spark
(GB10) in its own container; slides, live demo captures, captions,
and assembly run inside the CI image. The host needs only Docker
(plus the GB10 for the TTS server) — nothing is installed on it.

Built with Fish Audio. Model weights (`fishaudio/drama-3`) are under
the [Fish Audio Community License 1.0](https://huggingface.co/fishaudio/drama-3/raw/main/LICENSE):
royalty-free commercial use while annual revenue is under
USD 500,000; generating narration for your own content is explicitly
not a "Hosted Service". We own the outputs.

## Architecture

| Piece | Where | Notes |
|---|---|---|
| Drama 3 TTS server | `Dockerfile.video` → container `drama3` | SGLang-Omni (pinned), GB10/GPU, ~37 GB weights downloaded on first start into the `drama3-hf` volume |
| Builder | CI image (`grpc-dc-ci`, Dockerfile.ci) | `video/build.mjs`: TTS calls, Playwright slides, real demo captures, ffmpeg assembly |
| Glue | Docker network `grpc-dc-video` | Builder reaches the server as `http://drama3:8000` |

Keeping the GPU speech stack out of `Dockerfile.ci` is deliberate:
that image is the CPU test gate for 16 languages and must stay lean.

## Make a video

```sh
# Terminal A: build + start the TTS server (first start is slow:
# ~37 GB model download + one-time FlashInfer SM121 JIT compile).
make video-tts-up

# Once it answers (docker exec drama3 curl -s localhost:8000/v1/models),
# build one or both videos:
make video-grpcdc     # grpc-over-datachannels (blog: introducing + direct)
make video-kafka      # kafka-proxy

# No GPU server handy? Silent framing/caption preview (never upload):
make video-preview VIDEO_SCRIPT=video/scripts/grpc-dc.json
```

Outputs land in `video/out/<id>/` (gitignored): `<id>.mp4`,
`<id>.srt` (upload alongside for searchable captions; they are also
burned into the MP4), `<id>-thumbnail.png`, and `<id>-youtube.txt`
(title, description, tags). Upload manually; there is no automatic
publishing.

## Narration scripts

`video/scripts/*.json` is the source of truth per video: scene list
(`title` / `bullets` / `demo` / `outro`), the spoken text per scene
(Drama 3 direction cues in `[brackets]` are performed, not read
aloud, and are stripped from captions), and the YouTube metadata.
A top-level `direction` sets the narrator's character for every
scene — currently a sultry cinematic actress voice (Drama 3 designs
the voice from that text; there is no reference clip). Change the
`direction` string and rebuild to recast the narrator.
Demo scenes run the real thing at build time — the direct Echo
example, and a generated JS client round trip through `kafka_proxy`
against a real Apache Kafka — and show the captured terminal output.

## Stop the server

```sh
make video-tts-down   # model weights stay cached in the volume
```
