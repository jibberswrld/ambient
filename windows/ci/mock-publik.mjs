// A stand-in for publik on the CI runner, so the built app can be run end to end without a real account,
// without minting installs and without spending anything. It answers the three calls a signed-in launch makes:
// GET /api/v1/wallet (signed in, on a plan), POST /api/v1/chat/completions (a short streamed reply) and
// POST /api/v1/telemetry. Everything else is a 404, which the app must survive (speech falls back to text).
import { createServer } from "node:http";

const port = Number(process.env.MOCK_PUBLIK_PORT ?? 4555);
const replyWords = ["Ambient ", "is ", "running ", "on ", "Windows."];

createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;
  request.resume();
  request.on("end", () => {
    console.log(`${request.method} ${path}`);
    if (request.method === "GET" && path === "/api/v1/wallet") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ claim_state: "claimed", account: { handle: "ci" }, plan: { kind: "plan", label: "Plus" }, balance_micros: 0, remaining_percent: 64, top_up_url: "https://publikhq.com/wallet" }));
    } else if (request.method === "POST" && path === "/api/v1/chat/completions") {
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const word of replyWords) {
        response.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: word } }] })}\n\n`);
      }
      response.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
      response.end("data: [DONE]\n\n");
    } else if (request.method === "POST" && path === "/api/v1/telemetry") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end("{}");
    } else {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "The CI mock does not serve this." } }));
    }
  });
}).listen(port, "127.0.0.1", () => console.log(`mock publik on ${port}`));
