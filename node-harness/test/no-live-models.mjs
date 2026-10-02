// Loaded BEFORE SDK/tsx imports by npm test. Unit/conformance tests must never warm
// a local model or accidentally spend provider tokens. Only this project's loopback
// test HTTP routes are allowed through fetch; no Ollama/provider APIs are permitted.
process.env.PI_OFFLINE = "1";
process.env.PI_OS_AGENT = "0";

const originalFetch = globalThis.fetch;
const testRoutes = /^(?:\/health|\/tools(?:\/[^?]*)?|\/invoke|\/invocations\/[^?]*|\/models|\/settings\/(?:model|resources))$/;
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "localhost";
  if (!loopback || url.protocol !== "http:" || url.port === "11434" || !testRoutes.test(url.pathname)) {
    throw new Error(`Live provider/network calls are forbidden in tests: ${url.origin}${url.pathname}`);
  }
  return originalFetch(input, init);
};
