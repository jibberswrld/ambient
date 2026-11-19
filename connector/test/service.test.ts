import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { handleConnectorRequest } from "../src/service.ts";

const originalFetch = globalThis.fetch;
const originalEnvironment = { ...process.env };
afterEach(() => {
  globalThis.fetch = originalFetch;
  process.env = { ...originalEnvironment };
});

let testNumber = 0;
function fixture(options: { claimState?: string; walletStatus?: number; owner?: string; upstreamFailure?: boolean } = {}) {
  const bearer = `pk_fixture_${++testNumber}`;
  process.env.COMPOSIO_API_KEY = "fixture";
  const requests: Request[] = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    requests.push(request.clone());
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/wallet") {
      assert.equal(request.headers.get("authorization"), `Bearer ${bearer}`);
      return Response.json({ claim_state: options.claimState ?? "claimed", account: { handle: "fixture" } }, { status: options.walletStatus ?? 200 });
    }
    assert.equal(request.headers.get("x-api-key"), "fixture");
    if (options.upstreamFailure) return Response.json({ message: "private upstream details" }, { status: 400 });
    if (url.pathname.endsWith("/tool_router/session") || /\/session\/session_fixture$/.test(url.pathname)) {
      if (request.method === "POST") {
        const body = await request.json();
        assert.equal(body.user_id, "ambient_fixture");
        assert.equal(body.toolkits, undefined);
        assert.equal(body.tools, undefined);
      }
      return Response.json({
        session_id: "session_fixture", mcp: { url: "https://backend.composio.dev/mcp" },
        config: { user_id: options.owner ?? "ambient_fixture", preload: { tools: [] }, execute: {}, search: {}, instant: false },
        experimental: { assistive_prompt: "Composio supplied guidance" },
      });
    }
    if (url.pathname.endsWith("/toolkits")) {
      assert.equal(url.searchParams.get("search"), "unlisted app");
      return Response.json({ items: [{ slug: "unlisted_app", name: "Unlisted App", is_no_auth: false, meta: { logo: "https://example.com/logo.png" }, connected_account: { id: "account_fixture", status: "ACTIVE", auth_config: { id: "config_fixture", auth_scheme: "OAUTH2", is_composio_managed: true } } }], next_cursor: "next-page", total_pages: 2 });
    }
    if (url.pathname.endsWith("/tools")) {
      return Response.json({ items: [{ slug: "COMPOSIO_SEARCH_TOOLS", name: "Search tools", description: "Find tools", input_parameters: { type: "object", properties: { queries: { type: "array" } } }, output_parameters: {}, tags: [], no_auth: true }], next_cursor: null });
    }
    if (url.pathname.endsWith("/link")) {
      assert.deepEqual(await request.json(), { toolkit: "unlisted_app" });
      return Response.json({ connected_account_id: "account_fixture", redirect_url: "https://connect.composio.dev/link/fixture" });
    }
    if (url.pathname.endsWith("/execute")) {
      assert.deepEqual(await request.json(), { tool_slug: "COMPOSIO_SEARCH_TOOLS", arguments: { queries: [{ use_case: "send an email" }] } });
      return Response.json({ result_type: "completed", data: { tools: ["DYNAMIC_DISCOVERED_TOOL"] }, error: null, log_id: "log_fixture" });
    }
    if (url.pathname.endsWith("/connected_accounts")) {
      assert.equal(url.searchParams.get("user_ids"), "ambient_fixture");
      assert.equal(url.searchParams.get("toolkit_slugs"), "unlisted_app");
      assert.equal(url.searchParams.get("account_type"), "PRIVATE");
      const cursor = url.searchParams.get("cursor");
      return Response.json({ items: [{ id: cursor ? "second" : "first", toolkit: { slug: "unlisted_app" }, status: "ACTIVE", status_reason: null, is_disabled: false, created_at: "2026-01-01", updated_at: "2026-01-01", auth_config: { id: "config_fixture", is_composio_managed: true, is_disabled: false } }], total_pages: 2, next_cursor: cursor ? null : "next" });
    }
    if (/\/connected_accounts\/(first|second)$/.test(url.pathname)) {
      assert.equal(request.method, "DELETE");
      return Response.json({ id: url.pathname.split("/").at(-1), deleted: true });
    }
    throw new Error(`Unexpected stub request: ${request.method} ${url.pathname}`);
  };
  return {
    requests,
    call: (path: string, body?: unknown, authorization = `Bearer ${bearer}`) => handleConnectorRequest(new Request(`http://localhost/api/${path}`, {
      method: body === undefined ? "GET" : "POST", headers: { authorization, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })),
  };
}

test("every route requires a publik bearer before any upstream access", async () => {
  const { call, requests } = fixture();
  for (const [path, body] of [["apps", undefined], ["tools", undefined], ["connect", {}], ["disconnect", {}], ["execute", {}]] as const) {
    assert.equal((await call(path, body, "")).status, 401);
  }
  assert.equal(requests.length, 0);
});

test("reject unclaimed accounts and wallets with non-success HTTP status", async () => {
  for (const options of [{ claimState: "anonymous" }, { walletStatus: 401 }]) {
    const { call, requests } = fixture(options);
    assert.equal((await call("tools")).status, 401);
    assert.equal(requests.length, 1);
  }
});

test("verification cache expires after five minutes without storing bearer values", async () => {
  const { call, requests } = fixture();
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    assert.equal((await call("tools")).status, 200);
    assert.equal((await call("tools")).status, 200);
    assert.equal(requests.filter(request => request.url.endsWith("/wallet")).length, 1);
    now += 5 * 60_000 + 1;
    assert.equal((await call("tools")).status, 200);
    assert.equal(requests.filter(request => request.url.endsWith("/wallet")).length, 2);
  } finally { Date.now = realNow; }
});

test("catalog search and pagination use Composio, including apps outside a handpicked catalog", async () => {
  const { call } = fixture();
  const response = await call("apps?query=unlisted%20app&cursor=previous");
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { apps: [{ slug: "unlisted_app", name: "Unlisted App", logoURL: "https://example.com/logo.png", isConnected: true }], nextCursor: "next-page" });
});

test("connection uses session authorization and returns a browser URL", async () => {
  const { call } = fixture();
  const response = await call("connect", { appSlug: "unlisted_app" });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { authorizationURL: "https://connect.composio.dev/link/fixture" });
});

test("disconnect enumerates all private account pages scoped to this user and toolkit", async () => {
  const { call, requests } = fixture();
  const response = await call("disconnect", { appSlug: "unlisted_app" });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  const deletions = requests.filter(request => request.method === "DELETE");
  assert.equal(deletions.length, 2);
  const lastListIndex = requests.findLastIndex(request => new URL(request.url).pathname.endsWith("/connected_accounts"));
  assert.ok(requests.findIndex(request => request.method === "DELETE") > lastListIndex);
});

test("tools return SDK OpenAI function definitions, session ID and guidance", async () => {
  const { call } = fixture();
  const response = await call("tools");
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.sessionId, "session_fixture");
  assert.equal(body.systemPrompt, "Composio supplied guidance");
  assert.equal(body.tools[0].type, "function");
  assert.equal(body.tools[0].function.name, "COMPOSIO_SEARCH_TOOLS");
  assert.equal(body.tools[0].function.parameters.type, "object");
});

test("execute uses the original session and dynamically validates its tools", async () => {
  const { call } = fixture();
  const response = await call("execute", { sessionId: "session_fixture", name: "COMPOSIO_SEARCH_TOOLS", arguments: { queries: [{ use_case: "send an email" }] } });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).result.data.tools[0], "DYNAMIC_DISCOVERED_TOOL");
  assert.equal((await call("execute", { sessionId: "session_fixture", name: "UNADVERTISED_TOOL", arguments: {} })).status, 400);
});

test("a session belonging to another user cannot execute or disclose its tools", async () => {
  const { call, requests } = fixture({ owner: "ambient_other" });
  const response = await call("execute", { sessionId: "session_fixture", name: "COMPOSIO_SEARCH_TOOLS", arguments: {} });
  assert.equal(response.status, 403);
  assert.equal(requests.some(request => request.url.endsWith("/tools") || request.url.endsWith("/execute")), false);
});

test("invalid payloads, missing configuration and upstream failures have small public errors", async () => {
  let { call } = fixture();
  for (const body of [null, [], {}, { appSlug: "" }, { appSlug: 3 }]) assert.equal((await call("connect", body)).status, 400);
  assert.equal((await call("execute", { sessionId: "session_fixture", name: "COMPOSIO_SEARCH_TOOLS", arguments: [] })).status, 400);
  delete process.env.COMPOSIO_API_KEY;
  let response = await call("tools");
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "connector_not_configured");
  ({ call } = fixture({ upstreamFailure: true }));
  response = await call("tools");
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: { code: "connector_error", message: "The connected app did not answer. Please try again." } });
});

test("publik outage returns a readable 503", async () => {
  const { call } = fixture({ walletStatus: 503 });
  const response = await call("apps");
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "publik_unreachable");
});

test("the Node adapter handles both raw local bodies and Vercel's parsed body", async () => {
  const { createServer } = await import("node:http");
  const { handleNodeRequest } = await import("../src/http.ts");
  const { requests } = fixture();
  const bearer = `pk_fixture_${testNumber}`;
  const server = createServer(async (request, response) => {
    if (request.headers["x-test-parsed-body"]) {
      Object.assign(request, { body: { appSlug: "unlisted_app" } });
    }
    await handleNodeRequest(request, response);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  try {
    for (const parsed of [false, true]) {
      const response: Response = await originalFetch(`http://127.0.0.1:${address.port}/api/connect`, {
        method: "POST", headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json", ...(parsed ? { "x-test-parsed-body": "yes" } : {}) },
        body: JSON.stringify({ appSlug: "unlisted_app" }),
      });
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("cache-control"), "no-store");
      assert.equal((await response.json()).authorizationURL, "https://connect.composio.dev/link/fixture");
    }
    assert.equal(requests.filter(request => request.url.endsWith("/link")).length, 2);
  } finally {
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
