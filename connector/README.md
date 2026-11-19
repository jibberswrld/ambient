# Ambient connector

A small Node.js/TypeScript service keeps the Composio project key off the Mac. Composio's unrestricted Tool Router owns app discovery, connection authorization, schemas and execution. Ambient supplies no toolkit catalog or app adapters.

## Run

Requires Node.js 22.22.3 or newer in the 22.x release line. Install with `npm ci`. Export `COMPOSIO_API_KEY` in the server process environment, then `npm run dev`. The server listens only at `http://127.0.0.1:3019`. Node runs the TypeScript directly; no postinstall binary is required. Never put the key in the Mac app. `.env.example` documents configuration; the server does not load dotenv files automatically.

Run `npm test` and `npm run typecheck`. Tests stub HTTP for both publik and the real Composio SDK, with no external accounts or credentials.

## HTTP API

Every request requires `Authorization: Bearer <publik install key>`. The service verifies `GET https://publikhq.com/api/v1/wallet`, requires `claim_state: "claimed"` with an account handle, and uses `ambient_<handle>` as the Composio user ID. Verification is cached for five minutes using a SHA-256 digest of the credential (bounded to 5,000 entries per instance). Consequently, credential revocations can take up to five minutes to reach a warm instance. Responses have `Cache-Control: no-store`.

| Route | Request | Response |
| --- | --- | --- |
| `GET /api/apps` | Optional `query` and `cursor` query parameters | `{ apps: [{ slug, name, logoURL: string \| null, isConnected: boolean }], nextCursor: string \| null }` (50 per page) |
| `POST /api/connect` | `{ appSlug: string }` | `{ authorizationURL: string }`; open it in a browser |
| `POST /api/disconnect` | `{ appSlug: string }` | `{ ok: true }`; removes all this user's private accounts for that toolkit, across pages |
| `GET /api/tools` | No body | `{ sessionId: string, tools: OpenAIFunctionTool[], systemPrompt: string \| null }` |
| `POST /api/execute` | `{ sessionId: string, name: string, arguments: object }` | `{ result: <Composio session execution result> }` |

Tool definitions are the SDK's OpenAI `{ type: "function", function: { name, description, parameters } }` JSON. Guidance comes from `session.experimental.assistivePrompt`. Carry the returned session ID through subsequent calls: discovery and execution share Composio's session state. The server retrieves the session, checks `config.user_id` against the verified caller, and permits only tools advertised by that session. It never accepts a caller-supplied user ID.

Errors are always `{ error: { code: string, message: string } }`. Statuses: 400 malformed request or unadvertised tool, 401 unclaimed/invalid publik credential, 403 session owned by someone else, 404 unknown route, 413 body over 1 MiB, 502 Composio failure, 503 missing configuration or unreachable publik. SDK exceptions and upstream error bodies are not returned or logged. Execution results, including app-level errors, remain tool data.

## Vercel

Create a deployment with **Root Directory `connector`**, **Framework Preset Other**, and the **Node.js 22.x** runtime (latest patch, at least 22.22.3). Use the normal `npm ci` install, no frontend build command, and no output-directory override. `api/[...path].ts` is the Node function entry point; `vercel.json` allows up to 300 seconds for tool calls. The HTTP adapter handles both Vercel's parsed request bodies and local Node streams.

Set **`COMPOSIO_API_KEY`** as a server-only Vercel environment variable. **`PUBLIK_ORIGIN`** is optional for isolated tests and defaults to `https://publikhq.com`; leave it unset in real deployments. There is no database, Composio project creation, MCP server provisioning, callback route or browser UI to configure. Composio hosts the authorization page and completion flow. No deployment was performed for this implementation.

Point the Mac at the resulting HTTPS origin using `AMBIENT_CONNECTOR_ORIGIN` (or the explicit client initializer). HTTP origins are accepted only for loopback development.

## Swift integration

```swift
let connectorClient = AmbientConnectorClient(credentialSource: publikCredentialSource)
let connectorTools = ComposioToolProvider(client: connectorClient) { authorizationURL in
    await MainActor.run { _ = NSWorkspace.shared.open(authorizationURL) }
}
// Use connectorClient as ConnectorService in settings.
// Supply connectorTools as ToolProvider to the agent.
```

`AmbientConnectorClient(origin: URL? = nil, credentialSource: any AICredentialSource, urlSession: URLSession = .shared)` conforms to `ConnectorService`. It uses the credential's publik `apiKey` as bearer and ignores its AI base URL. Explicit origin takes precedence over `AMBIENT_CONNECTOR_ORIGIN`, then `http://127.0.0.1:3019`. It follows catalog search pages internally; an empty query returns the first page of popular apps.

`ComposioToolProvider(client:authorizationRequired:)` is an actor conforming to `ToolProvider`. The async `@Sendable (URL) -> Void` callback must open the browser and return; it should not wait for OAuth completion. Meta tools and SDK guidance share a coalesced five-minute cache keyed to the credential. Previously returned tools refuse execution after a sign-in change. Argument-based flow-bar labels use tool slugs and search text without app-specific logic. Results are bounded at 48,000 UTF-8 bytes plus a truncation note; narrower queries or pagination retrieve more. Nested Composio HTTPS authorization links trigger the callback before truncation, and the model is told the browser was opened and to retry after the person finishes. Arbitrary URLs in app data never auto-open. Offline/unconfigured providers expose a readable error tool; execution never throws.

From `Packages/AmbientKit`:

```sh
swift build --target AmbientConnectors --scratch-path .build-connectors
swift test --filter AmbientConnectorsTests --scratch-path .build-connectors
AMBIENT_LIVE_TESTS=1 swift test --filter AmbientConnectorsTests --scratch-path .build-connectors
```

The live test is skipped by default. When enabled, it reads the existing publik development credential from `~/Library/Application Support/publik/apps/looseends.json`, uses the running connector, lists real apps, obtains an authorization URL without opening it, fetches real meta tools and guidance, and executes the read-only search meta tool for “send an email.” It never completes OAuth, executes a discovered app action, or disconnects a real account. The connector's own Composio key must already be in its process environment.

SDK references checked for this implementation: [session methods](https://docs.composio.dev/reference/sdk-reference/typescript/session), [session creation and reuse](https://docs.composio.dev/reference/sdk-reference/typescript/sessions), and the installed `@composio/core` 0.29.0 TypeScript source/types.
