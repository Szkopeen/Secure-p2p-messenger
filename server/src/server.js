import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { WebSocketServer, WebSocket } from 'ws';
import { config } from './config.js';
import {
  safeJsonParse,
  validateContactRequest,
  validateDirectoryQuery,
  validateDirectoryUpdate,
  validateHello,
  validatePresenceQuery,
  validateProfileQuery,
  validateProfileUpdate,
  validateRelay,
  validateSignal
} from './protocol.js';
import { SlidingWindowRateLimiter } from './rateLimiter.js';

const users = new Map();
const profiles = new Map();
const offlineQueues = new Map();
const publicDirectory = new Map();

loadProfiles();
loadOfflineQueues();
loadPublicDirectory();

function audit(message, fields = {}) {
  if (!config.securityLogs) return;
  const safeFields = { ...fields };
  delete safeFields.payload;
  delete safeFields.relayToken;
  console.info(JSON.stringify({ time: new Date().toISOString(), message, ...safeFields }));
}

function loadOfflineQueues() {
  try {
    if (!fs.existsSync(config.offlineQueueFile)) return;
    const raw = fs.readFileSync(config.offlineQueueFile, 'utf8');
    const decoded = JSON.parse(raw);
    if (!decoded || decoded.v !== 1 || !decoded.queues) return;

    const now = Date.now();
    for (const [userId, items] of Object.entries(decoded.queues)) {
      if (!Array.isArray(items)) continue;
      const liveItems = items.filter((item) => item.expiresAt > now && item.envelope);
      if (liveItems.length > 0) offlineQueues.set(userId, liveItems);
    }
  } catch (error) {
    audit('Nie wczytano kolejki offline', { error: String(error) });
  }
}

function loadProfiles() {
  try {
    if (!fs.existsSync(config.publicProfilesFile)) return;
    const raw = fs.readFileSync(config.publicProfilesFile, 'utf8');
    const decoded = JSON.parse(raw);
    if (!decoded || decoded.v !== 1 || !decoded.profiles) return;

    for (const [userId, profile] of Object.entries(decoded.profiles)) {
      profiles.set(userId, sanitizeProfile(profile));
    }
  } catch (error) {
    audit('Nie wczytano profili publicznych', { error: String(error) });
  }
}

function loadPublicDirectory() {
  try {
    if (!fs.existsSync(config.publicDirectoryFile)) return;
    const raw = fs.readFileSync(config.publicDirectoryFile, 'utf8');
    const decoded = JSON.parse(raw);
    if (!decoded || decoded.v !== 1 || !decoded.users) return;

    for (const [userId, entry] of Object.entries(decoded.users)) {
      if (!entry || typeof entry.identityPublicKey !== 'string') continue;
      publicDirectory.set(userId, {
        v: 1,
        userId,
        displayName: sanitizeDisplayName(entry.displayName, userId),
        identityPublicKey: entry.identityPublicKey,
        updatedAt: entry.updatedAt || new Date().toISOString()
      });
    }
  } catch (error) {
    audit('Nie wczytano publicznej listy uzytkownikow', { error: String(error) });
  }
}

function persistProfiles() {
  try {
    const dir = path.dirname(config.publicProfilesFile);
    fs.mkdirSync(dir, { recursive: true });
    const savedProfiles = {};
    for (const [userId, profile] of profiles.entries()) {
      savedProfiles[userId] = profile;
    }
    fs.writeFileSync(
      config.publicProfilesFile,
      JSON.stringify({ v: 1, savedAt: new Date().toISOString(), profiles: savedProfiles }),
      'utf8'
    );
  } catch (error) {
    audit('Nie zapisano profili publicznych', { error: String(error) });
  }
}

function persistPublicDirectory() {
  try {
    const dir = path.dirname(config.publicDirectoryFile);
    fs.mkdirSync(dir, { recursive: true });
    const users = {};
    for (const [userId, entry] of publicDirectory.entries()) {
      users[userId] = entry;
    }
    fs.writeFileSync(
      config.publicDirectoryFile,
      JSON.stringify({ v: 1, savedAt: new Date().toISOString(), users }),
      'utf8'
    );
  } catch (error) {
    audit('Nie zapisano publicznej listy uzytkownikow', { error: String(error) });
  }
}

function persistOfflineQueues() {
  try {
    const dir = path.dirname(config.offlineQueueFile);
    fs.mkdirSync(dir, { recursive: true });
    const queues = {};
    for (const [userId, items] of offlineQueues.entries()) {
      queues[userId] = items;
    }
    fs.writeFileSync(
      config.offlineQueueFile,
      JSON.stringify({ v: 1, savedAt: new Date().toISOString(), queues }),
      'utf8'
    );
  } catch (error) {
    audit('Nie zapisano kolejki offline', { error: String(error) });
  }
}

function pruneOfflineQueues() {
  const now = Date.now();
  let changed = false;
  for (const [userId, items] of offlineQueues.entries()) {
    const liveItems = items.filter((item) => item.expiresAt > now);
    if (liveItems.length === 0) {
      offlineQueues.delete(userId);
      changed = true;
    } else if (liveItems.length !== items.length) {
      offlineQueues.set(userId, liveItems);
      changed = true;
    }
  }
  if (changed) persistOfflineQueues();
}

function enqueueOffline(to, envelope) {
  pruneOfflineQueues();
  const queue = offlineQueues.get(to) || [];
  queue.push({
    queuedAt: Date.now(),
    expiresAt: Date.now() + config.offlineQueueTtlMs,
    envelope
  });
  while (queue.length > config.offlineQueueMaxPerUser) {
    queue.shift();
  }
  offlineQueues.set(to, queue);
  persistOfflineQueues();
  return true;
}

function flushOfflineQueue(userId) {
  pruneOfflineQueues();
  const queue = offlineQueues.get(userId);
  if (!queue || queue.length === 0) return 0;

  let delivered = 0;
  for (const item of queue) {
    delivered += forwardToUser(userId, {
      ...item.envelope,
      queued: true,
      queuedAt: new Date(item.queuedAt).toISOString()
    });
  }
  offlineQueues.delete(userId);
  persistOfflineQueues();
  return delivered;
}

function sanitizeProfile(profile) {
  return {
    v: 1,
    avatarMimeType: profile.avatarMimeType || null,
    avatarBytes: profile.avatarBytes || null,
    updatedAt: profile.updatedAt || new Date().toISOString()
  };
}

function sanitizeDisplayName(value, fallback) {
  if (typeof value !== 'string') return fallback;
  const trimmed = value.trim().replace(/\s+/g, ' ');
  if (!trimmed) return fallback;
  return trimmed.slice(0, 80);
}

function sendProfileToUser(userId, targetUserId) {
  const profile = profiles.get(targetUserId);
  if (!profile) return;
  forwardToUser(userId, {
    v: 1,
    type: 'profile',
    userId: targetUserId,
    profile
  });
}

function timingSafeTokenEquals(received) {
  const expected = Buffer.from(config.relayToken, 'utf8');
  const actual = Buffer.from(String(received || ''), 'utf8');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function send(ws, message) {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(message));
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store'
  });
  res.end(JSON.stringify(payload));
}

function contentTypeForFile(fileName) {
  const lower = fileName.toLowerCase();
  if (lower.endsWith('.zip')) return 'application/zip';
  if (lower.endsWith('.apk')) return 'application/vnd.android.package-archive';
  if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
  return 'application/octet-stream';
}

function serveUpdateManifest(res) {
  try {
    if (!fs.existsSync(config.updateManifestFile)) {
      sendJson(res, 404, {
        ok: false,
        error: 'Manifest aktualizacji nie jest jeszcze dostepny.'
      });
      return;
    }
    const raw = fs.readFileSync(config.updateManifestFile, 'utf8');
    const parsed = JSON.parse(raw);
    sendJson(res, 200, parsed);
  } catch (error) {
    sendJson(res, 500, {
      ok: false,
      error: 'Nie mozna odczytac manifestu aktualizacji.'
    });
  }
}

function serveUpdateFile(res, fileName) {
  const cleanName = path.basename(fileName || '');
  if (!cleanName || cleanName !== fileName) {
    sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa pliku.' });
    return;
  }

  const baseDir = path.resolve(config.updateFilesDir);
  const filePath = path.resolve(baseDir, cleanName);
  if (!filePath.startsWith(baseDir + path.sep)) {
    sendJson(res, 400, { ok: false, error: 'Niepoprawna sciezka pliku.' });
    return;
  }
  if (!fs.existsSync(filePath)) {
    sendJson(res, 404, { ok: false, error: 'Plik aktualizacji nie istnieje.' });
    return;
  }

  const stat = fs.statSync(filePath);
  res.writeHead(200, {
    'content-type': contentTypeForFile(cleanName),
    'content-length': stat.size,
    'cache-control': 'no-store',
    'content-disposition': `attachment; filename="${cleanName.replaceAll('"', '')}"`
  });
  fs.createReadStream(filePath)
    .on('error', () => res.destroy())
    .pipe(res);
}

function closeWithError(ws, code, reason) {
  try {
    send(ws, { v: 1, type: 'error', code, reason });
    ws.close(code, reason.slice(0, 120));
  } catch {
    ws.terminate();
  }
}

function registerClient(state, ws) {
  const existing = users.get(state.userId) || new Map();
  if (existing.size >= config.maxConnectionsPerUser) {
    closeWithError(ws, 1008, 'Za duzo aktywnych polaczen dla uzytkownika.');
    return false;
  }

  existing.set(state.connectionId, { ws, state });
  users.set(state.userId, existing);
  return true;
}

function unregisterClient(state) {
  if (!state.userId) return;
  const existing = users.get(state.userId);
  if (!existing) return;
  existing.delete(state.connectionId);
  if (existing.size === 0) users.delete(state.userId);
}

function forwardToUser(to, envelope) {
  const recipients = users.get(to);
  if (!recipients || recipients.size === 0) {
    return 0;
  }

  let delivered = 0;
  for (const { ws } of recipients.values()) {
    if (ws.readyState === WebSocket.OPEN) {
      send(ws, envelope);
      delivered += 1;
    }
  }
  return delivered;
}

function handleHello(ws, state, message) {
  const error = validateHello(message);
  if (error) {
    closeWithError(ws, 1008, error);
    return;
  }

  if (!timingSafeTokenEquals(message.relayToken)) {
    audit('Nieudana autoryzacja relay', { userId: message.userId });
    closeWithError(ws, 1008, 'Niepoprawna autoryzacja.');
    return;
  }

  state.authenticated = true;
  state.userId = message.userId;
  state.deviceId = message.deviceId;
  state.identityPublicKey = message.identityPublicKey;

  if (!registerClient(state, ws)) return;

  audit('Polaczono klienta', { userId: state.userId, deviceId: state.deviceId });
  send(ws, {
    v: 1,
    type: 'hello_ok',
    connectionId: state.connectionId,
    serverTime: new Date().toISOString(),
    maxPayloadBytes: config.maxPayloadBytes
  });
  const flushed = flushOfflineQueue(state.userId);
  if (flushed > 0) {
    audit('Dostarczono kolejke offline', { userId: state.userId, delivered: flushed });
  }
}

function handleRelay(ws, state, message) {
  const error = validateRelay(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_relay', reason: error });
    return;
  }

  const envelope = {
    v: 1,
    type: 'deliver',
    kind: 'relay',
    id: message.id,
    from: state.userId,
    to: message.to,
    sentAt: new Date().toISOString(),
    payload: message.payload
  };

  const deliveredConnections = forwardToUser(message.to, envelope);
  const queued = deliveredConnections === 0 ? enqueueOffline(message.to, envelope) : false;
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'relay',
    deliveredConnections,
    queued
  });
}

function handleSignal(ws, state, message) {
  const error = validateSignal(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_signal', reason: error });
    return;
  }

  const envelope = {
    v: 1,
    type: 'deliver',
    kind: 'signal',
    id: message.id,
    from: state.userId,
    to: message.to,
    signalType: message.signalType,
    sentAt: new Date().toISOString(),
    payload: message.payload
  };

  const deliveredConnections = forwardToUser(message.to, envelope);
  const canQueueSignal =
    message.signalType === 'crypto-handshake-init' ||
    message.signalType === 'crypto-handshake-accept';
  const queued =
    deliveredConnections === 0 && canQueueSignal ? enqueueOffline(message.to, envelope) : false;
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'signal',
    deliveredConnections,
    queued
  });
}

function handlePresenceQuery(ws, message) {
  const error = validatePresenceQuery(message);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_presence', reason: error });
    return;
  }

  const result = {};
  for (const contact of message.contacts) {
    result[contact] = users.has(contact);
  }

  send(ws, {
    v: 1,
    type: 'presence',
    contacts: result,
    serverTime: new Date().toISOString()
  });
}

function directoryEntriesFor(requestingUserId) {
  return Array.from(publicDirectory.values())
    .filter((entry) => entry.userId !== requestingUserId)
    .sort((left, right) => left.displayName.localeCompare(right.displayName))
    .map((entry) => ({
      ...entry,
      online: users.has(entry.userId)
    }));
}

function handleDirectoryUpdate(ws, state, message) {
  const error = validateDirectoryUpdate(message);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_directory_update', reason: error });
    return;
  }

  if (!message.enabled) {
    publicDirectory.delete(state.userId);
    persistPublicDirectory();
    send(ws, { v: 1, type: 'directory_updated', enabled: false });
    return;
  }

  publicDirectory.set(state.userId, {
    v: 1,
    userId: state.userId,
    displayName: sanitizeDisplayName(message.displayName, state.userId),
    identityPublicKey: state.identityPublicKey,
    updatedAt: new Date().toISOString()
  });
  persistPublicDirectory();
  send(ws, { v: 1, type: 'directory_updated', enabled: true });
}

function handleDirectoryQuery(ws, state, message) {
  const error = validateDirectoryQuery(message);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_directory_query', reason: error });
    return;
  }
  send(ws, {
    v: 1,
    type: 'directory',
    entries: directoryEntriesFor(state.userId)
  });
}

function handleContactRequest(ws, state, message) {
  const error = validateContactRequest(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_contact_request', reason: error });
    return;
  }

  const envelope = {
    v: 1,
    type: 'deliver',
    kind: 'contact_request',
    id: message.id,
    from: state.userId,
    to: message.to,
    sentAt: new Date().toISOString(),
    payload: {
      v: 1,
      displayName: sanitizeDisplayName(message.displayName, state.userId),
      identityPublicKey: state.identityPublicKey
    }
  };

  const deliveredConnections = forwardToUser(message.to, envelope);
  const queued = deliveredConnections === 0 ? enqueueOffline(message.to, envelope) : false;
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'contact_request',
    deliveredConnections,
    queued
  });
}

function handleProfileUpdate(ws, state, message) {
  const error = validateProfileUpdate(message, config.profileAvatarMaxBytes);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_profile', reason: error });
    return;
  }

  const profile = sanitizeProfile(message.profile);
  profiles.set(state.userId, profile);
  persistProfiles();
  audit('Zaktualizowano profil publiczny', { userId: state.userId });

  for (const [userId] of users.entries()) {
    if (userId !== state.userId) {
      sendProfileToUser(userId, state.userId);
    }
  }
}

function handleProfileQuery(ws, message) {
  const error = validateProfileQuery(message);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_profile_query', reason: error });
    return;
  }

  const result = {};
  for (const contact of message.contacts) {
    const profile = profiles.get(contact);
    if (profile) result[contact] = profile;
  }

  send(ws, {
    v: 1,
    type: 'profiles',
    profiles: result,
    serverTime: new Date().toISOString()
  });
}

const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname === '/healthz') {
    sendJson(res, 200, { ok: true, time: new Date().toISOString() });
    return;
  }

  if (url.pathname === '/updates/manifest.json' || url.pathname === '/update/manifest') {
    serveUpdateManifest(res);
    return;
  }

  if (url.pathname.startsWith('/updates/files/')) {
    let fileName;
    try {
      fileName = decodeURIComponent(url.pathname.slice('/updates/files/'.length));
    } catch {
      sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa pliku.' });
      return;
    }
    serveUpdateFile(res, fileName);
    return;
  }

  res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: config.maxPayloadBytes,
  perMessageDeflate: false
});

wss.on('connection', (ws, request) => {
  const state = {
    authenticated: false,
    connectionId: crypto.randomUUID(),
    userId: null,
    deviceId: null,
    identityPublicKey: null,
    limiter: new SlidingWindowRateLimiter(config.rateLimitMessages, config.rateLimitWindowMs),
    remoteAddress: request.socket.remoteAddress
  };

  ws.on('message', (raw, isBinary) => {
    if (!state.limiter.allow()) {
      closeWithError(ws, 1008, 'Przekroczono limit liczby pakietow.');
      return;
    }

    if (isBinary) {
      closeWithError(ws, 1003, 'Serwer przyjmuje tylko JSON tekstowy.');
      return;
    }

    const parsed = safeJsonParse(raw.toString('utf8'));
    if (!parsed.ok) {
      closeWithError(ws, 1007, parsed.error);
      return;
    }

    const message = parsed.value;
    if (!state.authenticated) {
      handleHello(ws, state, message);
      return;
    }

    switch (message.type) {
      case 'relay':
        handleRelay(ws, state, message);
        break;
      case 'signal':
        handleSignal(ws, state, message);
        break;
      case 'presence_query':
        handlePresenceQuery(ws, message);
        break;
      case 'directory_update':
        handleDirectoryUpdate(ws, state, message);
        break;
      case 'directory_query':
        handleDirectoryQuery(ws, state, message);
        break;
      case 'contact_request':
        handleContactRequest(ws, state, message);
        break;
      case 'profile_update':
        handleProfileUpdate(ws, state, message);
        break;
      case 'profile_query':
        handleProfileQuery(ws, message);
        break;
      case 'ping':
        send(ws, { v: 1, type: 'pong', serverTime: new Date().toISOString() });
        break;
      default:
        send(ws, { v: 1, type: 'error', code: 'unknown_type', reason: 'Nieznany typ pakietu.' });
    }
  });

  ws.on('close', () => {
    unregisterClient(state);
    audit('Rozlaczono klienta', { userId: state.userId, deviceId: state.deviceId });
  });

  ws.on('error', () => {
    unregisterClient(state);
  });
});

const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.ping();
    }
  }
}, 30_000);

const offlineQueueMaintenance = setInterval(() => {
  pruneOfflineQueues();
}, 60_000);

function shutdown(signal) {
  audit('Zamykanie serwera', { signal });
  clearInterval(heartbeat);
  clearInterval(offlineQueueMaintenance);
  persistOfflineQueues();
  persistProfiles();
  for (const client of wss.clients) {
    client.close(1001, 'Server shutdown');
  }
  httpServer.close(() => process.exit(0));
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

httpServer.listen(config.port, config.host, () => {
  console.info(`Secure relay listening on ${config.host}:${config.port}`);
});
