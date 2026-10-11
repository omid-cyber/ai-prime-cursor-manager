import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { Readable } from "node:stream";

const HOST = "127.0.0.1";
const PORT = Number(process.env.CURSOR_BRIDGE_PORT || 8787);
const LOCAL_KEY = process.env.CURSOR_BRIDGE_KEY || "";
const API_KEY = process.env.AIPRIMETECH_API_KEY || "";
const API_BASE = (process.env.AIPRIMETECH_BASE_URL || "https://aiprimetech.io/v1").replace(/\/+$/, "");
const UPSTREAM_MODEL = process.env.AIPRIMETECH_MODEL || "claude-sonnet-4-6";
const MODEL_ALIAS = process.env.CURSOR_MODEL_ALIAS || "aiprimetech-sonnet-4-6";
const LOG_PATH = process.env.BRIDGE_LOG_PATH || path.join(os.homedir(), "AppData", "Local", "AIPrimeCursorBridge", "bridge.log");

// AI Prime Tech gateway plans can enforce a concurrent-request ceiling. Queue Cursor's
// parallel calls locally so they don't all race upstream at once.
const MAX_UPSTREAM_CONCURRENCY = Math.max(1, Number(process.env.CURSOR_BRIDGE_MAX_CONCURRENCY || 1));
const MAX_UPSTREAM_QUEUE = Math.max(1, Number(process.env.CURSOR_BRIDGE_MAX_QUEUE || 8));
const UPSTREAM_QUEUE_TIMEOUT_MS = Math.max(15000, Number(process.env.CURSOR_BRIDGE_QUEUE_TIMEOUT_MS || 120000));
let activeUpstream = 0;
const upstreamWaiters = [];

function acquireUpstreamSlot() {
  if (activeUpstream < MAX_UPSTREAM_CONCURRENCY) {
    activeUpstream++;
    return Promise.resolve(makeRelease());
  }
  if (upstreamWaiters.length >= MAX_UPSTREAM_QUEUE) {
    const error = new Error("Local upstream queue is full. Wait for active Cursor requests to finish, then retry.");
    error.code = "local_concurrency_limit";
    error.statusCode = 429;
    return Promise.reject(error);
  }
  log(`Upstream slot busy; queueing request (${upstreamWaiters.length + 1}/${MAX_UPSTREAM_QUEUE}).`);
  return new Promise((resolve, reject) => {
    const waiter = { resolve, reject, timer: null };
    waiter.timer = setTimeout(() => {
      const index = upstreamWaiters.indexOf(waiter);
      if (index >= 0) upstreamWaiters.splice(index, 1);
      const error = new Error("Timed out waiting for an upstream slot. The provider is busy; retry later.");
      error.code = "local_queue_timeout";
      error.statusCode = 429;
      reject(error);
    }, UPSTREAM_QUEUE_TIMEOUT_MS);
    upstreamWaiters.push(waiter);
  }).then(() => makeRelease());
}

function makeRelease() {
  let released = false;
  return () => {
    if (released) return;
    released = true;
    while (upstreamWaiters.length > 0) {
      const next = upstreamWaiters.shift();
      if (!next) continue;
      clearTimeout(next.timer);
      next.resolve();
      return; // Hand the existing slot directly to the next queued request.
    }
    activeUpstream = Math.max(0, activeUpstream - 1);
  };
}

function log(message) {
  try {
    fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
    try {
      if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > 2_000_000) {
        fs.writeFileSync(LOG_PATH, "");
      }
    } catch { /* logging must not stop the bridge */ }
    fs.appendFileSync(LOG_PATH, `${new Date().toISOString()} [BRIDGE] ${message}\r\n`, "utf8");
  } catch { /* logging must not stop the bridge */ }
}

function send(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(data));
}

function authorized(req) {
  return Boolean(LOCAL_KEY) && req.headers.authorization === `Bearer ${LOCAL_KEY}`;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${HOST}:${PORT}`);
  const endpoint = url.pathname;

  if (req.method === "GET" && endpoint === "/health") {
    return send(res, 200, { ok: true, model: UPSTREAM_MODEL, alias: MODEL_ALIAS, port: PORT, activeUpstream, queuedUpstream: upstreamWaiters.length, maxUpstreamConcurrency: MAX_UPSTREAM_CONCURRENCY });
  }

  if (!authorized(req)) {
    log(`Rejected unauthorized request ${req.method} ${endpoint}`);
    return send(res, 401, { error: { message: "Invalid local bridge key" } });
  }

  if (req.method === "GET" && (endpoint === "/v1/models" || endpoint === "/models")) {
    log(`Models list requested; exposing alias ${MODEL_ALIAS}`);
    return send(res, 200, {
      object: "list",
      data: [{ id: MODEL_ALIAS, object: "model", created: 0, owned_by: "aiprimetech" }]
    });
  }

  if (req.method !== "POST" || !["/v1/chat/completions", "/chat/completions"].includes(endpoint)) {
    return send(res, 404, { error: { message: "Unsupported endpoint" } });
  }

  if (!API_KEY) {
    log("Request failed because AI Prime Tech API key is missing");
    return send(res, 500, { error: { message: "AI Prime Tech API key is missing. Open the manager and restart the bridge." } });
  }

  let raw = "";
  try {
    for await (const chunk of req) {
      raw += chunk.toString("utf8");
      if (raw.length > 20_000_000) {
        return send(res, 413, { error: { message: "Request too large" } });
      }
    }

    let body;
    try {
      body = JSON.parse(raw || "{}");
    } catch {
      log("Rejected malformed JSON request body.");
      return send(res, 400, { error: { code: "invalid_json", message: "Request body must be valid JSON." } });
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      log("Rejected invalid request JSON shape.");
      return send(res, 400, { error: { code: "invalid_request", message: "Request body must be a JSON object." } });
    }
    const requestedAlias = body.model || MODEL_ALIAS;
    body.model = UPSTREAM_MODEL;
    log(`Forwarding chat request: alias=${String(requestedAlias).slice(0, 100)} upstream=${UPSTREAM_MODEL} stream=${Boolean(body.stream)}`);

    let releaseSlot = null;
    try {
      releaseSlot = await acquireUpstreamSlot();
    } catch (queueError) {
      log(`Upstream queue did not accept request: ${queueError.code || queueError.message}`);
      res.setHeader("Retry-After", "5");
      return send(res, queueError.statusCode || 429, {
        error: {
          code: queueError.code || "local_concurrency_limit",
          message: queueError.message || "The local upstream queue is full. Retry later."
        }
      });
    }

    let slotReleased = false;
    const releaseOnce = () => {
      if (!slotReleased && releaseSlot) {
        slotReleased = true;
        releaseSlot();
      }
    };

    try {
      const upstream = await fetch(`${API_BASE}/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${API_KEY}`,
          "Content-Type": "application/json",
          Accept: req.headers.accept || "application/json"
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(180_000)
      });

      log(`Upstream responded with HTTP ${upstream.status}; active=${activeUpstream}; queued=${upstreamWaiters.length}`);
      res.statusCode = upstream.status;
      res.setHeader("Content-Type", upstream.headers.get("content-type") || "application/json");
      const cacheControl = upstream.headers.get("cache-control");
      if (cacheControl) res.setHeader("Cache-Control", cacheControl);
      const requestId = upstream.headers.get("x-request-id");
      if (requestId) res.setHeader("x-request-id", requestId);

      if (upstream.body) {
        const source = Readable.fromWeb(upstream.body);
        source.once("end", releaseOnce);
        source.once("error", releaseOnce);
        source.once("close", releaseOnce);
        res.once("close", releaseOnce);
        source.pipe(res);
      } else {
        res.end();
        releaseOnce();
      }
    } catch (upstreamError) {
      releaseOnce();
      throw upstreamError;
    }
  } catch (error) {
    log(`Request failed: ${String(error?.message || error).replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]")}`);
    if (!res.headersSent) {
      const status = error?.statusCode || 502;
      if (status === 429) res.setHeader("Retry-After", "5");
      send(res, status, { error: { code: error?.code || "bridge_error", message: `Bridge error: ${error?.message || "unknown error"}` } });
    } else {
      res.destroy();
    }
  }
});

server.on("error", error => {
  log(`Server error: ${error.message}`);
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  log(`Started on http://${HOST}:${PORT}; model alias=${MODEL_ALIAS}; upstream=${UPSTREAM_MODEL}`);
});

function shutdown() {
  log("Bridge stopping");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);