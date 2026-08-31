import { readFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";

export const MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export interface ScreenshotImage {
  type: "image";
  data: string;
  mimeType: "image/png";
}

/** Reads only host-owned PNG captures. Image bytes never appear in text/details. */
export async function loadScreenshotImage(filePath: string, captureDir: string): Promise<ScreenshotImage> {
  const root = resolve(captureDir);
  const candidate = resolve(filePath);
  const fromRoot = relative(root, candidate);
  if (fromRoot === "" || fromRoot.startsWith("..") || isAbsolute(fromRoot)) {
    throw new Error("capture_failed: Screenshot path is outside the pi-os captures directory");
  }

  let data: Buffer;
  try {
    data = await readFile(candidate);
  } catch {
    throw new Error("capture_failed: Screenshot file is missing or unreadable");
  }
  if (data.length === 0) {
    throw new Error("capture_failed: Screenshot file is empty");
  }
  if (data.length > MAX_SCREENSHOT_BYTES) {
    throw new Error("capture_failed: Screenshot exceeds the 8 MB limit");
  }
  if (data.length < PNG_SIGNATURE.length || !data.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error("capture_failed: Screenshot is not a PNG file");
  }

  return { type: "image", mimeType: "image/png", data: data.toString("base64") };
}
