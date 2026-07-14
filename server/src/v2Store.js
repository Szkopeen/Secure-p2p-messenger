import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { URL } from 'node:url';

const SAFE_ID = /^[a-zA-Z0-9_.:@-]{3,64}$/;
const MAX_BODY_BYTES = 64 * 1024 * 1024;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

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
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('base64url')) {
  const hash = crypto.scryptSync(String(password), salt, 64, {
    N: 16384,
    r: 8,
    p: 1,
    maxmem: 64 * 1024 * 1024
  });
  return {
    algorithm: 'scrypt',
    salt,
    hash: hash.toString('base64url'),
    params: { N: 16384, r: 8, p: 1 }
  };
}

function verifyPassword(password, stored) {
  if (!stored || stored.algorithm !== 'scrypt') return false;
  const candidate = hashPassword(password, stored.salt);
  const expected = Buffer.from(stored.hash, 'base64url');
  const actual = Buffer.from(candidate.hash, 'base64url');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw new Error('Payload jest za duzy.');
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
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
    this.usersFile = path.join(this.dataDir, 'users.json');
    this.sessionsFile = path.join(this.dataDir, 'sessions.json');
    this.conversationsFile = path.join(this.dataDir, 'conversations.json');
    this.messagesFile = path.join(this.dataDir, 'messages.json');
    this.users = readJson(this.usersFile, { v: 1, users: {} });
    this.sessions = readJson(this.sessionsFile, { v: 1, sessions: {} });
    this.conversations = readJson(this.conversationsFile, { v: 1, conversations: {} });
    this.messages = readJson(this.messagesFile, { v: 1, messages: {} });
    this.liveSockets = new Map();
    this.pruneSessions();
  }

  persistUsers() {
    writeJson(this.usersFile, this.users);
  }

  persistSessions() {
    writeJson(this.sessionsFile, this.sessions);
  }

  persistConversations() {
    writeJson(this.conversationsFile, this.conversations);
  }

  persistMessages() {
    writeJson(this.messagesFile, this.messages);
  }

  pruneSessions() {
    const now = Date.now();
    let changed = false;
    for (const [token, session] of Object.entries(this.sessions.sessions)) {
      if (!session || session.expiresAtMs <= now) {
        delete this.sessions.sessions[token];
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
      identityRotationProof: user.identityRotationProof || null,
      updatedAt: user.updatedAt
    };
  }

  createSession(user, deviceId, deviceName) {
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
    this.sessions.sessions[token] = {
      token,
      userId: user.userId,
      deviceId,
      createdAt: nowIso(),
      expiresAtMs
    };
    this.persistUsers();
    this.persistSessions();
    return { token, expiresAt: new Date(expiresAtMs).toISOString() };
  }

  auth(req) {
    this.pruneSessions();
    const token = bearerToken(req);
    const session = this.sessions.sessions[token];
    if (!session) return null;
    const user = this.users.users[session.userId];
    if (!user) return null;
    user.devices ||= {};
    if (user.devices[session.deviceId]) {
      user.devices[session.deviceId].lastSeenAt = nowIso();
      this.persistUsers();
    }
    return { token, session, user };
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

  messagesForConversation(conversationId, afterSeq = 0) {
    return (this.messages.messages[conversationId] || [])
      .filter((message) => message.seq > afterSeq)
      .sort((a, b) => a.seq - b.seq);
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

  attachSocket(userId, ws) {
    const sockets = this.liveSockets.get(userId) || new Set();
    sockets.add(ws);
    this.liveSockets.set(userId, sockets);
    ws.on('close', () => {
      sockets.delete(ws);
      if (sockets.size === 0) this.liveSockets.delete(userId);
    });
  }
}

export async function handleV2Http(store, req, res, url) {
  try {
    const method = req.method || 'GET';
    const parts = url.pathname.split('/').filter(Boolean);

    if (method === 'POST' && url.pathname === '/v2/register') {
      const body = await readBody(req);
      const username = normalizeUsername(body.username);
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
        password: hashPassword(password),
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
      const session = store.createSession(user, deviceId, body.deviceName);
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
      const body = await readBody(req);
      const user = store.userByName(body.username);
      if (!user || !verifyPassword(String(body.password || ''), user.password)) {
        return sendJson(res, 401, { ok: false, error: 'Niepoprawny login albo haslo.' });
      }
      const deviceId = String(body.deviceId || randomId());
      const session = store.createSession(user, deviceId, body.deviceName);
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

    const auth = store.auth(req);
    if (!auth) return sendJson(res, 401, { ok: false, error: 'Brak logowania.' });

    if (method === 'GET' && url.pathname === '/v2/session') {
      return sendJson(res, 200, { ok: true, user: store.publicUser(auth.user), deviceId: auth.session.deviceId });
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
      auth.user.updatedAt = nowIso();
      store.persistUsers();
      return sendJson(res, 200, { ok: true, user: store.publicUser(auth.user) });
    }

    if (method === 'PUT' && url.pathname === '/v2/vault') {
      const body = await readBody(req);
      if (!isObject(body.encryptedVault)) {
        return sendJson(res, 400, { ok: false, error: 'Brak zaszyfrowanego vaulta.' });
      }
      auth.user.encryptedVault = body.encryptedVault;
      auth.user.updatedAt = nowIso();
      store.persistUsers();
      store.broadcast([auth.user.userId], { type: 'vault_updated', updatedAt: auth.user.updatedAt });
      return sendJson(res, 200, { ok: true });
    }

    if (method === 'GET' && url.pathname === '/v2/vault') {
      return sendJson(res, 200, {
        ok: true,
        vaultSalt: auth.user.vaultSalt,
        encryptedVault: auth.user.encryptedVault
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
      let conversation = store.conversationForMembers(memberIds, 'direct');
      if (!conversation) {
        conversation = {
          conversationId: randomId(),
          type: 'direct',
          memberIds,
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

    if (method === 'GET' && url.pathname === '/v2/messages') {
      const conversationId = url.searchParams.get('conversationId') || '';
      const conversation = store.conversations.conversations[conversationId];
      if (!conversation || !conversation.memberIds.includes(auth.user.userId)) {
        return sendJson(res, 404, { ok: false, error: 'Nie ma takiej rozmowy.' });
      }
      const afterSeq = Number.parseInt(url.searchParams.get('afterSeq') || '0', 10);
      return sendJson(res, 200, {
        ok: true,
        messages: store.messagesForConversation(conversationId, Number.isFinite(afterSeq) ? afterSeq : 0)
      });
    }

    if (method === 'POST' && url.pathname === '/v2/messages') {
      const body = await readBody(req);
      const conversationId = String(body.conversationId || '');
      const conversation = store.conversations.conversations[conversationId];
      if (!conversation || !conversation.memberIds.includes(auth.user.userId)) {
        return sendJson(res, 404, { ok: false, error: 'Nie ma takiej rozmowy.' });
      }
      const payloadError = validateCloudMessagePayload(body.payload, body, auth);
      if (payloadError) {
        return sendJson(res, 400, { ok: false, error: payloadError });
      }
      const list = store.messages.messages[conversationId] || [];
      const seq = list.length === 0 ? 1 : list[list.length - 1].seq + 1;
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
      store.persistMessages();
      store.persistConversations();
      store.broadcast(conversation.memberIds, { type: 'message', message });
      return sendJson(res, 200, { ok: true, message });
    }

    return sendJson(res, 404, { ok: false, error: 'Nieznany endpoint v2.' });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: String(error.message || error) });
  }
}

export function handleV2WebSocket(store, ws, request) {
  const url = new URL(request.url || '/', 'http://127.0.0.1');
  const token = url.searchParams.get('token') || '';
  const fakeReq = { headers: { authorization: `Bearer ${token}` } };
  const auth = store.auth(fakeReq);
  if (!auth) {
    ws.close(1008, 'Brak logowania.');
    return;
  }
  store.attachSocket(auth.user.userId, ws);
  ws.send(JSON.stringify({
    type: 'ready',
    userId: auth.user.userId,
    deviceId: auth.session.deviceId,
    serverTime: nowIso()
  }));
  ws.on('message', () => {
    ws.send(JSON.stringify({ type: 'pong', serverTime: nowIso() }));
  });
}
