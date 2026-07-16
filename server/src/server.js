import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { WebSocket, WebSocketServer } from 'ws';
import { config } from './config.js';
import {
  V2Store,
  handleV2Http,
  handleV2WebSocket,
  kdfMetrics,
  storageMetrics
} from './v2Store.js';
import { SafeUpdateFileError, safeOpenUpdateFile } from './updateFiles.js';

const v2Store = new V2Store({
  dataDir: config.v2DataDir,
  limits: {
    messageBytes: config.messageMaxBytes,
    messagesPerConversation: config.messagesPerConversation,
    conversationBytes: config.conversationQuotaBytes,
    accountBytes: config.accountQuotaBytes,
    instanceBytes: config.instanceQuotaBytes,
    dailyAccountBytes: config.dailyAccountQuotaBytes,
    minFreeDiskBytes: config.minFreeDiskBytes
  },
  sessionTtlMs: config.sessionTtlHours * 60 * 60 * 1000,
  sessionIdleTtlMs: config.sessionIdleTtlHours * 60 * 60 * 1000
});

let cachedStorageMetrics = null;
let cachedStorageMetricsAt = 0;

function timingSafeTextEqual(left, right) {
  const a = Buffer.from(String(left || ''), 'utf8');
  const b = Buffer.from(String(right || ''), 'utf8');
  return a.length === b.length && a.length > 0 && crypto.timingSafeEqual(a, b);
}

function currentStorageMetrics() {
  const now = Date.now();
  const ttlMs = config.metricsStorageCacheSeconds * 1000;
  if (cachedStorageMetrics && now - cachedStorageMetricsAt < ttlMs) {
    return cachedStorageMetrics;
  }
  cachedStorageMetrics = storageMetrics(v2Store);
  cachedStorageMetricsAt = now;
  return cachedStorageMetrics;
}

function clientIp(req) {
  const remote = req.socket.remoteAddress || '';
  if (!config.trustedProxies.includes(remote)) return remote;
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded !== 'string') return remote;
  const first = forwarded.split(',')[0].trim();
  return /^[0-9a-fA-F:.]+$/.test(first) ? first : remote;
}

function metricsIpAllowed(req) {
  if (config.metricsAllowedIps.includes('*')) return true;
  return config.metricsAllowedIps.includes(req.clientIp || '');
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff'
  });
  res.end(JSON.stringify(payload));
}

function serveUpdateManifest(res) {
  const file = path.resolve(config.updateManifestFile);
  let opened;
  try {
    opened = safeOpenUpdateFile(path.dirname(file), path.basename(file), {
      maxBytes: 1024 * 1024
    });
  } catch (error) {
    if (error instanceof SafeUpdateFileError && error.code === 'TOO_LARGE') {
      sendJson(res, 500, { ok: false, error: 'Niepoprawny manifest aktualizacji.' });
      return;
    }
    sendJson(res, 404, { ok: false, error: 'Brak manifestu aktualizacji.' });
    return;
  }
  res.writeHead(200, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': opened.stat.size,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff'
  });
  fs.createReadStream(opened.file, { fd: opened.fd, autoClose: true })
    .on('error', () => res.destroy())
    .pipe(res);
}

function serveUpdateFile(res, encodedName) {
  let decoded;
  try {
    decoded = decodeURIComponent(encodedName);
  } catch {
    sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa pliku.' });
    return;
  }
  const fileName = path.basename(decoded);
  if (!fileName || fileName !== decoded || !/^[a-zA-Z0-9._-]+$/.test(fileName)) {
    sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa pliku.' });
    return;
  }
  const baseDir = path.resolve(config.updateFilesDir);
  let opened;
  try {
    opened = safeOpenUpdateFile(baseDir, fileName);
  } catch {
    sendJson(res, 404, { ok: false, error: 'Plik aktualizacji nie istnieje.' });
    return;
  }
  res.writeHead(200, {
    'content-type': 'application/octet-stream',
    'content-length': opened.stat.size,
    'cache-control': 'no-store',
    'content-disposition': `attachment; filename="${fileName}"`,
    'x-content-type-options': 'nosniff'
  });
  fs.createReadStream(opened.file, { fd: opened.fd, autoClose: true })
    .on('error', () => res.destroy())
    .pipe(res);
}

const httpServer = http.createServer((req, res) => {
  req.clientIp = clientIp(req);
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname === '/healthz') {
    sendJson(res, 200, { ok: true });
    return;
  }
  if (url.pathname === '/metrics') {
    if (!metricsIpAllowed(req)) {
      sendJson(res, 403, { ok: false, error: 'Endpoint metryk jest dostepny tylko z dozwolonych adresow.' });
      return;
    }
    if (!config.adminToken || !timingSafeTextEqual(req.headers['x-admin-token'], config.adminToken)) {
      sendJson(res, 401, { ok: false, error: 'Brak autoryzacji administratora.' });
      return;
    }
    sendJson(res, 200, {
      ok: true,
      time: new Date().toISOString(),
      kdf: kdfMetrics(),
      storage: currentStorageMetrics()
    });
    return;
  }
  if (url.pathname === '/v2' || url.pathname.startsWith('/v2/')) {
    void handleV2Http(v2Store, req, res, url, {
      registrationMode: config.registrationMode,
      adminToken: config.adminToken
    });
    return;
  }
  if (url.pathname === '/updates/manifest.json') {
    serveUpdateManifest(res);
    return;
  }
  if (url.pathname.startsWith('/updates/files/')) {
    serveUpdateFile(res, url.pathname.slice('/updates/files/'.length));
    return;
  }
  sendJson(res, 404, { ok: false, error: 'NOT_FOUND' });
});

httpServer.headersTimeout = 10_000;
httpServer.requestTimeout = 30_000;
httpServer.keepAliveTimeout = 5_000;

const wss = new WebSocketServer({
  noServer: true,
  maxPayload: config.maxPayloadBytes,
  perMessageDeflate: false
});

httpServer.on('upgrade', (request, socket, head) => {
  let url;
  try {
    url = new URL(request.url || '/', 'http://127.0.0.1');
  } catch {
    socket.destroy();
    return;
  }
  if (url.pathname !== '/v2/ws' || url.search) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit('connection', ws, request);
  });
});

wss.on('connection', (ws, request) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  handleV2WebSocket(v2Store, ws, request);
});

const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) continue;
    if (client.isAlive === false) {
      client.terminate();
      continue;
    }
    client.isAlive = false;
    client.ping();
  }
}, 30_000);
heartbeat.unref();

function shutdown() {
  clearInterval(heartbeat);
  for (const client of wss.clients) client.close(1001, 'Server shutdown');
  httpServer.close(() => process.exit(0));
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

httpServer.listen(config.port, config.host, () => {
  console.info(`Secure chat v2 listening on ${config.host}:${config.port}`);
});
