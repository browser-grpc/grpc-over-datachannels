import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
if (!process.env.GRPC_DC_KAFKA_NATIVE_ADDON) {
  const prebuild = join(here, "prebuilds", process.platform + "-" + process.arch, "kafka_native_addon.node");
  if (existsSync(prebuild)) process.env.GRPC_DC_KAFKA_NATIVE_ADDON = prebuild;
}
export * from "./kafka_native.js";
