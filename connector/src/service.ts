import { createHash } from "node:crypto";
import { Composio } from "@composio/core";

class ConnectorError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const verifiedAccounts = new Map<string, { handle: string; expiresAt: number }>();
const verificationLifetimeMilliseconds = 5 * 60_000;

async function verifiedUserIdentifier(request: Request): Promise<string> {
  const unauthorized = () => new ConnectorError(401, "unauthorized", "Sign in with a claimed publik account to use app connections.");
  const publikKey = /^Bearer (pk_\S+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!publikKey) throw unauthorized();
  // Keep a digest rather than the credential in the short verification cache.
  const credentialDigest = createHash("sha256").update(publikKey).digest("hex");
  const cachedAccount = verifiedAccounts.get(credentialDigest);
  if (cachedAccount && cachedAccount.expiresAt > Date.now()) return `ambient_${cachedAccount.handle}`;
  verifiedAccounts.delete(credentialDigest);
  let walletResponse: Response;
  try {
    walletResponse = await fetch(`${process.env.PUBLIK_ORIGIN || "https://publikhq.com"}/api/v1/wallet`, {
      headers: { authorization: `Bearer ${publikKey}` }, signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new ConnectorError(503, "publik_unreachable", "publik is not reachable. Please try again.");
  }
  if (walletResponse.status >= 500 || walletResponse.status === 429) {
    throw new ConnectorError(503, "publik_unreachable", "publik is not reachable. Please try again.");
  }
  const wallet = await walletResponse.json().catch(() => null);
  if (!walletResponse.ok || wallet?.claim_state !== "claimed" || typeof wallet?.account?.handle !== "string" || !wallet.account.handle) {
    throw unauthorized();
  }
  if (verifiedAccounts.size >= 5000) verifiedAccounts.clear();
  verifiedAccounts.set(credentialDigest, { handle: wallet.account.handle, expiresAt: Date.now() + verificationLifetimeMilliseconds });
  return `ambient_${wallet.account.handle}`;
}

function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

function requiredString(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.length > 512) {
    throw new ConnectorError(400, "invalid_request", "Provide the required nonempty string fields.");
  }
  return value;
}

async function requestObject(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    if (body && typeof body === "object" && !Array.isArray(body)) return body;
  } catch { /* Malformed JSON has the same public error as a malformed object. */ }
  throw new ConnectorError(400, "invalid_request", "Provide a JSON object.");
}

export async function handleConnectorRequest(request: Request): Promise<Response> {
  try {
    const userIdentifier = await verifiedUserIdentifier(request);
    const composioKey = process.env.COMPOSIO_API_KEY;
    if (!composioKey) throw new ConnectorError(503, "connector_not_configured", "App connections are not configured yet.");
    // SDK logging/tracking is disabled: upstream errors can contain private request details.
    const composio = new Composio({ apiKey: composioKey, allowTracking: false, logLevel: "silent" });
    const requestURL = new URL(request.url);
    const route = `${request.method} ${requestURL.pathname}`;
    switch (route) {
      case "GET /api/apps": {
        const session = await composio.create(userIdentifier);
        const page = await session.toolkits({
          search: requestURL.searchParams.get("query") || undefined,
          cursor: requestURL.searchParams.get("cursor") || undefined, limit: 50,
        });
        return jsonResponse({
          apps: page.items.map(app => ({ slug: app.slug, name: app.name, logoURL: app.logo ?? null, isConnected: app.connection?.isActive === true })),
          nextCursor: page.cursor ?? null,
        });
      }
      case "POST /api/connect": {
        const body = await requestObject(request);
        const appSlug = requiredString(body.appSlug);
        const session = await composio.create(userIdentifier);
        const connection = await session.authorize(appSlug);
        if (!connection.redirectUrl) throw new Error("Missing authorization URL");
        return jsonResponse({ authorizationURL: connection.redirectUrl });
      }
      case "POST /api/disconnect": {
        const body = await requestObject(request);
        const appSlug = requiredString(body.appSlug);
        let cursor: string | undefined;
        // Collect before deleting so removals cannot shift subsequent pages.
        const accountIdentifiers: string[] = [];
        do {
          const page = await composio.connectedAccounts.list({ userIds: [userIdentifier], toolkitSlugs: [appSlug], accountType: "PRIVATE", cursor });
          accountIdentifiers.push(...page.items.map(account => account.id));
          cursor = page.nextCursor ?? undefined;
        } while (cursor);
        for (const accountIdentifier of accountIdentifiers) await composio.connectedAccounts.delete(accountIdentifier);
        return jsonResponse({ ok: true });
      }
      case "GET /api/tools": {
        const session = await composio.create(userIdentifier);
        return jsonResponse({ sessionId: session.sessionId, tools: await session.tools(), systemPrompt: session.experimental.assistivePrompt ?? null });
      }
      case "POST /api/execute": {
        const body = await requestObject(request);
        const sessionIdentifier = requiredString(body.sessionId);
        const toolName = requiredString(body.name);
        if (!body.arguments || typeof body.arguments !== "object" || Array.isArray(body.arguments)) {
          throw new ConnectorError(400, "invalid_request", "Tool arguments must be a JSON object.");
        }
        const session = await composio.use(sessionIdentifier);
        // A session ID is not authorization. Verify its owner even on a fresh serverless instance.
        if (session.config.user_id !== userIdentifier) {
          throw new ConnectorError(403, "session_forbidden", "This tool session belongs to another account. Refresh app connections.");
        }
        const definitions = await session.tools();
        if (!definitions.some(tool => tool.type === "function" && tool.function.name === toolName)) {
          throw new ConnectorError(400, "invalid_request", "Choose a tool returned by this session.");
        }
        const result = await session.execute(toolName, body.arguments as Record<string, unknown>);
        return jsonResponse({ result });
      }
      default:
        throw new ConnectorError(404, "not_found", "Connector route not found.");
    }
  } catch (error) {
    if (error instanceof ConnectorError) return jsonResponse({ error: { code: error.code, message: error.message } }, error.status);
    // Never reflect SDK exceptions, stack traces, upstream response bodies or credentials.
    return jsonResponse({ error: { code: "connector_error", message: "The connected app did not answer. Please try again." } }, 502);
  }
}
