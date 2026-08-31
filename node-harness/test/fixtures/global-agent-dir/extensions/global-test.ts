import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function globalTestExtension(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "fixture_global_tool",
    label: "Fixture Global Tool",
    description: "A test tool loaded from the configured global agent directory.",
    parameters: Type.Object({}, { additionalProperties: false }),
    async execute() {
      return {
        content: [{ type: "text", text: "Global fixture tool is available." }],
        details: {},
      };
    },
  });
}
