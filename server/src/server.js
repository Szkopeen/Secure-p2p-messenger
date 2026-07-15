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
import { V2Store, handleV2Http, handleV2WebSocket } from './v2Store.js';

const SAFE_USER_ID = /^[a-zA-Z0-9_.:@-]{3,128}$/;

const users = new Map();
const knownUsers = new Map();
const profiles = new Map();
const offlineQueues = new Map();
const publicDirectory = new Map();
const bannedUsers = new Set();
const v2Store = new V2Store({ dataDir: config.v2DataDir });

loadKnownUsers();
loadProfiles();
loadOfflineQueues();
loadPublicDirectory();
loadBannedUsers();

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

function timingSafeSecretEquals(received, expectedSecret) {
  const expected = Buffer.from(expectedSecret, 'utf8');
  const actual = Buffer.from(String(received || ''), 'utf8');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function timingSafeTokenEquals(received) {
  return timingSafeSecretEquals(received, config.relayToken);
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

function forwardToUser(to, envelope, options = {}) {
  const recipients = users.get(to);
  if (!recipients || recipients.size === 0) {
    return { deliveredConnections: 0, deliveredDeviceIds: [] };
  }

  let deliveredConnections = 0;
  const deliveredDeviceIds = new Set();
  for (const { ws, state } of recipients.values()) {
    if (options.excludeConnectionId && state.connectionId === options.excludeConnectionId) {
      continue;
    }
    if (ws.readyState === WebSocket.OPEN) {
      send(ws, envelope);
      deliveredConnections += 1;
      if (state.deviceId) deliveredDeviceIds.add(state.deviceId);
    }
  }
  return {
    deliveredConnections,
    deliveredDeviceIds: Array.from(deliveredDeviceIds)
  };
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

  if (isBannedUser(message.userId)) {
    audit('Odrzucono zablokowanego uzytkownika', { userId: message.userId });
    closeWithError(ws, 1008, 'Konto jest zablokowane na tym relay.');
    return;
  }

  state.authenticated = true;
  state.userId = message.userId;
  state.deviceId = message.deviceId;
  state.identityPublicKey = message.identityPublicKey;

  if (!registerClient(state, ws)) return;
  rememberKnownUser(state);

  audit('Polaczono klienta', { userId: state.userId, deviceId: state.deviceId });
  send(ws, {
    v: 1,
    type: 'hello_ok',
    connectionId: state.connectionId,
    serverTime: new Date().toISOString(),
    maxPayloadBytes: config.maxPayloadBytes
  });
  const flushed = flushOfflineQueue(state, ws);
  if (flushed > 0) {
    audit('Dostarczono kolejke offline', { userId: state.userId, delivered: flushed });
  }
}

function handleRelay(ws, state, message) {
  const error = validateRelay(message, state.userId);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_relay', reason: error });
    return;
  }

  if (isBannedUser(message.to)) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'recipient_banned', reason: 'Adresat jest zablokowany.' });
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

  const ownDeviceRelay = message.to === state.userId;
  const delivery = forwardToUser(message.to, envelope, {
    excludeConnectionId: ownDeviceRelay ? state.connectionId : null
  });
  const deliveredDeviceIds = ownDeviceRelay
    ? Array.from(new Set([state.deviceId, ...delivery.deliveredDeviceIds]))
    : delivery.deliveredDeviceIds;
  const queued = enqueueOffline(message.to, envelope, deliveredDeviceIds);
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'relay',
    deliveredConnections: delivery.deliveredConnections,
    queued
  });
}

function handleSignal(ws, state, message) {
  const error = validateSignal(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_signal', reason: error });
    return;
  }

  if (isBannedUser(message.to)) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'recipient_banned', reason: 'Adresat jest zablokowany.' });
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

  const delivery = forwardToUser(message.to, envelope);
  const canQueueSignal =
    message.signalType === 'crypto-handshake-init' ||
    message.signalType === 'crypto-handshake-accept';
  const queued =
    delivery.deliveredConnections === 0 && canQueueSignal
      ? enqueueOffline(message.to, envelope, delivery.deliveredDeviceIds)
      : false;
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'signal',
    deliveredConnections: delivery.deliveredConnections,
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
    .filter((entry) => entry.userId !== requestingUserId && !isBannedUser(entry.userId))
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

  if (isBannedUser(message.to)) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'recipient_banned', reason: 'Adresat jest zablokowany.' });
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

  const delivery = forwardToUser(message.to, envelope);
  const queued = enqueueOffline(message.to, envelope, delivery.deliveredDeviceIds);
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'contact_request',
    deliveredConnections: delivery.deliveredConnections,
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

  // Protokol v1 ze wspolnym RELAY_TOKEN jest bezwarunkowo wylaczony.
  ws.close(1008, 'Legacy relay zostal usuniety. Uzyj /v2/ws.');
  return;

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
