import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { SqliteStateStore } from './sqliteStore.js';

const SAFE_ID = /^[a-zA-Z0-9_.:@-]{3,64}$/;
const DEFAULT_MAX_BODY_BYTES = 1024 * 1024;
const AUTH_MAX_BODY_BYTES = 32 * 1024;
const MAX_MESSAGE_PAGE = 500;
const DEFAULT_MESSAGE_PAGE = 100;
const MAX_MEMBER_KEY_BYTES = 16 * 1024;
const MAX_STORED_MESSAGE_BYTES = 1024 * 1024;
const MAX_MESSAGES_PER_CONVERSATION = 100_000;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const WS_TICKET_TTL_MS = 30 * 1000;
const WS_TICKET_MAX_GLOBAL = 10_000;
const WS_TICKET_MAX_PER_SESSION = 4;
const WS_TICKET_WINDOW_MS = 60 * 1000;
const WS_TICKET_MAX_PER_WINDOW = 30;
const AUTH_WINDOW_MS = 60 * 1000;
const AUTH_MAX_ATTEMPTS = 10;
const AUTH_MAX_KEYS = 5000;
const PENDING_LOGIN_TTL_MS = 2 * 60 * 1000;
const PENDING_LOGIN_MAX_GLOBAL = 5000;
const MAX_CONCURRENT_KDF = 4;
const LAST_SEEN_WRITE_INTERVAL_MS = 10 * 60 * 1000;
const authAttempts = new Map();
let activeKdfOperations = 0;
const kdfWaiters = [];

function nowIso() {
  return new Date().toISOString();
}

function randomId() {
  return crypto.randomUUID();
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isValidIdentityRotationProof(value) {
  return isObject(value) &&
    Number.isInteger(value.rotationEpoch) &&
    value.rotationEpoch >= 1 &&
    typeof value.previousRotationHash === 'string' &&
    typeof value.oldIdentityPublicKey === 'string' &&
    value.oldIdentityPublicKey.length >= 16 &&
    typeof value.newIdentityPublicKey === 'string' &&
    value.newIdentityPublicKey.length >= 16 &&
    typeof value.newKeyAgreementPublicKey === 'string' &&
    value.newKeyAgreementPublicKey.length >= 16 &&
    typeof value.signature === 'string' &&
    value.signature.length >= 16 &&
    typeof value.newIdentityConfirmationSignature === 'string' &&
    value.newIdentityConfirmationSignature.length >= 16 &&
    typeof value.rotatedAt === 'string' &&
    value.rotatedAt.length >= 16;
}

function isValidDeviceCertificate(value) {
  return isObject(value) &&
    value.v === 1 &&
    typeof value.accountId === 'string' &&
    value.accountId.length >= 16 &&
    typeof value.serverOrigin === 'string' &&
    value.serverOrigin.length >= 8 &&
    typeof value.deviceId === 'string' &&
    value.deviceId.length >= 8 &&
    typeof value.deviceSigningPublicKey === 'string' &&
    value.deviceSigningPublicKey.length >= 16 &&
    Number.isInteger(value.deviceEpoch) &&
    value.deviceEpoch >= 1 &&
    typeof value.createdAt === 'string' &&
    value.createdAt.length >= 16 &&
    typeof value.signature === 'string' &&
    value.signature.length >= 16;
}

function isValidDeviceList(value) {
  if (!isObject(value) ||
      value.v !== 1 ||
      (value.protocol !== undefined && value.protocol !== 'secure-chat/device-list/v1') ||
      typeof value.accountId !== 'string' ||
      value.accountId.length < 16 ||
      typeof value.serverOrigin !== 'string' ||
      value.serverOrigin.length < 8 ||
      !Number.isInteger(value.deviceListEpoch) ||
      value.deviceListEpoch < 1 ||
      typeof value.previousDeviceListHash !== 'string' ||
      !Number.isInteger(value.identityRotationEpoch) ||
      value.identityRotationEpoch < 0 ||
      !Array.isArray(value.devices) ||
      !Array.isArray(value.revokedDevices) ||
      typeof value.signature !== 'string' ||
      value.signature.length < 16 ||
      typeof value.updatedAt !== 'string') {
    return false;
  }
  for (const device of value.devices) {
    if (!isObject(device) ||
        typeof device.deviceId !== 'string' ||
        device.deviceId.length < 8 ||
        typeof device.deviceSigningPublicKey !== 'string' ||
        device.deviceSigningPublicKey.length < 16 ||
        typeof device.certificateHash !== 'string' ||
        device.certificateHash.length < 16 ||
        typeof device.addedAt !== 'string' ||
        !Number.isInteger(device.deviceEpoch) ||
        device.deviceEpoch < 1) {
      return false;
    }
  }
  for (const device of value.revokedDevices) {
    if (!isObject(device) ||
        typeof device.deviceId !== 'string' ||
        device.deviceId.length < 8 ||
        (device.deviceSigningPublicKey !== undefined &&
          typeof device.deviceSigningPublicKey !== 'string') ||
        (device.deviceCertificateHash !== undefined &&
          typeof device.deviceCertificateHash !== 'string') ||
        !Number.isInteger(device.revokedDeviceEpoch) ||
        device.revokedDeviceEpoch < 1 ||
        typeof device.revokedAt !== 'string' ||
        typeof device.reasonCode !== 'string') {
      return false;
    }
  }
  const activeIds = new Set(value.devices.map((device) => device.deviceId));
  for (const device of value.revokedDevices) {
    if (activeIds.has(device.deviceId)) return false;
  }
  return true;
}

function revokedDeviceIds(user) {
  if (!isValidDeviceList(user?.deviceList)) return new Set();
  return new Set(user.deviceList.revokedDevices.map((device) => device.deviceId));
}

function activeDeviceEntry(user, deviceId) {
  if (!isValidDeviceList(user?.deviceList)) return null;
  return user.deviceList.devices.find((device) => device.deviceId === deviceId) || null;
}

function isDeviceRevoked(user, deviceId) {
  return revokedDeviceIds(user).has(deviceId);
}

function validateCloudMessagePayload(payload, body, auth) {
  if (!isObject(payload)) return 'Brak zaszyfrowanego payloadu.';
  if (!isObject(payload.aad)) return 'Brak AAD wiadomosci.';
  if (String(payload.messageId || '') !== String(body.messageId || '')) {
    return 'messageId payloadu nie zgadza sie z zadaniem.';
  }
  if (String(payload.aad.messageId || '') !== String(body.messageId || '')) {
    return 'messageId w AAD nie zgadza sie z zadaniem.';
  }
  if (String(payload.aad.senderUserId || '') !== auth.user.userId) {
    return 'senderUserId w AAD nie zgadza sie z sesja.';
  }
  const hasReplayFields =
    payload.aad.senderDeviceId !== undefined ||
    payload.aad.messageCounter !== undefined ||
    payload.aad.previousMessageHash !== undefined;
  if (!hasReplayFields &&
      payload.deviceCertificate === undefined &&
      payload.deviceSignature === undefined) return null;
  if (String(payload.aad.senderDeviceId || '') !== auth.session.deviceId) {
    return 'senderDeviceId w AAD nie zgadza sie z sesja.';
  }
  if (!Number.isInteger(payload.aad.messageCounter) || payload.aad.messageCounter < 1) {
    return 'Niepoprawny licznik wiadomosci.';
  }
  if (typeof payload.aad.previousMessageHash !== 'string') {
    return 'Niepoprawny hash poprzedniej wiadomosci.';
  }
  if (payload.aad.protocolVersion !== undefined && payload.aad.protocolVersion !== 2) {
    return 'Niepoprawna wersja protokolu wiadomosci.';
  }
  if (payload.deviceCertificate !== undefined) {
    if (!isValidDeviceCertificate(payload.deviceCertificate)) {
      return 'Niepoprawny certyfikat urzadzenia.';
    }
    if (payload.deviceCertificate.accountId !== auth.user.userId ||
        payload.deviceCertificate.deviceId !== auth.session.deviceId) {
      return 'Certyfikat urzadzenia nie zgadza sie z sesja.';
    }
    if (typeof payload.deviceSignature !== 'string' || payload.deviceSignature.length < 16) {
      return 'Brak podpisu urzadzenia.';
    }
    if (isDeviceRevoked(auth.user, auth.session.deviceId)) {
      return 'Urzadzenie zostalo uniewaznione.';
    }
    const activeDevice = activeDeviceEntry(auth.user, auth.session.deviceId);
    if (isValidDeviceList(auth.user.deviceList)) {
      if (!activeDevice) {
        return 'Urzadzenie nie jest aktywne na podpisanej liscie urzadzen.';
      }
      if (activeDevice.deviceSigningPublicKey !== payload.deviceCertificate.deviceSigningPublicKey) {
        return 'Certyfikat urzadzenia nie zgadza sie z lista urzadzen.';
      }
    }
  }
  if (payload.deviceSignature !== undefined && payload.deviceCertificate === undefined) {
    return 'Podpis urzadzenia wymaga certyfikatu urzadzenia.';
  }
  return null;
}

function safeUsername(value) {
  return typeof value === 'string' && SAFE_ID.test(value);
}

function normalizeUsername(value) {
  return String(value || '').trim().toLowerCase();
}

function readJson(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`Nie mozna bezpiecznie odczytac stanu ${file}: ${error.message}`);
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

async function scryptAsync(password, salt) {
  if (activeKdfOperations >= MAX_CONCURRENT_KDF) {
    await new Promise((resolve) => kdfWaiters.push(resolve));
  }
  activeKdfOperations += 1;
  try {
    return await new Promise((resolve, reject) => crypto.scrypt(String(password), salt, 64, {
      N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024
    }, (error, key) => error ? reject(error) : resolve(key)));
  } finally {
    activeKdfOperations -= 1;
    kdfWaiters.shift()?.();
  }
}

function ed25519PublicKey(rawBase64) {
  const raw = Buffer.from(rawBase64, 'base64');
  if (raw.length !== 32) throw new Error('Niepoprawny klucz Ed25519.');
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  return crypto.createPublicKey({ key: Buffer.concat([prefix, raw]), format: 'der', type: 'spki' });
}

function loginChallengePayload(pending) {
  return Buffer.from(JSON.stringify({
    protocol: 'secure-chat/login-challenge/v1',
    challenge: pending.challenge,
    userId: pending.userId,
    deviceId: pending.deviceId,
    expiresAtMs: pending.expiresAtMs
  }), 'utf8');
}

function allowAuthAttempt(req, username) {
  const now = Date.now();
  const ip = req.clientIp || req.socket?.remoteAddress || 'unknown';
  const key = `${ip}:${normalizeUsername(username)}`;
  const live = (authAttempts.get(key) || []).filter((time) => time > now - AUTH_WINDOW_MS);
  if (live.length >= AUTH_MAX_ATTEMPTS) return false;
  live.push(now);
  authAttempts.set(key, live);
  if (authAttempts.size > AUTH_MAX_KEYS) {
    for (const [attemptKey, attempts] of authAttempts.entries()) {
      const stillLive = attempts.filter((time) => time > now - AUTH_WINDOW_MS);
      if (stillLive.length === 0) authAttempts.delete(attemptKey);
      else authAttempts.set(attemptKey, stillLive);
    }
    while (authAttempts.size > AUTH_MAX_KEYS) {
      const oldestKey = authAttempts.keys().next().value;
      authAttempts.delete(oldestKey);
    }
  }
  return true;
}

async function hashPassword(password, salt = crypto.randomBytes(16).toString('base64url')) {
  const hash = await scryptAsync(password, salt);
  return {
    algorithm: 'scrypt',
    salt,
    hash: hash.toString('base64url'),
    params: { N: 16384, r: 8, p: 1 }
  };
}

async function verifyPassword(password, stored) {
  if (!stored || stored.algorithm !== 'scrypt') return false;
  const candidate = await hashPassword(password, stored.salt);
  const expected = Buffer.from(stored.hash, 'base64url');
  const actual = Buffer.from(candidate.hash, 'base64url');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

async function readBody(req, maxBytes = DEFAULT_MAX_BODY_BYTES) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new Error('Payload jest za duzy.');
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(String(token), 'utf8').digest('base64url');
}

function validateMemberKeys(memberKeys, memberIds) {
  if (!isObject(memberKeys)) return 'memberKeys musi byc obiektem.';
  const allowed = new Set(memberIds);
  for (const [memberId, envelope] of Object.entries(memberKeys)) {
    if (!allowed.has(memberId)) return 'memberKeys zawiera uzytkownika spoza rozmowy.';
    if (!isObject(envelope)) return 'Koperta memberKeys musi byc obiektem.';
    if (Buffer.byteLength(JSON.stringify(envelope), 'utf8') > MAX_MEMBER_KEY_BYTES) {
      return 'Koperta memberKeys jest za duza.';
    }
    const requiredStrings = ['algorithm', 'conversationId', 'senderUserId', 'senderDeviceId',
      'recipientUserId', 'senderPublicKey', 'senderIdentityPublicKey', 'nonce', 'ciphertext', 'mac', 'signature'];
    if (envelope.v !== 1 || envelope.protocolVersion !== 1 || !Number.isInteger(envelope.keyEpoch) || envelope.keyEpoch < 1 ||
        requiredStrings.some((field) => typeof envelope[field] !== 'string' || envelope[field].length === 0)) {
      return 'Koperta memberKeys nie spelnia schematu secure-chat/member-key/v1.';
    }
    if (envelope.algorithm !== 'X25519-HKDF-SHA256-AES-256-GCM') {
      return 'Nieobslugiwany algorytm koperty memberKeys.';
    }
    if (envelope.recipientUserId !== memberId) {
      return 'Odbiorca koperty memberKeys nie zgadza sie z kluczem mapy.';
    }
  }
  return null;
}

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store'
  });
  res.end(JSON.stringify(payload));
}

function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') return '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1] : '';
}

export class V2Store {
  constructor({ dataDir }) {
    this.dataDir = path.resolve(dataDir);
    fs.mkdirSync(this.dataDir, { recursive: true });
    this.database = new SqliteStateStore(this.dataDir);
    this.usersFile = path.join(this.dataDir, 'users.json');
    this.sessionsFile = path.join(this.dataDir, 'sessions.json');
    this.conversationsFile = path.join(this.dataDir, 'conversations.json');
    this.messagesFile = path.join(this.dataDir, 'messages.json');
    this.users = this.database.hasState('users')
      ? this.database.readState('users', null)
      : readJson(this.usersFile, { v: 1, users: {} });
    this.sessions = this.database.hasState('sessions')
      ? this.database.readState('sessions', null)
      : readJson(this.sessionsFile, { v: 1, sessions: {} });
    this.conversations = this.database.hasState('conversations')
      ? this.database.readState('conversations', null)
      : readJson(this.conversationsFile, { v: 1, conversations: {} });
    this.messages = fs.existsSync(this.messagesFile)
      ? readJson(this.messagesFile, { v: 1, messages: {} })
      : { v: 1, messages: {} };
    this.database.importLegacyMessages(this.messages.messages);
    this.database.writeState('users', this.users);
    this.database.writeState('sessions', this.sessions);
    this.database.writeState('conversations', this.conversations);
    this.liveSockets = new Map();
    this.sessionSockets = new Map();
    this.accountQueues = new Map();
    this.wsTickets = new Map();
    this.wsTicketAttempts = new Map();
    this.pendingLogins = new Map();
    this.pruneSessions();
  }

  prunePendingLogins() {
    const now = Date.now();
    for (const [hash, pending] of this.pendingLogins.entries()) {
      if (!pending || pending.expiresAtMs <= now) this.pendingLogins.delete(hash);
    }
  }

  createPendingLogin(user, deviceId, deviceName) {
    this.prunePendingLogins();
    if (this.pendingLogins.size >= PENDING_LOGIN_MAX_GLOBAL) return null;
    const token = crypto.randomBytes(32).toString('base64url');
    const pending = {
      userId: user.userId,
      deviceId,
      deviceName: String(deviceName || 'Urzadzenie').slice(0, 80),
      challenge: crypto.randomBytes(32).toString('base64url'),
      expiresAtMs: Date.now() + PENDING_LOGIN_TTL_MS
    };
    this.pendingLogins.set(tokenHash(token), pending);
    return { token, ...pending };
  }

  completePendingLogin(token, signature) {
    this.prunePendingLogins();
    const hash = tokenHash(token);
    const pending = this.pendingLogins.get(hash);
    this.pendingLogins.delete(hash);
    if (!pending) return null;
    const user = this.users.users[pending.userId];
    if (!user || typeof signature !== 'string') return null;
    let valid = false;
    try {
      valid = crypto.verify(null, loginChallengePayload(pending), ed25519PublicKey(user.identityPublicKey), Buffer.from(signature, 'base64'));
    } catch {
      valid = false;
    }
    if (!valid) return null;
    const session = this.createSession(user, pending.deviceId, pending.deviceName);
    return { user, session, deviceId: pending.deviceId };
  }

  persistUsers() {
    this.database.writeState('users', this.users);
  }

  persistSessions() {
    this.database.writeState('sessions', this.sessions);
  }

  persistConversations() {
    this.database.writeState('conversations', this.conversations);
  }

  persistMessages(message) {
    this.database.appendMessage(message);
  }

  persistMessageAndConversation(message) {
    this.database.appendMessageAndUpdateConversations(message, this.conversations);
  }

  pruneSessions() {
    const now = Date.now();
    let changed = false;
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (!session || session.expiresAtMs <= now) {
        delete this.sessions.sessions[hash];
        this.closeSessionSockets(hash, 'session_expired');
        this.revokeWsTicketsForSession(hash);
        changed = true;
      }
    }
    if (changed) this.persistSessions();
  }

  userByName(username) {
    const normalized = normalizeUsername(username);
    return Object.values(this.users.users).find((user) => user.username === normalized) || null;
  }

  publicUser(user) {
    const devices = {};
    for (const [deviceId, device] of Object.entries(user.devices || {})) {
      devices[deviceId] = {
        deviceId,
        deviceName: device.deviceName || 'Urzadzenie',
        lastSeenAt: device.lastSeenAt || null,
        deviceCertificate: isValidDeviceCertificate(device.deviceCertificate)
          ? device.deviceCertificate
          : null
      };
    }
    return {
      userId: user.userId,
      username: user.username,
      displayName: user.displayName || user.username,
      keyAgreementPublicKey: user.keyAgreementPublicKey,
      identityPublicKey: user.identityPublicKey || '',
      keyAgreementPublicKeySignature: user.keyAgreementPublicKeySignature || '',
      devices,
      deviceList: isValidDeviceList(user.deviceList) ? user.deviceList : null,
      deviceListHash: typeof user.deviceListHash === 'string' ? user.deviceListHash : '',
      identityRotationProof: user.identityRotationProof || null,
      updatedAt: user.updatedAt
    };
  }

  createSession(user, deviceId, deviceName) {
    if (isDeviceRevoked(user, deviceId)) {
      throw new Error('Urzadzenie zostalo uniewaznione.');
    }
    const token = crypto.randomBytes(32).toString('base64url');
    const expiresAtMs = Date.now() + SESSION_TTL_MS;
    user.devices ||= {};
    const previousDevice = user.devices[deviceId] || {};
    user.devices[deviceId] = {
      ...previousDevice,
      deviceId,
      deviceName: String(deviceName || 'Urzadzenie').slice(0, 80),
      lastSeenAt: nowIso()
    };
    const hash = tokenHash(token);
    this.sessions.sessions[hash] = {
      userId: user.userId,
      deviceId,
      createdAt: nowIso(),
      lastSeenAtWriteMs: Date.now(),
      expiresAtMs
    };
    this.persistUsers();
    this.persistSessions();
    return { token, expiresAt: new Date(expiresAtMs).toISOString() };
  }

  auth(req) {
    this.pruneSessions();
    const token = bearerToken(req);
    const hash = tokenHash(token);
    const session = this.sessions.sessions[hash];
    if (!session) return null;
    const user = this.users.users[session.userId];
    if (!user) return null;
    if (isDeviceRevoked(user, session.deviceId)) {
      delete this.sessions.sessions[hash];
      this.closeSessionSockets(hash, 'device_revoked');
      this.revokeWsTicketsForSession(hash);
      this.persistSessions();
      return null;
    }
    user.devices ||= {};
    if (user.devices[session.deviceId]) {
      const now = Date.now();
      if (!Number.isFinite(session.lastSeenAtWriteMs) ||
          now - session.lastSeenAtWriteMs >= LAST_SEEN_WRITE_INTERVAL_MS) {
        user.devices[session.deviceId].lastSeenAt = nowIso();
        session.lastSeenAtWriteMs = now;
        this.persistUsers();
        this.persistSessions();
      }
    }
    return { tokenHash: hash, session, user };
  }

  conversationForMembers(memberIds, type = 'direct') {
    const sorted = [...memberIds].sort();
    return Object.values(this.conversations.conversations).find((conversation) =>
      conversation.type === type &&
      conversation.memberIds.length === sorted.length &&
      conversation.memberIds.every((memberId, index) => memberId === sorted[index])
    ) || null;
  }

  conversationsForUser(userId) {
    return Object.values(this.conversations.conversations)
      .filter((conversation) => conversation.memberIds.includes(userId))
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  }

  messagesForConversation(conversationId, afterSeq = 0, limit = DEFAULT_MESSAGE_PAGE) {
    return this.database.readMessages(
      conversationId,
      afterSeq,
      Math.min(MAX_MESSAGE_PAGE, Math.max(1, limit))
    );
  }

  broadcast(userIds, event) {
    const raw = JSON.stringify(event);
    for (const userId of userIds) {
      const sockets = this.liveSockets.get(userId);
      if (!sockets) continue;
      for (const ws of sockets) {
        if (ws.readyState === 1) {
          ws.send(raw);
        }
      }
    }
  }

  attachSocket(userId, deviceId, sessionHash, ws) {
    ws._secureP2pDeviceId = deviceId;
    ws._secureP2pSessionHash = sessionHash;
    const sockets = this.liveSockets.get(userId) || new Set();
    sockets.add(ws);
    this.liveSockets.set(userId, sockets);
    const sessionSockets = this.sessionSockets.get(sessionHash) || new Set();
    sessionSockets.add(ws);
    this.sessionSockets.set(sessionHash, sessionSockets);
    ws.on('close', () => {
      sockets.delete(ws);
      if (sockets.size === 0) this.liveSockets.delete(userId);
      sessionSockets.delete(ws);
      if (sessionSockets.size === 0) this.sessionSockets.delete(sessionHash);
    });
  }

  issueWsTicket(auth) {
    this.pruneWsTickets();
    if (!this.allowWsTicketRequest(auth.tokenHash)) return null;
    if (this.wsTickets.size >= WS_TICKET_MAX_GLOBAL) return null;
    let activeForSession = 0;
    for (const entry of this.wsTickets.values()) {
      if (entry.sessionHash === auth.tokenHash) activeForSession += 1;
    }
    if (activeForSession >= WS_TICKET_MAX_PER_SESSION) return null;
    const ticket = crypto.randomBytes(32).toString('base64url');
    this.wsTickets.set(tokenHash(ticket), {
      sessionHash: auth.tokenHash,
      expiresAtMs: Date.now() + WS_TICKET_TTL_MS
    });
    return ticket;
  }

  consumeWsTicket(ticket) {
    this.pruneWsTickets();
    const hash = tokenHash(ticket);
    const entry = this.wsTickets.get(hash);
    this.wsTickets.delete(hash);
    if (!entry || entry.expiresAtMs < Date.now()) return null;
    const session = this.sessions.sessions[entry.sessionHash];
    const user = session && this.users.users[session.userId];
    if (!session || !user || isDeviceRevoked(user, session.deviceId)) return null;
    return { sessionHash: entry.sessionHash, session, user };
  }

  pruneWsTickets() {
    const now = Date.now();
    for (const [hash, entry] of this.wsTickets.entries()) {
      if (!entry || entry.expiresAtMs <= now || !this.sessions.sessions[entry.sessionHash]) {
        this.wsTickets.delete(hash);
      }
    }
    for (const [sessionHash, attempts] of this.wsTicketAttempts.entries()) {
      const live = attempts.filter((time) => time > now - WS_TICKET_WINDOW_MS);
      if (live.length === 0) this.wsTicketAttempts.delete(sessionHash);
      else this.wsTicketAttempts.set(sessionHash, live);
    }
  }

  allowWsTicketRequest(sessionHash) {
    const now = Date.now();
    const live = (this.wsTicketAttempts.get(sessionHash) || [])
      .filter((time) => time > now - WS_TICKET_WINDOW_MS);
    if (live.length >= WS_TICKET_MAX_PER_WINDOW) {
      this.wsTicketAttempts.set(sessionHash, live);
      return false;
    }
    live.push(now);
    this.wsTicketAttempts.set(sessionHash, live);
    return true;
  }

  revokeWsTicketsForSession(sessionHash) {
    for (const [hash, entry] of this.wsTickets.entries()) {
      if (entry.sessionHash === sessionHash) this.wsTickets.delete(hash);
    }
    this.wsTicketAttempts.delete(sessionHash);
  }

  closeSessionSockets(sessionHash, reason = 'session_revoked') {
    const sockets = this.sessionSockets.get(sessionHash);
    if (!sockets) return 0;
    let closed = 0;
    for (const ws of Array.from(sockets)) {
      if (ws.readyState === 0 || ws.readyState === 1) {
        ws.close(4001, reason);
        closed += 1;
      }
    }
    this.sessionSockets.delete(sessionHash);
    return closed;
  }

  closeUserSockets(userId, reason = 'session_revoked') {
    const sockets = this.liveSockets.get(userId);
    if (!sockets) return 0;
    let closed = 0;
    for (const ws of Array.from(sockets)) {
      if (ws.readyState === 0 || ws.readyState === 1) {
        ws.close(4001, reason);
        closed += 1;
      }
    }
    this.liveSockets.delete(userId);
    return closed;
  }

  revokeSession(sessionHash) {
    const existed = delete this.sessions.sessions[sessionHash];
    this.revokeWsTicketsForSession(sessionHash);
    this.closeSessionSockets(sessionHash, 'session_revoked');
    if (existed) this.persistSessions();
    return existed;
  }

  revokeAllSessionsForUser(userId) {
    let changed = false;
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (session.userId === userId) {
        delete this.sessions.sessions[hash];
        this.revokeWsTicketsForSession(hash);
        this.closeSessionSockets(hash, 'session_revoked');
        changed = true;
      }
    }
    this.closeUserSockets(userId, 'session_revoked');
    if (changed) this.persistSessions();
    return changed;
  }

  revokeDeviceSessions(userId, deviceIds) {
    const revoked = new Set(deviceIds);
    if (revoked.size === 0) return;
    let changed = false;
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (session.userId === userId && revoked.has(session.deviceId)) {
        delete this.sessions.sessions[hash];
        this.revokeWsTicketsForSession(hash);
        this.closeSessionSockets(hash, 'device_revoked');
        changed = true;
      }
    }
    if (changed) this.persistSessions();
    const sockets = this.liveSockets.get(userId);
    if (!sockets) return;
    for (const ws of Array.from(sockets)) {
      if (revoked.has(ws._secureP2pDeviceId) && ws.readyState === 1) {
        ws.close(4001, 'Urzadzenie zostalo uniewaznione.');
      }
    }
  }

  withAccountLock(userId, task) {
    const previous = this.accountQueues.get(userId) || Promise.resolve();
    let current;
    current = previous
      .catch(() => {})
      .then(task)
      .finally(() => {
        if (this.accountQueues.get(userId) === current) {
          this.accountQueues.delete(userId);
        }
      });
    this.accountQueues.set(userId, current);
    return current;
  }
}

export async function handleV2Http(store, req, res, url, options = {}) {
  try {
    const method = req.method || 'GET';
    const parts = url.pathname.split('/').filter(Boolean);

    if (method === 'POST' && url.pathname === '/v2/register') {
      if ((options.registrationMode || 'invite') !== 'open') {
        return sendJson(res, 403, { ok: false, error: 'Rejestracja publiczna jest wylaczona.' });
      }
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      const username = normalizeUsername(body.username);
      if (!allowAuthAttempt(req, username)) return sendJson(res, 429, { ok: false, error: 'Sprobuj ponownie pozniej.' });
      const password = String(body.password || '');
      const deviceId = String(body.deviceId || randomId());
      if (!safeUsername(username)) return sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa konta.' });
      if (password.length < 8) return sendJson(res, 400, { ok: false, error: 'Haslo ma minimum 8 znakow.' });
      if (store.userByName(username)) return sendJson(res, 409, { ok: false, error: 'Konto juz istnieje.' });
      if (typeof body.keyAgreementPublicKey !== 'string' || body.keyAgreementPublicKey.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak publicznego klucza szyfrowania.' });
      }
      if (typeof body.identityPublicKey !== 'string' || body.identityPublicKey.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak publicznego klucza tozsamosci.' });
      }
      if (typeof body.keyAgreementPublicKeySignature !== 'string' || body.keyAgreementPublicKeySignature.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak podpisu klucza szyfrowania.' });
      }

      const userId = randomId();
      const user = {
        userId,
        username,
        displayName: String(body.displayName || username).slice(0, 80),
        password: await hashPassword(password),
        vaultSalt: typeof body.vaultSalt === 'string' && body.vaultSalt.length >= 16
          ? body.vaultSalt
          : crypto.randomBytes(16).toString('base64url'),
        keyAgreementPublicKey: body.keyAgreementPublicKey,
        identityPublicKey: body.identityPublicKey,
        keyAgreementPublicKeySignature: body.keyAgreementPublicKeySignature,
        identityRotationProof: isValidIdentityRotationProof(body.identityRotationProof) ? body.identityRotationProof : null,
        encryptedVault: isObject(body.encryptedVault) ? body.encryptedVault : null,
        devices: {},
        createdAt: nowIso(),
        updatedAt: nowIso()
      };
      store.users.users[userId] = user;
      let session;
      try {
        session = store.createSession(user, deviceId, body.deviceName);
      } catch (error) {
        return sendJson(res, 403, { ok: false, error: String(error.message || error) });
      }
      store.persistUsers();
      return sendJson(res, 200, {
        ok: true,
        token: session.token,
        expiresAt: session.expiresAt,
        user: store.publicUser(user),
        deviceId,
        vaultSalt: user.vaultSalt,
        encryptedVault: user.encryptedVault
      });
    }

    if (method === 'POST' && url.pathname === '/v2/login') {
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      if (!allowAuthAttempt(req, body.username)) return sendJson(res, 429, { ok: false, error: 'Sprobuj ponownie pozniej.' });
      const user = store.userByName(body.username);
      if (!user || !await verifyPassword(String(body.password || ''), user.password)) {
        return sendJson(res, 401, { ok: false, error: 'Niepoprawny login albo haslo.' });
      }
      const deviceId = String(body.deviceId || randomId());
      if (isDeviceRevoked(user, deviceId)) {
        return sendJson(res, 403, { ok: false, error: 'Urzadzenie zostalo uniewaznione.' });
      }
      const pending = store.createPendingLogin(user, deviceId, body.deviceName);
      if (!pending) return sendJson(res, 503, { ok: false, error: 'Serwer obsluguje zbyt wiele logowan.' });
      return sendJson(res, 200, {
        ok: true,
        pendingToken: pending.token,
        challenge: pending.challenge,
        challengeExpiresAtMs: pending.expiresAtMs,
        user: store.publicUser(user),
        deviceId,
        vaultSalt: user.vaultSalt,
        encryptedVault: user.encryptedVault,
        vaultEpoch: Number.isInteger(user.vaultEpoch) ? user.vaultEpoch : 0,
        vaultHash: typeof user.vaultHash === 'string' ? user.vaultHash : ''
      });
    }

    if (method === 'POST' && url.pathname === '/v2/login/complete') {
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      const completed = store.completePendingLogin(String(body.pendingToken || ''), body.signature);
      if (!completed) return sendJson(res, 401, { ok: false, error: 'Niepoprawne lub wygasle potwierdzenie vaultu.' });
      return sendJson(res, 200, {
        ok: true,
        token: completed.session.token,
        expiresAt: completed.session.expiresAt,
        user: store.publicUser(completed.user),
        deviceId: completed.deviceId,
        vaultSalt: completed.user.vaultSalt,
        encryptedVault: completed.user.encryptedVault
      });
    }

    const auth = store.auth(req);
    if (!auth) return sendJson(res, 401, { ok: false, error: 'Brak logowania.' });

    if (method === 'GET' && url.pathname === '/v2/session') {
      return sendJson(res, 200, { ok: true, user: store.publicUser(auth.user), deviceId: auth.session.deviceId });
    }

    if (method === 'POST' && url.pathname === '/v2/logout') {
      store.revokeSession(auth.tokenHash);
      return sendJson(res, 200, { ok: true });
    }

    if (method === 'POST' && url.pathname === '/v2/sessions/revoke-all') {
      store.revokeAllSessionsForUser(auth.user.userId);
      return sendJson(res, 200, { ok: true });
    }

    if (method === 'POST' && url.pathname === '/v2/ws-ticket') {
      const ticket = store.issueWsTicket(auth);
      if (!ticket) {
        return sendJson(res, 429, { ok: false, error: 'Za duzo aktywnych biletow WebSocket.' });
      }
      return sendJson(res, 200, { ok: true, ticket, expiresInSeconds: 30 });
    }

    if (method === 'GET' && url.pathname === '/v2/users') {
      const users = Object.values(store.users.users)
        .filter((user) => user.userId !== auth.user.userId)
        .map((user) => store.publicUser(user))
        .sort((a, b) => a.displayName.localeCompare(b.displayName));
      return sendJson(res, 200, { ok: true, users });
    }

    if (method === 'PUT' && url.pathname === '/v2/keys') {
      const body = await readBody(req);
      return await store.withAccountLock(auth.user.userId, async () => {
      auth.user = store.users.users[auth.user.userId];
      if (!auth.user) {
        return sendJson(res, 401, { ok: false, error: 'Brak logowania.' });
      }
      if (typeof body.keyAgreementPublicKey !== 'string' || body.keyAgreementPublicKey.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak publicznego klucza szyfrowania.' });
      }
      if (typeof body.identityPublicKey !== 'string' || body.identityPublicKey.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak publicznego klucza tozsamosci.' });
      }
      if (typeof body.keyAgreementPublicKeySignature !== 'string' || body.keyAgreementPublicKeySignature.length < 16) {
        return sendJson(res, 400, { ok: false, error: 'Brak podpisu klucza szyfrowania.' });
      }
      if (body.identityRotationProof !== undefined && body.identityRotationProof !== null && !isValidIdentityRotationProof(body.identityRotationProof)) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny dowod rotacji tozsamosci.' });
      }
      if (body.deviceCertificate !== undefined && body.deviceCertificate !== null) {
        if (!isValidDeviceCertificate(body.deviceCertificate)) {
          return sendJson(res, 400, { ok: false, error: 'Niepoprawny certyfikat urzadzenia.' });
        }
        if (body.deviceCertificate.accountId !== auth.user.userId ||
            body.deviceCertificate.deviceId !== auth.session.deviceId) {
          return sendJson(res, 400, { ok: false, error: 'Certyfikat urzadzenia nie zgadza sie z sesja.' });
        }
      }
      if (body.deviceList !== undefined && body.deviceList !== null) {
        if (!isValidDeviceList(body.deviceList)) {
          return sendJson(res, 400, { ok: false, error: 'Niepoprawna lista urzadzen.' });
        }
        if (body.deviceList.accountId !== auth.user.userId) {
          return sendJson(res, 400, { ok: false, error: 'Lista urzadzen nie zgadza sie z kontem.' });
        }
        if (body.deviceList.revokedDevices.some((device) => device.deviceId === auth.session.deviceId)) {
          return sendJson(res, 400, { ok: false, error: 'Nie mozna uniewaznic aktualnie uzywanego urzadzenia.' });
        }
        if (typeof body.deviceListHash !== 'string' || body.deviceListHash.length < 16) {
          return sendJson(res, 400, { ok: false, error: 'Brak hasha listy urzadzen.' });
        }
        const currentEpoch = Number.isInteger(auth.user.deviceList?.deviceListEpoch)
          ? auth.user.deviceList.deviceListEpoch
          : 0;
        const currentHash = typeof auth.user.deviceListHash === 'string'
          ? auth.user.deviceListHash
          : '';
        if (!Number.isInteger(body.expectedDeviceListEpoch) ||
            typeof body.expectedDeviceListHash !== 'string') {
          return sendJson(res, 400, { ok: false, error: 'Aktualizacja listy urzadzen wymaga expectedDeviceListEpoch i expectedDeviceListHash.' });
        }
        const expectedEpoch = body.expectedDeviceListEpoch;
        const expectedHash = body.expectedDeviceListHash;
        if (expectedEpoch !== currentEpoch || expectedHash !== currentHash) {
          return sendJson(res, 409, {
            ok: false,
            error: 'Lista urzadzen zostala zmieniona przez inne urzadzenie. Odswiez stan i sprobuj ponownie.'
          });
        }
      }
      const previouslyRevoked = revokedDeviceIds(auth.user);
      auth.user.keyAgreementPublicKey = body.keyAgreementPublicKey;
      auth.user.identityPublicKey = body.identityPublicKey;
      auth.user.keyAgreementPublicKeySignature = body.keyAgreementPublicKeySignature;
      auth.user.identityRotationProof = isValidIdentityRotationProof(body.identityRotationProof) ? body.identityRotationProof : null;
      if (isValidDeviceCertificate(body.deviceCertificate)) {
        auth.user.devices ||= {};
        const previousDevice = auth.user.devices[auth.session.deviceId] || {};
        auth.user.devices[auth.session.deviceId] = {
          ...previousDevice,
          deviceId: auth.session.deviceId,
          deviceCertificate: body.deviceCertificate,
          deviceSigningPublicKey: body.deviceCertificate.deviceSigningPublicKey,
          lastSeenAt: nowIso()
        };
      }
      if (isValidDeviceList(body.deviceList)) {
        auth.user.deviceList = body.deviceList;
        auth.user.deviceListHash = body.deviceListHash;
      }
      auth.user.updatedAt = nowIso();
      store.persistUsers();
      if (isValidDeviceList(body.deviceList)) {
        const nowRevoked = revokedDeviceIds(auth.user);
        const newlyRevoked = Array.from(nowRevoked).filter((deviceId) => !previouslyRevoked.has(deviceId));
        store.revokeDeviceSessions(auth.user.userId, newlyRevoked);
      }
      return sendJson(res, 200, { ok: true, user: store.publicUser(auth.user) });
      });
    }

    if (method === 'PUT' && url.pathname === '/v2/vault') {
      const body = await readBody(req);
      if (!isObject(body.encryptedVault)) {
        return sendJson(res, 400, { ok: false, error: 'Brak zaszyfrowanego vaulta.' });
      }
      return await store.withAccountLock(auth.user.userId, async () => {
        const user = store.users.users[auth.user.userId];
        const currentEpoch = Number.isInteger(user.vaultEpoch) ? user.vaultEpoch : 0;
        const currentHash = typeof user.vaultHash === 'string' ? user.vaultHash : '';
        if (!Number.isInteger(body.expectedVaultEpoch) || typeof body.expectedVaultHash !== 'string') {
          return sendJson(res, 400, { ok: false, error: 'Zapis vaultu wymaga expectedVaultEpoch i expectedVaultHash.' });
        }
        if (body.expectedVaultEpoch !== currentEpoch || body.expectedVaultHash !== currentHash) {
          return sendJson(res, 409, { ok: false, error: 'Vault zostal zmieniony przez inne urzadzenie.' });
        }
        const serialized = JSON.stringify(body.encryptedVault);
        if (Buffer.byteLength(serialized, 'utf8') > DEFAULT_MAX_BODY_BYTES) {
          return sendJson(res, 413, { ok: false, error: 'Vault jest za duzy.' });
        }
        user.encryptedVault = body.encryptedVault;
        user.vaultEpoch = currentEpoch + 1;
        user.vaultHash = crypto.createHash('sha256').update(serialized).digest('base64url');
        user.updatedAt = nowIso();
        store.persistUsers();
        store.broadcast([user.userId], { type: 'vault_updated', vaultEpoch: user.vaultEpoch, vaultHash: user.vaultHash });
        return sendJson(res, 200, { ok: true, vaultEpoch: user.vaultEpoch, vaultHash: user.vaultHash });
      });
    }

    if (method === 'GET' && url.pathname === '/v2/vault') {
      return sendJson(res, 200, {
        ok: true,
        vaultSalt: auth.user.vaultSalt,
        encryptedVault: auth.user.encryptedVault
        ,vaultEpoch: Number.isInteger(auth.user.vaultEpoch) ? auth.user.vaultEpoch : 0
        ,vaultHash: typeof auth.user.vaultHash === 'string' ? auth.user.vaultHash : ''
      });
    }

    if (method === 'GET' && url.pathname === '/v2/conversations') {
      return sendJson(res, 200, { ok: true, conversations: store.conversationsForUser(auth.user.userId) });
    }

    if (method === 'POST' && url.pathname === '/v2/conversations/direct') {
      const body = await readBody(req);
      const peerUserId = String(body.peerUserId || '');
      const peer = store.users.users[peerUserId];
      if (!peer) return sendJson(res, 404, { ok: false, error: 'Nie ma takiego uzytkownika.' });
      const memberIds = [auth.user.userId, peerUserId].sort();
      const requestedConversationId = String(body.conversationId || '');
      if (!SAFE_ID.test(requestedConversationId)) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny identyfikator rozmowy.' });
      }
      const memberKeysError = validateMemberKeys(body.memberKeys || {}, memberIds);
      if (memberKeysError) return sendJson(res, 400, { ok: false, error: memberKeysError });
      if (Object.keys(body.memberKeys || {}).length !== memberIds.length) {
        return sendJson(res, 400, { ok: false, error: 'Tworzenie rozmowy wymaga koperty dla kazdego czlonka.' });
      }
      for (const envelope of Object.values(body.memberKeys)) {
        if (envelope.conversationId !== requestedConversationId || envelope.senderUserId !== auth.user.userId ||
            envelope.senderDeviceId !== auth.session.deviceId) {
          return sendJson(res, 400, { ok: false, error: 'Kontekst koperty memberKeys nie zgadza sie z sesja lub rozmowa.' });
        }
      }
      let conversation = store.conversationForMembers(memberIds, 'direct');
      if (!conversation) {
        conversation = {
          conversationId: requestedConversationId,
          type: 'direct',
          memberIds,
          keyEpoch: 1,
          memberKeys: isObject(body.memberKeys) ? body.memberKeys : {},
          createdAt: nowIso(),
          updatedAt: nowIso()
        };
        store.conversations.conversations[conversation.conversationId] = conversation;
        store.persistConversations();
        store.broadcast(memberIds, { type: 'conversation', conversation });
      } else if (isObject(body.memberKeys)) {
        for (const [userId, envelope] of Object.entries(body.memberKeys)) {
          if (conversation.memberKeys[userId] === undefined) {
            conversation.memberKeys[userId] = envelope;
          }
        }
        conversation.updatedAt = nowIso();
        store.persistConversations();
      }
      return sendJson(res, 200, { ok: true, conversation });
    }

    if (method === 'PUT' && parts.length === 4 && parts[0] === 'v2' &&
        parts[1] === 'conversations' && parts[3] === 'keys') {
      const conversationId = parts[2];
      const body = await readBody(req);
      return await store.withAccountLock(`conversation:${conversationId}`, async () => {
        const conversation = store.conversations.conversations[conversationId];
        if (!conversation || !conversation.memberIds.includes(auth.user.userId)) {
          return sendJson(res, 404, { ok: false, error: 'Nie ma takiej rozmowy.' });
        }
        const currentEpoch = Number.isInteger(conversation.keyEpoch) ? conversation.keyEpoch : 1;
        if (body.expectedKeyEpoch !== currentEpoch) {
          return sendJson(res, 409, { ok: false, error: 'Klucz rozmowy zostal juz obrocony.' });
        }
        const memberKeysError = validateMemberKeys(body.memberKeys, conversation.memberIds);
        if (memberKeysError) return sendJson(res, 400, { ok: false, error: memberKeysError });
        if (Object.keys(body.memberKeys).length !== conversation.memberIds.length) {
          return sendJson(res, 400, { ok: false, error: 'Rotacja wymaga koperty dla kazdego czlonka.' });
        }
        for (const envelope of Object.values(body.memberKeys)) {
          if (envelope.conversationId !== conversationId || envelope.keyEpoch !== currentEpoch + 1 ||
              envelope.senderUserId !== auth.user.userId || envelope.senderDeviceId !== auth.session.deviceId) {
            return sendJson(res, 400, { ok: false, error: 'Niepoprawny kontekst rotacji klucza.' });
          }
        }
        conversation.memberKeys = body.memberKeys;
        conversation.keyEpoch = currentEpoch + 1;
        conversation.updatedAt = nowIso();
        store.persistConversations();
        store.broadcast(conversation.memberIds, { type: 'conversation', conversation, securityEvent: 'key_rotated' });
        return sendJson(res, 200, { ok: true, conversation });
      });
    }

    if (method === 'GET' && url.pathname === '/v2/messages') {
      const conversationId = url.searchParams.get('conversationId') || '';
      const conversation = store.conversations.conversations[conversationId];
      if (!conversation || !conversation.memberIds.includes(auth.user.userId)) {
        return sendJson(res, 404, { ok: false, error: 'Nie ma takiej rozmowy.' });
      }
      const afterSeq = Number.parseInt(url.searchParams.get('afterSeq') || '0', 10);
      const requestedLimit = Number.parseInt(url.searchParams.get('limit') || String(DEFAULT_MESSAGE_PAGE), 10);
      const limit = Number.isFinite(requestedLimit) ? Math.min(MAX_MESSAGE_PAGE, Math.max(1, requestedLimit)) : DEFAULT_MESSAGE_PAGE;
      const messages = store.messagesForConversation(conversationId, Number.isFinite(afterSeq) ? afterSeq : 0, limit);
      return sendJson(res, 200, {
        ok: true,
        messages,
        nextAfterSeq: messages.length === limit ? messages[messages.length - 1].seq : null
      });
    }

    if (method === 'POST' && url.pathname === '/v2/messages') {
      const body = await readBody(req);
      const conversationId = String(body.conversationId || '');
      return await store.withAccountLock(`conversation:${conversationId}`, async () => {
      const conversation = store.conversations.conversations[conversationId];
      if (!conversation || !conversation.memberIds.includes(auth.user.userId)) {
        return sendJson(res, 404, { ok: false, error: 'Nie ma takiej rozmowy.' });
      }
      const payloadError = validateCloudMessagePayload(body.payload, body, auth);
      if (payloadError) {
        return sendJson(res, 400, { ok: false, error: payloadError });
      }
      if (Buffer.byteLength(JSON.stringify(body.payload), 'utf8') > MAX_STORED_MESSAGE_BYTES) {
        return sendJson(res, 413, { ok: false, error: 'Wiadomosc jest za duza.' });
      }
      if (store.database.messageCount(conversationId) >= MAX_MESSAGES_PER_CONVERSATION) {
        return sendJson(res, 507, { ok: false, error: 'Rozmowa osiagnela limit przechowywania.' });
      }
      const list = store.messages.messages[conversationId] || [];
      const seq = store.database.nextMessageSequence(conversationId);
      const message = {
        messageId: String(body.messageId || randomId()),
        conversationId,
        seq,
        senderUserId: auth.user.userId,
        senderDeviceId: auth.session.deviceId,
        createdAt: nowIso(),
        payload: body.payload
      };
      list.push(message);
      store.messages.messages[conversationId] = list;
      conversation.updatedAt = message.createdAt;
      store.persistMessageAndConversation(message);
      store.broadcast(conversation.memberIds, { type: 'message', message });
      return sendJson(res, 200, { ok: true, message });
      });
    }

    return sendJson(res, 404, { ok: false, error: 'Nieznany endpoint v2.' });
  } catch (error) {
    const requestId = crypto.randomUUID();
    console.error(JSON.stringify({ requestId, error: String(error?.stack || error) }));
    return sendJson(res, 500, { ok: false, error: 'INTERNAL_ERROR', requestId });
  }
}

export function handleV2WebSocket(store, ws, request) {
  const timer = setTimeout(() => ws.close(1008, 'Brak biletu WebSocket.'), 10_000);
  ws.once('message', (raw) => {
    clearTimeout(timer);
    let message;
    try { message = JSON.parse(String(raw)); } catch { ws.close(1008, 'Niepoprawne uwierzytelnienie.'); return; }
    const auth = message?.type === 'auth' || message?.type === 'authenticate'
      ? store.consumeWsTicket(message.ticket)
      : null;
    if (!auth) { ws.close(1008, 'Niepoprawny lub zuzyty bilet.'); return; }
    store.attachSocket(auth.user.userId, auth.session.deviceId, auth.sessionHash, ws);
    ws.send(JSON.stringify({ type: 'ready', userId: auth.user.userId, deviceId: auth.session.deviceId, serverTime: nowIso() }));
    ws.on('message', () => ws.send(JSON.stringify({ type: 'pong', serverTime: nowIso() })));
  });
}
