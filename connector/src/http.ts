import type { IncomingMessage, ServerResponse } from "node:http";
import { handleConnectorRequest } from "./service.ts";

export async function handleNodeRequest(request: IncomingMessage & { body?: unknown }, response: ServerResponse): Promise<void> {
  try {
    const chunks: Buffer[] = [];
    let bodyBytes = 0;
    // Vercel exposes a parsed body; the loopback server exposes the raw stream.
    const parsedBody = request.body;
    const bodyChunks = parsedBody === undefined
      ? request
      : [Buffer.isBuffer(parsedBody) ? parsedBody : Buffer.from(typeof parsedBody === "string" ? parsedBody : JSON.stringify(parsedBody))];
    for await (const chunk of bodyChunks) {
      bodyBytes += chunk.length;
      if (bodyBytes > 1_048_576) {
        response.writeHead(413, { "content-type": "application/json", "cache-control": "no-store" });
        response.end(JSON.stringify({ error: { code: "invalid_request", message: "The connector request is too large." } }));
        return;
      }
      chunks.push(Buffer.from(chunk));
    }
    const headers = new Headers();
    for (const [name, value] of Object.entries(request.headers)) {
      if (value !== undefined) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
    }
    const method = request.method || "GET";
    const connectorResponse = await handleConnectorRequest(new Request(`http://connector.local${request.url || "/"}`, {
      method, headers, ...(method !== "GET" && method !== "HEAD" ? { body: Buffer.concat(chunks) } : {}),
    }));
    response.writeHead(connectorResponse.status, Object.fromEntries(connectorResponse.headers));
    response.end(Buffer.from(await connectorResponse.arrayBuffer()));
  } catch {
    response.writeHead(400, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify({ error: { code: "invalid_request", message: "The connector request could not be read." } }));
  }
}
