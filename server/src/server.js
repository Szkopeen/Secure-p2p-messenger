import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { WebSocketServer, WebSocket } from 'ws';
import { config } from './config.js';
import { V2Store, handleV2Http, handleV2WebSocket } from './v2Store.js';

const SAFE_USER_ID = /^[a-zA-Z0-9_.:@-]{3,128}$/;

const users = new Map();
const knownUsers = new Map();
const profiles = new Map();
const offlineQueues = new Map();
const publicDirectory = new Map();
const bannedUsers = new Set();
const v2Store = new V2Store({ dataDir: config.v2DataDir });

function clientIp(req) {
  const remote = req.socket.remoteAddress || '';
  if (!config.trustedProxies.includes(remote)) return remote;
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded !== 'string') return remote;
  const first = forwarded.split(',')[0].trim();
  return /^[0-9a-fA-F:.]+$/.test(first) ? first : remote;
}

loadKnownUsers();
loadProfiles();
loadOfflineQueues();
loadPublicDirectory();
loadBannedUsers();

function audit(message, fields = {}) {
  if (!config.securityLogs) return;
  const safeFields = { ...fields };
  delete safeFields.payload;
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
      const liveItems = items
        .map((item) => normalizeQueueItem(item))
        .filter((item) => item && item.expiresAt > now);
      if (liveItems.length > 0) offlineQueues.set(userId, liveItems);
    }
  } catch (error) {
    audit('Nie wczytano kolejki offline', { error: String(error) });
  }
}

function loadKnownUsers() {
  try {
    knownUsers.clear();
    if (!fs.existsSync(config.knownUsersFile)) return;
    const raw = fs.readFileSync(config.knownUsersFile, 'utf8');
    const decoded = JSON.parse(raw);
    if (!decoded || decoded.v !== 1 || !decoded.users) return;

    for (const [userId, entry] of Object.entries(decoded.users)) {
      if (!entry || typeof entry.identityPublicKey !== 'string') continue;
      const nowIso = new Date().toISOString();
      const devices = normalizeKnownDevices(entry, nowIso);
      knownUsers.set(userId, {
        v: 1,
        userId,
        identityPublicKey: entry.identityPublicKey,
        firstSeenAt: entry.firstSeenAt || entry.lastSeenAt || nowIso,
        lastSeenAt: entry.lastSeenAt || nowIso,
        lastDeviceId: typeof entry.lastDeviceId === 'string' ? entry.lastDeviceId : null,
        devices
      });
    }
  } catch (error) {
    audit('Nie wczytano znanych uzytkownikow', { error: String(error) });
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

function loadBannedUsers() {
  try {
    bannedUsers.clear();
    if (!fs.existsSync(config.bannedUsersFile)) return;
    const raw = fs.readFileSync(config.bannedUsersFile, 'utf8');
    const decoded = JSON.parse(raw);
    if (!decoded || decoded.v !== 1 || !Array.isArray(decoded.users)) return;

    for (const userId of decoded.users) {
      if (typeof userId === 'string') bannedUsers.add(userId);
    }
  } catch (error) {
    audit('Nie wczytano listy zablokowanych uzytkownikow', { error: String(error) });
  }
}

function persistKnownUsers() {
  try {
    const dir = path.dirname(config.knownUsersFile);
    fs.mkdirSync(dir, { recursive: true });
    const savedUsers = {};
    for (const [userId, entry] of knownUsers.entries()) {
      savedUsers[userId] = entry;
    }
    fs.writeFileSync(
      config.knownUsersFile,
      JSON.stringify({ v: 1, savedAt: new Date().toISOString(), users: savedUsers }),
      'utf8'
    );
  } catch (error) {
    audit('Nie zapisano znanych uzytkownikow', { error: String(error) });
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

function persistBannedUsers() {
  try {
    const dir = path.dirname(config.bannedUsersFile);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      config.bannedUsersFile,
      JSON.stringify({
        v: 1,
        savedAt: new Date().toISOString(),
        users: Array.from(bannedUsers).sort((left, right) => left.localeCompare(right))
      }),
      'utf8'
    );
  } catch (error) {
    audit('Nie zapisano banlisty', { error: String(error) });
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

function rememberKnownUser(state) {
  const nowIso = new Date().toISOString();
  const existing = knownUsers.get(state.userId);
  const devices = normalizeKnownDevices(existing, nowIso);
  const previousDevice = devices[state.deviceId] || {};
  devices[state.deviceId] = {
    firstSeenAt: previousDevice.firstSeenAt || nowIso,
    lastSeenAt: nowIso
  };
  knownUsers.set(state.userId, {
    v: 1,
    userId: state.userId,
    identityPublicKey: state.identityPublicKey,
    firstSeenAt: existing?.firstSeenAt || nowIso,
    lastSeenAt: nowIso,
    lastDeviceId: state.deviceId,
    devices
  });
  persistKnownUsers();
}

function normalizeKnownDevices(entry, fallbackIso) {
  const devices = {};
  if (entry?.devices && typeof entry.devices === 'object') {
    for (const [deviceId, value] of Object.entries(entry.devices)) {
      if (typeof deviceId !== 'string' || deviceId.length === 0) continue;
      const firstSeenAt = typeof value?.firstSeenAt === 'string'
        ? value.firstSeenAt
        : fallbackIso;
      const lastSeenAt = typeof value?.lastSeenAt === 'string'
        ? value.lastSeenAt
        : firstSeenAt;
      devices[deviceId] = { firstSeenAt, lastSeenAt };
    }
  }

  if (typeof entry?.lastDeviceId === 'string' && entry.lastDeviceId.length > 0) {
    devices[entry.lastDeviceId] ||= {
      firstSeenAt: entry.firstSeenAt || entry.lastSeenAt || fallbackIso,
      lastSeenAt: entry.lastSeenAt || fallbackIso
    };
  }
  return devices;
}

function knownDeviceIds(userId) {
  return Object.keys(knownUsers.get(userId)?.devices || {});
}

function normalizeQueueItem(item) {
  const envelope = envelopeForQueueItem(item);
  if (!envelope) return null;
  const now = Date.now();
  const queuedAt = Number.isFinite(item?.queuedAt) ? item.queuedAt : now;
  const expiresAt = Number.isFinite(item?.expiresAt)
    ? item.expiresAt
    : queuedAt + config.offlineQueueTtlMs;
  const deliveredDeviceIds = Array.isArray(item?.deliveredDeviceIds)
    ? Array.from(new Set(item.deliveredDeviceIds.filter((id) => typeof id === 'string' && id.length > 0)))
    : [];

  return {
    queuedAt,
    expiresAt,
    deliveredDeviceIds,
    envelope
  };
}

function pruneOfflineQueues() {
  const now = Date.now();
  let changed = false;
  for (const [userId, items] of offlineQueues.entries()) {
    const liveItems = items.filter((item) =>
      item.expiresAt > now && !isQueueItemComplete(userId, item));
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

function isQueueItemComplete(userId, item) {
  const devices = knownDeviceIds(userId);
  if (devices.length === 0) return false;
  const delivered = new Set(item.deliveredDeviceIds || []);
  return devices.every((deviceId) => delivered.has(deviceId));
}

function shouldQueueForMissingDevices(userId, deliveredDeviceIds) {
  const devices = knownDeviceIds(userId);
  if (devices.length === 0) return deliveredDeviceIds.length === 0;
  const delivered = new Set(deliveredDeviceIds);
  return devices.some((deviceId) => !delivered.has(deviceId));
}

function enqueueOffline(to, envelope, deliveredDeviceIds = []) {
  const delivered = Array.from(new Set(deliveredDeviceIds));
  if (!shouldQueueForMissingDevices(to, delivered)) return false;
  pruneOfflineQueues();
  const queue = offlineQueues.get(to) || [];
  queue.push({
    queuedAt: Date.now(),
    expiresAt: Date.now() + config.offlineQueueTtlMs,
    deliveredDeviceIds: delivered,
    envelope
  });
  while (queue.length > config.offlineQueueMaxPerUser) {
    queue.shift();
  }
  offlineQueues.set(to, queue);
  persistOfflineQueues();
  return true;
}

function flushOfflineQueue(state, ws) {
  pruneOfflineQueues();
  const userId = state.userId;
  const queue = offlineQueues.get(userId);
  if (!queue || queue.length === 0) return 0;

  let delivered = 0;
  const remaining = [];
  for (const item of queue) {
    const deliveredDevices = new Set(item.deliveredDeviceIds || []);
    if (!deliveredDevices.has(state.deviceId) && ws.readyState === WebSocket.OPEN) {
      send(ws, {
        ...item.envelope,
        queued: true,
        queuedAt: new Date(item.queuedAt).toISOString()
      });
      deliveredDevices.add(state.deviceId);
      item.deliveredDeviceIds = Array.from(deliveredDevices);
      delivered += 1;
    }

    if (!isQueueItemComplete(userId, item)) {
      remaining.push(item);
    }
  }

  if (remaining.length === 0) {
    offlineQueues.delete(userId);
  } else {
    offlineQueues.set(userId, remaining);
  }
  persistOfflineQueues();
  return delivered;
}

function isBannedUser(userId) {
  return bannedUsers.has(userId);
}

function envelopeForQueueItem(item) {
  if (!item || typeof item !== 'object') return null;
  if (item.envelope && typeof item.envelope === 'object') return item.envelope;
  return item;
}

function collectAdminUserIds() {
  const ids = new Set();
  for (const userId of knownUsers.keys()) ids.add(userId);
  for (const userId of profiles.keys()) ids.add(userId);
  for (const userId of publicDirectory.keys()) ids.add(userId);
  for (const userId of offlineQueues.keys()) ids.add(userId);
  for (const userId of bannedUsers.values()) ids.add(userId);
  for (const items of offlineQueues.values()) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = envelopeForQueueItem(item);
      if (typeof envelope?.from === 'string') ids.add(envelope.from);
      if (typeof envelope?.to === 'string') ids.add(envelope.to);
    }
  }
  return Array.from(ids).sort((left, right) => left.localeCompare(right));
}

function adminUserSummary(userId) {
  const known = knownUsers.get(userId) || null;
  const profile = profiles.get(userId) || null;
  const directory = publicDirectory.get(userId) || null;
  const activeConnections = users.get(userId)?.size || 0;
  const devices = knownDeviceIds(userId);
  const queuedIn = offlineQueues.get(userId)?.length || 0;
  let queuedOut = 0;
  for (const items of offlineQueues.values()) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = envelopeForQueueItem(item);
      if (envelope?.from === userId) queuedOut += 1;
    }
  }

  return {
    userId,
    displayName: directory?.displayName || null,
    known: Boolean(known),
    directory: Boolean(directory),
    profile: Boolean(profile),
    banned: bannedUsers.has(userId),
    online: activeConnections > 0,
    activeConnections,
    queuedIn,
    queuedOut,
    deviceCount: devices.length,
    devices,
    firstSeenAt: known?.firstSeenAt || null,
    lastSeenAt: known?.lastSeenAt || null,
    lastDeviceId: known?.lastDeviceId || null,
    identityPublicKey: known?.identityPublicKey || directory?.identityPublicKey || null
  };
}

function closeUserConnections(userId, reason) {
  const active = users.get(userId);
  if (!active) return 0;
  let closed = 0;
  for (const { ws } of active.values()) {
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      try {
        ws.close(1008, reason);
      } catch {
        ws.terminate();
      }
      closed += 1;
    }
  }
  users.delete(userId);
  return closed;
}

function validateAdminUserId(userId) {
  return typeof userId === 'string' && SAFE_USER_ID.test(userId);
}

function deleteAdminUser(userId, { ban }) {
  const changed = [];
  if (knownUsers.delete(userId)) {
    persistKnownUsers();
    changed.push('knownUsers');
  }
  if (profiles.delete(userId)) {
    persistProfiles();
    changed.push('profiles');
  }
  if (publicDirectory.delete(userId)) {
    persistPublicDirectory();
    changed.push('directory');
  }

  let queueChanged = false;
  if (offlineQueues.delete(userId)) queueChanged = true;
  for (const [queueOwner, items] of offlineQueues.entries()) {
    if (!Array.isArray(items)) continue;
    const filtered = items.filter((item) => {
      const envelope = envelopeForQueueItem(item);
      return envelope?.from !== userId && envelope?.to !== userId;
    });
    if (filtered.length !== items.length) {
      if (filtered.length === 0) offlineQueues.delete(queueOwner);
      else offlineQueues.set(queueOwner, filtered);
      queueChanged = true;
    }
  }
  if (queueChanged) {
    persistOfflineQueues();
    changed.push('offlineQueues');
  }

  const closedConnections = closeUserConnections(userId, 'Konto zostalo usuniete z relay.');
  if (ban && !bannedUsers.has(userId)) {
    bannedUsers.add(userId);
    persistBannedUsers();
    changed.push('bannedUsers');
  }

  return {
    userId,
    changed,
    banned: bannedUsers.has(userId),
    closedConnections
  };
}

function banAdminUser(userId) {
  const alreadyBanned = bannedUsers.has(userId);
  if (!alreadyBanned) {
    bannedUsers.add(userId);
    persistBannedUsers();
  }
  const closedConnections = closeUserConnections(userId, 'Konto zostalo zablokowane na tym relay.');
  return {
    userId,
    changed: alreadyBanned ? [] : ['bannedUsers'],
    banned: true,
    closedConnections
  };
}

function unbanAdminUser(userId) {
  const changed = bannedUsers.delete(userId);
  if (changed) persistBannedUsers();
  return {
    userId,
    changed: changed ? ['bannedUsers'] : [],
    banned: false,
    closedConnections: 0
  };
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

function timingSafeSecretEquals(received, expectedSecret) {
  const expected = Buffer.from(expectedSecret, 'utf8');
  const actual = Buffer.from(String(received || ''), 'utf8');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function adminTokenFromRequest(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') return '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1] : '';
}

function isAuthorizedAdminRequest(req) {
  return Boolean(config.adminToken) &&
    timingSafeSecretEquals(adminTokenFromRequest(req), config.adminToken);
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

function sendAdminError(res, status, error) {
  sendJson(res, status, { ok: false, error });
}

function parseAdminBoolean(value, fallback) {
  if (value === null || value === undefined || value === '') return fallback;
  return ['1', 'true', 'yes', 'tak'].includes(String(value).toLowerCase());
}

function handleAdminRequest(req, res, url) {
  if (!config.adminToken) {
    sendAdminError(res, 503, 'Panel administratora nie jest wlaczony na relay. Ustaw ADMIN_TOKEN.');
    return;
  }

  if (!isAuthorizedAdminRequest(req)) {
    sendAdminError(res, 401, 'Brak autoryzacji administratora.');
    return;
  }

  const parts = url.pathname.split('/').filter(Boolean);
  const method = req.method || 'GET';

  if (method === 'GET' && parts.length === 2 && parts[0] === 'admin' && parts[1] === 'health') {
    sendJson(res, 200, {
      ok: true,
      serverTime: new Date().toISOString(),
      onlineUsers: users.size,
      knownUsers: knownUsers.size,
      queuedUsers: offlineQueues.size,
      bannedUsers: bannedUsers.size
    });
    return;
  }

  if (parts[0] !== 'admin' || parts[1] !== 'users') {
    sendAdminError(res, 404, 'Nieznany endpoint administratora.');
    return;
  }

  if (method === 'GET' && parts.length === 2) {
    const summaries = collectAdminUserIds().map((userId) => adminUserSummary(userId));
    sendJson(res, 200, {
      ok: true,
      serverTime: new Date().toISOString(),
      counts: {
        users: summaries.length,
        onlineUsers: summaries.filter((user) => user.online).length,
        bannedUsers: summaries.filter((user) => user.banned).length,
        queuedUsers: summaries.filter((user) => user.queuedIn > 0).length
      },
      users: summaries
    });
    return;
  }

  let userId = '';
  try {
    userId = decodeURIComponent(parts[2] || '');
  } catch {
    sendAdminError(res, 400, 'Niepoprawny userId.');
    return;
  }

  if (!validateAdminUserId(userId)) {
    sendAdminError(res, 400, 'Niepoprawny userId.');
    return;
  }

  if (method === 'GET' && parts.length === 3) {
    sendJson(res, 200, {
      ok: true,
      user: adminUserSummary(userId)
    });
    return;
  }

  if (method === 'POST' && parts.length === 4 && parts[3] === 'ban') {
    sendJson(res, 200, {
      ok: true,
      result: banAdminUser(userId),
      user: adminUserSummary(userId)
    });
    return;
  }

  if (method === 'POST' && parts.length === 4 && parts[3] === 'unban') {
    sendJson(res, 200, {
      ok: true,
      result: unbanAdminUser(userId),
      user: adminUserSummary(userId)
    });
    return;
  }

  const isDeleteRoute =
    (method === 'DELETE' && parts.length === 3) ||
    (method === 'POST' && parts.length === 4 && parts[3] === 'delete');
  if (isDeleteRoute) {
    const ban = parseAdminBoolean(url.searchParams.get('ban'), true);
    const result = deleteAdminUser(userId, { ban });
    sendJson(res, 200, {
      ok: true,
      result,
      user: adminUserSummary(userId)
    });
    return;
  }

  sendAdminError(res, 405, 'Nieobslugiwana operacja administratora.');
}

const httpServer = http.createServer((req, res) => {
  req.clientIp = clientIp(req);
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname === '/healthz') {
    sendJson(res, 200, { ok: true, time: new Date().toISOString() });
    return;
  }

  if (url.pathname === '/v2' || url.pathname.startsWith('/v2/')) {
    handleV2Http(v2Store, req, res, url, { registrationMode: config.registrationMode });
    return;
  }

  if (url.pathname === '/admin' || url.pathname.startsWith('/admin/')) {
    handleAdminRequest(req, res, url);
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
httpServer.headersTimeout = 10_000;
httpServer.requestTimeout = 30_000;
httpServer.keepAliveTimeout = 5_000;

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: config.maxPayloadBytes,
  perMessageDeflate: false
});

wss.on('connection', (ws, request) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  const requestUrl = new URL(request.url || '/', 'http://127.0.0.1');
  if (requestUrl.pathname === '/v2/ws') {
    handleV2WebSocket(v2Store, ws, request);
    return;
  }

  ws.close(1008, 'Legacy relay zostal usuniety. Uzyj /v2/ws.');
});

const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      if (client.isAlive === false) {
        client.terminate();
        continue;
      }
      client.isAlive = false;
      client.ping();
    }
  }
}, 30_000);

const offlineQueueMaintenance = setInterval(() => {
  loadBannedUsers();
  pruneOfflineQueues();
}, 60_000);

function shutdown(signal) {
  audit('Zamykanie serwera', { signal });
  clearInterval(heartbeat);
  clearInterval(offlineQueueMaintenance);
  persistOfflineQueues();
  persistKnownUsers();
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
