import { open, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import { isAbsolute, relative, sep } from "node:path";

export const MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export interface ScreenshotImage {
  type: "image";
  data: string;
  mimeType: "image/png";
}

/** Reads only host-owned PNG captures. Image bytes never appear in text/details. */
export async function loadScreenshotImage(filePath: string, captureDir: string): Promise<ScreenshotImage> {
  let root: string;
  let candidate: string;
  try {
    [root, candidate] = await Promise.all([realpath(captureDir), realpath(filePath)]);
  } catch {
    throw new Error("capture_failed: Screenshot file is missing or unreadable");
  }
  const fromRoot = relative(root, candidate);
  if (fromRoot === "" || fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) {
    throw new Error("capture_failed: Screenshot path is outside the pi-os captures directory");
  }

  const file = await open(candidate, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)).catch(() => {
    throw new Error("capture_failed: Screenshot file is missing or unreadable");
  });
  let data: Buffer;
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw new Error("capture_failed: Screenshot is not a regular file");
    if (stat.size > MAX_SCREENSHOT_BYTES) throw new Error("capture_failed: Screenshot exceeds the 8 MB limit");
    // Bound the allocation even if the file grows after stat(). The trusted root is host-owned (0700).
    const buffer = Buffer.alloc(Math.min(stat.size + 1, MAX_SCREENSHOT_BYTES + 1));
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await file.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    data = buffer.subarray(0, length);
    if (length > stat.size) throw new Error("capture_failed: Screenshot changed while reading");
  } finally {
    await file.close();
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
