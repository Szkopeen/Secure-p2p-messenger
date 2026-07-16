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
const MAX_STORED_MESSAGE_BYTES = 128 * 1024;
const MAX_MESSAGES_PER_CONVERSATION = 50_000;
const MAX_CONVERSATION_BYTES = 256 * 1024 * 1024;
const MAX_ACCOUNT_BYTES = 1024 * 1024 * 1024;
const MAX_INSTANCE_BYTES = 10 * 1024 * 1024 * 1024;
const MAX_DAILY_ACCOUNT_BYTES = 100 * 1024 * 1024;
const MIN_FREE_DISK_BYTES = 512 * 1024 * 1024;
const DEFAULT_SESSION_TTL_MS = 3 * 24 * 60 * 60 * 1000;
const DEFAULT_SESSION_IDLE_TTL_MS = 24 * 60 * 60 * 1000;
const WS_TICKET_TTL_MS = 30 * 1000;
const WS_TICKET_MAX_GLOBAL = 10_000;
const WS_TICKET_MAX_PER_SESSION = 4;
const WS_TICKET_WINDOW_MS = 60 * 1000;
const WS_TICKET_MAX_PER_WINDOW = 30;
const AUTH_WINDOW_MS = 60 * 1000;
const AUTH_PAIR_MAX_ATTEMPTS = 10;
const AUTH_ACCOUNT_MAX_ATTEMPTS = 20;
const AUTH_IP_MAX_ATTEMPTS = 80;
const AUTH_IP_MAX_KEYS = 5000;
const AUTH_ACCOUNT_MAX_KEYS = 5000;
const AUTH_PAIR_MAX_KEYS = 10000;
const AUTH_LOCK_BASE_MS = 30 * 1000;
const AUTH_LOCK_MAX_MS = 15 * 60 * 1000;
const PENDING_LOGIN_TTL_MS = 2 * 60 * 1000;
const PENDING_LOGIN_MAX_GLOBAL = 5000;
const MAX_CONCURRENT_KDF = 4;
const MAX_KDF_QUEUE = 32;
const KDF_QUEUE_TIMEOUT_MS = 5_000;
const PASSWORD_KEY_BYTES = 64;
const PASSWORD_SCRYPT_PARAMS = Object.freeze({ N: 32768, r: 8, p: 1 });
const PASSWORD_SCRYPT_LEGACY_PARAMS = Object.freeze({ N: 16384, r: 8, p: 1 });
const DEVICE_CERTIFICATE_TTL_MS = 365 * 24 * 60 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const LAST_SEEN_WRITE_INTERVAL_MS = 10 * 60 * 1000;
const authIpAttempts = new Map();
const authAccountAttempts = new Map();
const authPairAttempts = new Map();
const GENERIC_DEVICE_NAMES = new Set([
  'Device',
  'Windows device',
  'Linux device',
  'Android device',
  'Urzadzenie'
]);
let activeKdfOperations = 0;
const kdfWaiters = [];
let rejectedKdfOperations = 0;
let totalKdfQueueWaitMs = 0;
let completedKdfQueueWaits = 0;

class ServerBusyError extends Error {
  constructor(message = 'Serwer jest chwilowo przeciazony.') {
    super(message);
    this.code = 'SERVER_BUSY';
  }
}

function nowIso() {
  return new Date().toISOString();
}

function randomId() {
  return crypto.randomUUID();
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isValidVaultKdf(value, { allowLegacy = false } = {}) {
  if (!isObject(value)) return false;
  if (allowLegacy && value.algorithm === 'pbkdf2-sha256') {
    return value.iterations === 310000 && value.keyBytes === 32;
  }
  return value.algorithm === 'argon2id' && value.version === 19 &&
    Number.isInteger(value.memoryKiB) && value.memoryKiB >= 8192 &&
    value.memoryKiB <= 65536 && Number.isInteger(value.iterations) &&
    value.iterations >= 2 && value.iterations <= 4 && value.lanes === 1 &&
    value.keyBytes === 32;
}

function canonicalJson(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('Niekanoniczna liczba JSON.');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (isObject(value)) {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  throw new Error('Nieobslugiwany typ canonical JSON.');
}

function canonicalBytes(value) {
  return Buffer.from(canonicalJson(value), 'utf8');
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(canonicalBytes(value)).digest('hex');
}

function verifyEd25519(publicKey, payload, signature) {
  try {
    return crypto.verify(null, payload, ed25519PublicKey(publicKey), Buffer.from(signature, 'base64url'));
  } catch {
    return false;
  }
}

function unsignedDeviceCertificate(certificate) {
  return {
    v: 1,
    protocol: 'secure-chat/device-certificate/v1',
    accountId: certificate.accountId,
    serverOrigin: certificate.serverOrigin,
    deviceId: certificate.deviceId,
    deviceSigningPublicKey: certificate.deviceSigningPublicKey,
    deviceEpoch: certificate.deviceEpoch,
    createdAt: certificate.createdAt
  };
}

function verifyDeviceCertificate(user, certificate, now = Date.now()) {
  if (!verifyDeviceCertificateSignature(
    user.userId,
    user.identityPublicKey,
    certificate,
    now
  )) return false;
  const activeDevice = activeDeviceEntry(user, certificate.deviceId);
  if (!activeDevice || activeDevice.deviceSigningPublicKey !== certificate.deviceSigningPublicKey ||
      activeDevice.deviceEpoch !== certificate.deviceEpoch) return false;
  const certificateHash = sha256Hex(certificate);
  return activeDevice.certificateHash === certificateHash && !isDeviceRevoked(user, certificate.deviceId);
}

function verifyDeviceCertificateSignature(accountId, identityPublicKey, certificate, now = Date.now()) {
  if (!isValidDeviceCertificate(certificate) || certificate.accountId !== accountId) return false;
  const createdAtMs = Date.parse(certificate.createdAt);
  if (!Number.isFinite(createdAtMs) || createdAtMs > now + MAX_CLOCK_SKEW_MS ||
      now - createdAtMs > DEVICE_CERTIFICATE_TTL_MS) return false;
  return verifyEd25519(
    identityPublicKey,
    canonicalBytes(unsignedDeviceCertificate(certificate)),
    certificate.signature
  );
}

function verifyDeviceList(accountId, identityPublicKey, deviceList) {
  if (!isValidDeviceList(deviceList) || deviceList.accountId !== accountId) return false;
  const signed = {
    v: 1,
    protocol: 'secure-chat/device-list/v1',
    accountId: deviceList.accountId,
    serverOrigin: deviceList.serverOrigin,
    deviceListEpoch: deviceList.deviceListEpoch,
    previousDeviceListHash: deviceList.previousDeviceListHash,
    identityRotationEpoch: deviceList.identityRotationEpoch,
    devices: deviceList.devices,
    revokedDevices: deviceList.revokedDevices,
    updatedAt: deviceList.updatedAt
  };
  return verifyEd25519(identityPublicKey, canonicalBytes(signed), deviceList.signature);
}

function verifyKeyAgreementBinding(accountId, serverOrigin, identityPublicKey,
  keyAgreementPublicKey, signature) {
  return verifyEd25519(identityPublicKey, canonicalBytes({
    v: 1,
    protocol: 'secure-p2p-identity-key-binding/v2',
    accountId,
    serverOrigin,
    identityPublicKey,
    keyAgreementPublicKey
  }), signature);
}

function identityRotationHash(proof) {
  return proof ? sha256Hex(proof) : '';
}

function verifyIdentityRotation(user, nextIdentityPublicKey, nextKeyAgreementPublicKey,
  proof, serverOrigin) {
  if (!isValidIdentityRotationProof(proof) ||
      proof.oldIdentityPublicKey !== user.identityPublicKey ||
      proof.newIdentityPublicKey !== nextIdentityPublicKey ||
      proof.newKeyAgreementPublicKey !== nextKeyAgreementPublicKey) return false;
  const previousProof = user.identityRotationProof;
  const expectedEpoch = Number.isInteger(previousProof?.rotationEpoch)
    ? previousProof.rotationEpoch + 1
    : 1;
  if (proof.rotationEpoch !== expectedEpoch ||
      proof.previousRotationHash !== identityRotationHash(previousProof)) return false;
  const rotatedAtMs = Date.parse(proof.rotatedAt);
  if (!Number.isFinite(rotatedAtMs) || Math.abs(Date.now() - rotatedAtMs) > MAX_CLOCK_SKEW_MS) return false;
  const signed = canonicalBytes({
    v: 1,
    protocol: 'secure-p2p-identity-rotation/v1',
    accountId: user.userId,
    serverOrigin,
    rotationEpoch: proof.rotationEpoch,
    previousRotationHash: proof.previousRotationHash,
    oldIdentityPublicKey: proof.oldIdentityPublicKey,
    newIdentityPublicKey: proof.newIdentityPublicKey,
    newKeyAgreementPublicKey: proof.newKeyAgreementPublicKey,
    rotatedAt: proof.rotatedAt
  });
  return verifyEd25519(proof.oldIdentityPublicKey, signed, proof.signature) &&
    verifyEd25519(proof.newIdentityPublicKey, signed, proof.newIdentityConfirmationSignature);
}

function cloudMessageHash(payload) {
  return sha256Hex({
    v: 1,
    protocol: 'secure-chat/message-chain/v1',
    type: 'message',
    message: payload
  });
}

const CLOUD_MESSAGE_GENESIS_HASH = sha256Hex({
  v: 1,
  protocol: 'secure-chat/message-chain/v1',
  type: 'genesis'
});

function verifyCloudMessageSignature(user, payload) {
  const certificate = payload.deviceCertificate;
  if (!verifyDeviceCertificate(user, certificate)) return false;
  const unsigned = { ...payload };
  delete unsigned.deviceCertificate;
  delete unsigned.deviceSignature;
  const digest = crypto.createHash('sha256').update(canonicalBytes({
    v: 1,
    protocol: 'secure-chat/device-message/v1',
    envelope: unsigned
  })).digest();
  return verifyEd25519(certificate.deviceSigningPublicKey, digest, payload.deviceSignature);
}

function verifyMemberKeyEnvelope(envelope, user) {
  if (envelope.senderIdentityPublicKey !== user.identityPublicKey ||
      envelope.senderPublicKey !== user.keyAgreementPublicKey) return false;
  const unsigned = { ...envelope };
  delete unsigned.signature;
  return verifyEd25519(user.identityPublicKey, canonicalBytes(unsigned), envelope.signature);
}

function storageQuotaError(store, userId, conversationId, payloadBytes, now = Date.now()) {
  if (store.database.messageCount(conversationId) >= store.limits.messagesPerConversation) {
    return { status: 507, error: 'Rozmowa osiagnela limit przechowywania.' };
  }
  if (store.database.conversationBytes(conversationId) + payloadBytes > store.limits.conversationBytes) {
    return { status: 507, error: 'Rozmowa osiagnela limit bajtow.' };
  }
  if (store.database.accountBytes(userId) + payloadBytes > store.limits.accountBytes) {
    return { status: 507, error: 'Konto osiagnelo limit przechowywania.' };
  }
  if (store.database.instanceBytes() + payloadBytes > store.limits.instanceBytes) {
    return { status: 507, error: 'Instancja osiagnela limit przechowywania.' };
  }
  const sinceIso = new Date(now - 24 * 60 * 60 * 1000).toISOString();
  if (store.database.dailyAccountBytes(userId, sinceIso) + payloadBytes >
      store.limits.dailyAccountBytes) {
    return { status: 429, error: 'Przekroczono dobowy limit uploadu konta.' };
  }
  const disk = fs.statfsSync(store.dataDir);
  const freeBytes = Number(disk.bavail) * Number(disk.bsize);
  if (!Number.isFinite(freeBytes) || freeBytes - payloadBytes < store.limits.minFreeDiskBytes) {
    return { status: 507, error: 'Za malo wolnego miejsca na serwerze.' };
  }
  return null;
}

function messageStreamError(database, conversationId, senderUserId, senderDeviceId,
  counter, previousHash) {
  const streamHead = database.streamHead(conversationId, senderUserId, senderDeviceId);
  if (!streamHead) {
    return counter === 1 && previousHash === CLOUD_MESSAGE_GENESIS_HASH
      ? null
      : 'Licznik lub previousMessageHash nie rozpoczyna lancucha urzadzenia.';
  }
  return counter === streamHead.message_counter + 1 && previousHash === streamHead.payload_hash
    ? null
    : 'Licznik lub previousMessageHash nie kontynuuje lancucha urzadzenia.';
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
  if (payload.v !== 1 || payload.protocol !== 'secure-p2p-cloud-message/v1' ||
      payload.aad.v !== 1 || payload.aad.protocol !== 'secure-p2p-cloud-message/v1' ||
      payload.aad.protocolVersion !== 2) {
    return 'Nieobslugiwana wersja protokolu wiadomosci.';
  }
  if (String(payload.messageId || '') !== String(body.messageId || '')) {
    return 'messageId payloadu nie zgadza sie z zadaniem.';
  }
  if (String(payload.aad.messageId || '') !== String(body.messageId || '')) {
    return 'messageId w AAD nie zgadza sie z zadaniem.';
  }
  if (String(payload.aad.senderUserId || '') !== auth.user.userId) {
    return 'senderUserId w AAD nie zgadza sie z sesja.';
  }
  if (String(payload.aad.senderDeviceId || '') !== auth.session.deviceId) {
    return 'senderDeviceId w AAD nie zgadza sie z sesja.';
  }
  if (!Number.isInteger(payload.aad.messageCounter) || payload.aad.messageCounter < 1) {
    return 'Niepoprawny licznik wiadomosci.';
  }
  if (typeof payload.aad.previousMessageHash !== 'string') {
    return 'Niepoprawny hash poprzedniej wiadomosci.';
  }
  if (!isValidDeviceCertificate(payload.deviceCertificate) ||
      typeof payload.deviceSignature !== 'string' || payload.deviceSignature.length < 16) {
    return 'Wiadomosc wymaga certyfikatu i podpisu urzadzenia.';
  }
  if (!Number.isInteger(payload.aad.keyEpoch) || payload.aad.keyEpoch < 1) {
    return 'Niepoprawna epoka klucza wiadomosci.';
  }
  if (payload.deviceCertificate.accountId !== auth.user.userId ||
      payload.deviceCertificate.deviceId !== auth.session.deviceId) {
    return 'Certyfikat urzadzenia nie zgadza sie z sesja.';
  }
  if (!verifyCloudMessageSignature(auth.user, payload)) {
    return 'Niepoprawny lub wygasly certyfikat albo podpis wiadomosci.';
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

async function acquireKdfSlot() {
  if (activeKdfOperations < MAX_CONCURRENT_KDF) {
    activeKdfOperations += 1;
    return;
  }
  if (kdfWaiters.length >= MAX_KDF_QUEUE) {
    rejectedKdfOperations += 1;
    throw new ServerBusyError();
  }
  await new Promise((resolve, reject) => {
    const waiter = { resolve, reject, timer: null, enqueuedAt: Date.now() };
    waiter.timer = setTimeout(() => {
      const index = kdfWaiters.indexOf(waiter);
      if (index >= 0) kdfWaiters.splice(index, 1);
      rejectedKdfOperations += 1;
      reject(new ServerBusyError('Przekroczono czas oczekiwania na KDF.'));
    }, KDF_QUEUE_TIMEOUT_MS);
    waiter.timer.unref?.();
    kdfWaiters.push(waiter);
  });
}

function releaseKdfSlot() {
  activeKdfOperations -= 1;
  const waiter = kdfWaiters.shift();
  if (!waiter) return;
  clearTimeout(waiter.timer);
  totalKdfQueueWaitMs += Date.now() - waiter.enqueuedAt;
  completedKdfQueueWaits += 1;
  activeKdfOperations += 1;
  waiter.resolve();
}

export function kdfMetrics() {
  return {
    active: activeKdfOperations,
    queued: kdfWaiters.length,
    rejected: rejectedKdfOperations,
    averageQueueWaitMs: completedKdfQueueWaits === 0
      ? 0
      : Math.round(totalKdfQueueWaitMs / completedKdfQueueWaits)
  };
}

export function storageMetrics(store) {
  const usedBytes = Number(store.database.instanceBytes());
  const limitBytes = Number(store.limits.instanceBytes);
  const usedPercent = limitBytes > 0 ? (usedBytes / limitBytes) * 100 : 100;
  const disk = fs.statfsSync(store.dataDir);
  const freeDiskBytes = Number(disk.bavail) * Number(disk.bsize);
  const alertLevel = usedPercent >= 95 ? 'critical'
    : usedPercent >= 85 ? 'high'
      : usedPercent >= 70 ? 'warning'
        : 'ok';
  return {
    usedBytes,
    limitBytes,
    usedPercent: Math.round(usedPercent * 100) / 100,
    freeDiskBytes,
    minimumFreeDiskBytes: store.limits.minFreeDiskBytes,
    alertLevel
  };
}

function normalizeScryptParams(params) {
  const candidate = params && typeof params === 'object' ? params : PASSWORD_SCRYPT_LEGACY_PARAMS;
  const normalized = {
    N: Number(candidate.N),
    r: Number(candidate.r),
    p: Number(candidate.p)
  };

  if (
    !Number.isInteger(normalized.N) ||
    !Number.isInteger(normalized.r) ||
    !Number.isInteger(normalized.p) ||
    normalized.N < PASSWORD_SCRYPT_LEGACY_PARAMS.N ||
    normalized.N > 262144 ||
    (normalized.N & (normalized.N - 1)) !== 0 ||
    normalized.r < 8 ||
    normalized.r > 16 ||
    normalized.p < 1 ||
    normalized.p > 4
  ) {
    return null;
  }

  return normalized;
}

function scryptParamsEqual(left, right) {
  return left.N === right.N && left.r === right.r && left.p === right.p;
}

async function scryptAsync(password, salt, params = PASSWORD_SCRYPT_PARAMS) {
  const normalizedParams = normalizeScryptParams(params);
  if (!normalizedParams) throw new Error('invalid_scrypt_params');
  await acquireKdfSlot();
  try {
    return await new Promise((resolve, reject) => crypto.scrypt(String(password), salt, PASSWORD_KEY_BYTES, {
      ...normalizedParams, maxmem: 256 * 1024 * 1024
    }, (error, key) => error ? reject(error) : resolve(key)));
  } finally {
    releaseKdfSlot();
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

function authEntryExpired(entry, now) {
  return entry.hits.length === 0 && entry.lockUntilMs <= now;
}

function pruneAuthAttempts(map, now = Date.now()) {
  for (const [key, entry] of map.entries()) {
    entry.hits = entry.hits.filter((time) => time > now - AUTH_WINDOW_MS);
    if (authEntryExpired(entry, now)) {
      map.delete(key);
    }
  }
}

function authAttemptEntry(map, key, maxKeys, now) {
  const existing = map.get(key);
  if (existing && typeof existing === 'object' && Array.isArray(existing.hits)) {
    return existing;
  }
  pruneAuthAttempts(map, now);
  if (map.size >= maxKeys) {
    return null;
  }
  const entry = { hits: [], lockUntilMs: 0, failures: 0 };
  map.set(key, entry);
  return entry;
}

function pruneAllAuthAttempts(now = Date.now()) {
  pruneAuthAttempts(authIpAttempts, now);
  pruneAuthAttempts(authAccountAttempts, now);
  pruneAuthAttempts(authPairAttempts, now);
}

function checkAuthScope(map, key, maxAttempts, maxKeys, now) {
  const entry = authAttemptEntry(map, key, maxKeys, now);
  if (entry == null) return false;
  entry.hits = entry.hits.filter((time) => time > now - AUTH_WINDOW_MS);
  if (entry.lockUntilMs > now) return false;
  if (entry.hits.length >= maxAttempts) {
    entry.failures += 1;
    const backoffMs = Math.min(AUTH_LOCK_MAX_MS, AUTH_LOCK_BASE_MS * 2 ** Math.min(entry.failures - 1, 5));
    entry.lockUntilMs = now + backoffMs;
    return false;
  }
  entry.hits.push(now);
  return true;
}

function authScopeKeys(req, username) {
  const ip = req.clientIp || req.socket?.remoteAddress || 'unknown';
  const account = normalizeUsername(username) || 'unknown';
  return {
    ip: `ip:${ip}`,
    account: `account:${account}`,
    pair: `pair:${ip}:${account}`
  };
}

function sanitizeDeviceName(deviceName) {
  const value = String(deviceName || '').trim();
  return GENERIC_DEVICE_NAMES.has(value) ? value.slice(0, 80) : 'Device';
}

function allowAuthAttempt(req, username) {
  const now = Date.now();
  pruneAllAuthAttempts(now);
  const keys = authScopeKeys(req, username);
  const checks = [
    [authIpAttempts, keys.ip, AUTH_IP_MAX_ATTEMPTS, AUTH_IP_MAX_KEYS],
    [authPairAttempts, keys.pair, AUTH_PAIR_MAX_ATTEMPTS, AUTH_PAIR_MAX_KEYS]
  ];
  let allowed = true;
  for (const [map, key, maxAttempts, maxKeys] of checks) {
    if (!checkAuthScope(map, key, maxAttempts, maxKeys, now)) allowed = false;
  }
  checkAuthScope(authAccountAttempts, keys.account, AUTH_ACCOUNT_MAX_ATTEMPTS, AUTH_ACCOUNT_MAX_KEYS, now);
  pruneAllAuthAttempts(now);
  return allowed;
}

function recordAuthSuccess(req, username) {
  const keys = authScopeKeys(req, username);
  authAccountAttempts.delete(keys.account);
  authPairAttempts.delete(keys.pair);
}

function resetAuthRateLimits() {
  authIpAttempts.clear();
  authAccountAttempts.clear();
  authPairAttempts.clear();
}

async function hashPassword(password, salt = crypto.randomBytes(16).toString('base64url'), params = PASSWORD_SCRYPT_PARAMS) {
  const normalizedParams = normalizeScryptParams(params);
  if (!normalizedParams) throw new Error('invalid_scrypt_params');
  const hash = await scryptAsync(password, salt, normalizedParams);
  return {
    algorithm: 'scrypt',
    salt,
    hash: hash.toString('base64url'),
    params: normalizedParams
  };
}

async function verifyPasswordDetailed(password, stored) {
  if (!stored || stored.algorithm !== 'scrypt' || !stored.salt || !stored.hash) {
    return { ok: false, needsUpgrade: false };
  }
  const storedParams = normalizeScryptParams(stored.params);
  if (!storedParams) return { ok: false, needsUpgrade: false };
  const hash = await scryptAsync(password, stored.salt, storedParams);
  const expected = Buffer.from(stored.hash, 'base64url');
  const actual = Buffer.from(hash.toString('base64url'), 'base64url');
  const ok = expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
  return {
    ok,
    needsUpgrade: ok && !scryptParamsEqual(storedParams, PASSWORD_SCRYPT_PARAMS)
  };
}

async function verifyPassword(password, stored) {
  return (await verifyPasswordDetailed(password, stored)).ok;
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

function validateMemberKeys(memberKeys, memberIds, auth) {
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
    if (!auth || envelope.senderUserId !== auth.user.userId ||
        envelope.senderDeviceId !== auth.session.deviceId ||
        !verifyMemberKeyEnvelope(envelope, auth.user)) {
      return 'Koperta memberKeys nie ma poprawnego podpisu lub kluczy konta.';
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

function timingSafeTextEqual(left, right) {
  const a = Buffer.from(String(left || ''), 'utf8');
  const b = Buffer.from(String(right || ''), 'utf8');
  return a.length === b.length && a.length > 0 && crypto.timingSafeEqual(a, b);
}

function finiteNumber(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

function sessionCreatedAtMs(session, fallback = Date.now()) {
  return finiteNumber(Date.parse(session?.createdAt), fallback);
}

function sessionLastSeenAtMs(session, fallback = Date.now()) {
  if (Number.isFinite(session?.lastSeenAtMs)) return session.lastSeenAtMs;
  if (Number.isFinite(session?.lastSeenAtWriteMs)) return session.lastSeenAtWriteMs;
  return sessionCreatedAtMs(session, fallback);
}

export class V2Store {
  constructor({ dataDir, limits = {}, sessionTtlMs, sessionIdleTtlMs } = {}) {
    this.dataDir = path.resolve(dataDir);
    fs.mkdirSync(this.dataDir, { recursive: true });
    this.limits = Object.freeze({
      messageBytes: limits.messageBytes ?? MAX_STORED_MESSAGE_BYTES,
      messagesPerConversation: limits.messagesPerConversation ?? MAX_MESSAGES_PER_CONVERSATION,
      conversationBytes: limits.conversationBytes ?? MAX_CONVERSATION_BYTES,
      accountBytes: limits.accountBytes ?? MAX_ACCOUNT_BYTES,
      instanceBytes: limits.instanceBytes ?? MAX_INSTANCE_BYTES,
      dailyAccountBytes: limits.dailyAccountBytes ?? MAX_DAILY_ACCOUNT_BYTES,
      minFreeDiskBytes: limits.minFreeDiskBytes ?? MIN_FREE_DISK_BYTES
    });
    this.sessionPolicy = Object.freeze({
      ttlMs: sessionTtlMs ?? DEFAULT_SESSION_TTL_MS,
      idleTtlMs: sessionIdleTtlMs ?? DEFAULT_SESSION_IDLE_TTL_MS
    });
    this.database = new SqliteStateStore(this.dataDir);
    this.usersFile = path.join(this.dataDir, 'users.json');
    this.sessionsFile = path.join(this.dataDir, 'sessions.json');
    this.conversationsFile = path.join(this.dataDir, 'conversations.json');
    this.messagesFile = path.join(this.dataDir, 'messages.json');
    const normalizedState = this.database.readState('normalized-state-v1', false) === true;
    this.users = normalizedState
      ? this.database.readEntities('users', 'users')
      : this.database.hasState('users')
      ? this.database.readState('users', null)
      : readJson(this.usersFile, { v: 1, users: {} });
    this.sessions = normalizedState
      ? this.database.readEntities('sessions', 'sessions')
      : this.database.hasState('sessions')
      ? this.database.readState('sessions', null)
      : readJson(this.sessionsFile, { v: 1, sessions: {} });
    this.conversations = normalizedState
      ? this.database.readEntities('conversations', 'conversations')
      : this.database.hasState('conversations')
      ? this.database.readState('conversations', null)
      : readJson(this.conversationsFile, { v: 1, conversations: {} });
    this.invites = normalizedState
      ? this.database.readEntities('invitations', 'invites')
      : this.database.readState('invites', { v: 1, invites: {} });
    this.messages = !normalizedState && fs.existsSync(this.messagesFile)
      ? readJson(this.messagesFile, { v: 1, messages: {} })
      : { v: 1, messages: {} };
    if (!normalizedState) {
      this.database.importLegacyMessages(this.messages.messages);
      this.database.replaceEntities('users', this.users.users);
      this.database.replaceEntities('sessions', this.sessions.sessions);
      this.database.replaceEntities('conversations', this.conversations.conversations);
      this.database.replaceEntities('invitations', this.invites.invites);
      this.database.writeState('normalized-state-v1', true);
    }
    this.normalizePersistedSessions();
    this.anonymizeStoredDeviceNames();
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
      deviceName: sanitizeDeviceName(deviceName),
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

  normalizePersistedSessions() {
    const now = Date.now();
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (!session) continue;
      let changed = false;
      const createdAtMs = sessionCreatedAtMs(session, now);
      const policyExpiry = createdAtMs + this.sessionPolicy.ttlMs;
      if (!Number.isFinite(session.expiresAtMs) || session.expiresAtMs > policyExpiry) {
        session.expiresAtMs = policyExpiry;
        changed = true;
      }
      if (!Number.isFinite(session.lastSeenAtMs)) {
        session.lastSeenAtMs = sessionLastSeenAtMs(session, now);
        changed = true;
      }
      if (!Number.isFinite(session.lastSeenAtWriteMs)) {
        session.lastSeenAtWriteMs = session.lastSeenAtMs;
        changed = true;
      }
      if (changed) this.database.upsertSession(hash, session);
    }
  }

  anonymizeStoredDeviceNames() {
    for (const user of Object.values(this.users.users)) {
      let changed = false;
      for (const device of Object.values(user.devices || {})) {
        const safeName = sanitizeDeviceName(device.deviceName);
        if (device.deviceName !== safeName) {
          device.deviceName = safeName;
          changed = true;
        }
      }
      if (changed) this.persistUser(user);
    }
  }

  persistUser(user) {
    if (!user?.userId) return;
    this.database.upsertUser(user.userId, user);
  }

  persistUsers() {
    for (const user of Object.values(this.users.users)) this.persistUser(user);
  }

  persistSession(hash, session) {
    if (!hash || !session) return;
    this.database.upsertSession(hash, session);
  }

  deleteSession(hash) {
    if (!hash) return;
    this.database.deleteSession(hash);
  }

  persistSessions() {
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      this.persistSession(hash, session);
    }
  }

  persistConversation(conversation) {
    if (!conversation?.conversationId) return;
    this.database.upsertConversation(conversation.conversationId, conversation);
  }

  persistConversations() {
    for (const conversation of Object.values(this.conversations.conversations)) {
      this.persistConversation(conversation);
    }
  }

  persistInvite(invite) {
    if (!invite?.inviteId) return;
    this.database.upsertInvite(invite.inviteId, invite);
  }

  persistInvites() {
    for (const invite of Object.values(this.invites.invites)) this.persistInvite(invite);
  }

  createInvite({ createdBy = 'admin', restrictedUsername = '', expiresInSeconds = 86400,
    maxUses = 1 } = {}) {
    const token = crypto.randomBytes(32).toString('base64url');
    const inviteId = randomId();
    const now = Date.now();
    const invite = {
      inviteId,
      tokenHash: tokenHash(token),
      expiresAt: new Date(now + Math.min(7 * 86400, Math.max(300, expiresInSeconds)) * 1000).toISOString(),
      maxUses: Math.min(10, Math.max(1, maxUses)),
      uses: 0,
      createdBy,
      restrictedUsername: normalizeUsername(restrictedUsername),
      createdAt: new Date(now).toISOString(),
      usedAt: null
    };
    this.invites.invites[inviteId] = invite;
    this.persistInvite(invite);
    return { inviteId, token, ...invite, tokenHash: undefined };
  }

  consumeInvite(token, username) {
    const hash = tokenHash(token);
    const invite = this.database.consumeInviteAtomically(hash, normalizeUsername(username));
    if (!invite) {
      return false;
    }
    this.invites.invites[invite.inviteId] = invite;
    return true;
  }

  persistMessages(message) {
    this.database.appendMessage(message);
  }

  persistMessageAndConversation(message, conversation, streamCheck) {
    return this.database.appendMessageAndUpdateConversation(
      message,
      conversation || this.conversations.conversations[message.conversationId],
      streamCheck
    );
  }

  pruneSessions() {
    const now = Date.now();
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      const idleExpired = session &&
        this.sessionPolicy.idleTtlMs > 0 &&
        sessionLastSeenAtMs(session, now) + this.sessionPolicy.idleTtlMs <= now;
      if (!session || session.expiresAtMs <= now || idleExpired) {
        delete this.sessions.sessions[hash];
        this.deleteSession(hash);
        this.closeSessionSockets(hash, 'session_expired');
        this.revokeWsTicketsForSession(hash);
      }
    }
  }

  userByName(username) {
    const normalized = normalizeUsername(username);
    return Object.values(this.users.users).find((user) => user.username === normalized) || null;
  }

  publicUser(user, { includeDevices = true } = {}) {
    const devices = {};
    if (includeDevices) {
      for (const [deviceId, device] of Object.entries(user.devices || {})) {
        devices[deviceId] = {
          deviceId,
          deviceName: sanitizeDeviceName(device.deviceName),
          deviceCertificate: isValidDeviceCertificate(device.deviceCertificate)
            ? device.deviceCertificate
            : null
        };
      }
    }
    return {
      userId: user.userId,
      username: user.username,
      displayName: user.displayName || user.username,
      keyAgreementPublicKey: user.keyAgreementPublicKey,
      identityPublicKey: user.identityPublicKey || '',
      keyAgreementPublicKeySignature: user.keyAgreementPublicKeySignature || '',
      devices,
      deviceList: includeDevices && isValidDeviceList(user.deviceList) ? user.deviceList : null,
      deviceListHash: includeDevices && typeof user.deviceListHash === 'string' ? user.deviceListHash : '',
      identityRotationProof: user.identityRotationProof || null,
      updatedAt: user.updatedAt
    };
  }

  publicSession(hash, session, currentHash = '') {
    const user = this.users.users[session.userId];
    const device = user?.devices?.[session.deviceId] || {};
    const lastSeenAtMs = sessionLastSeenAtMs(session);
    return {
      sessionId: crypto.createHash('sha256').update(hash).digest('base64url').slice(0, 22),
      current: hash === currentHash,
      userId: session.userId,
      deviceId: session.deviceId,
      deviceName: sanitizeDeviceName(device.deviceName),
      createdAt: session.createdAt || new Date(lastSeenAtMs).toISOString(),
      lastSeenAt: new Date(lastSeenAtMs).toISOString(),
      expiresAt: new Date(session.expiresAtMs).toISOString(),
      idleExpiresAt: this.sessionPolicy.idleTtlMs > 0
        ? new Date(lastSeenAtMs + this.sessionPolicy.idleTtlMs).toISOString()
        : null
    };
  }

  createSession(user, deviceId, deviceName) {
    if (isDeviceRevoked(user, deviceId)) {
      throw new Error('Urzadzenie zostalo uniewaznione.');
    }
    const token = crypto.randomBytes(32).toString('base64url');
    const now = Date.now();
    const expiresAtMs = now + this.sessionPolicy.ttlMs;
    user.devices ||= {};
    const previousDevice = user.devices[deviceId] || {};
    user.devices[deviceId] = {
      ...previousDevice,
      deviceId,
      deviceName: sanitizeDeviceName(deviceName),
      lastSeenAt: new Date(now).toISOString()
    };
    const hash = tokenHash(token);
    this.sessions.sessions[hash] = {
      userId: user.userId,
      deviceId,
      createdAt: new Date(now).toISOString(),
      lastSeenAtMs: now,
      lastSeenAtWriteMs: now,
      expiresAtMs
    };
    this.persistUser(user);
    this.persistSession(hash, this.sessions.sessions[hash]);
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
      this.deleteSession(hash);
      this.closeSessionSockets(hash, 'device_revoked');
      this.revokeWsTicketsForSession(hash);
      return null;
    }
    user.devices ||= {};
    const now = Date.now();
    session.lastSeenAtMs = now;
    if (user.devices[session.deviceId]) {
      if (!Number.isFinite(session.lastSeenAtWriteMs) ||
          now - session.lastSeenAtWriteMs >= LAST_SEEN_WRITE_INTERVAL_MS) {
        user.devices[session.deviceId].lastSeenAt = nowIso();
        session.lastSeenAtWriteMs = now;
        this.persistUser(user);
        this.persistSession(hash, session);
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
    if (existed) this.deleteSession(sessionHash);
    this.revokeWsTicketsForSession(sessionHash);
    this.closeSessionSockets(sessionHash, 'session_revoked');
    return existed;
  }

  revokeAllSessionsForUser(userId) {
    let changed = false;
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (session.userId === userId) {
        delete this.sessions.sessions[hash];
        this.deleteSession(hash);
        this.revokeWsTicketsForSession(hash);
        this.closeSessionSockets(hash, 'session_revoked');
        changed = true;
      }
    }
    this.closeUserSockets(userId, 'session_revoked');
    return changed;
  }

  revokeDeviceSessions(userId, deviceIds) {
    const revoked = new Set(deviceIds);
    if (revoked.size === 0) return;
    let changed = false;
    for (const [hash, session] of Object.entries(this.sessions.sessions)) {
      if (session.userId === userId && revoked.has(session.deviceId)) {
        delete this.sessions.sessions[hash];
        this.deleteSession(hash);
        this.revokeWsTicketsForSession(hash);
        this.closeSessionSockets(hash, 'device_revoked');
        changed = true;
      }
    }
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

    if (method === 'POST' && url.pathname === '/v2/admin/invites') {
      if (!timingSafeTextEqual(req.headers['x-admin-token'], options.adminToken)) {
        return sendJson(res, 401, { ok: false, error: 'Brak autoryzacji administratora.' });
      }
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      const invite = store.createInvite({
        createdBy: 'admin',
        restrictedUsername: body.restrictedUsername,
        expiresInSeconds: Number(body.expiresInSeconds) || 86400,
        maxUses: Number(body.maxUses) || 1
      });
      return sendJson(res, 201, { ok: true, invite });
    }

    if (method === 'POST' && url.pathname === '/v2/register') {
      const registrationMode = options.registrationMode || 'disabled';
      if (registrationMode === 'disabled') {
        return sendJson(res, 403, { ok: false, error: 'Rejestracja publiczna jest wylaczona.' });
      }
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      const username = normalizeUsername(body.username);
      if (!allowAuthAttempt(req, username)) return sendJson(res, 429, { ok: false, error: 'Sprobuj ponownie pozniej.' });
      const password = String(body.password || '');
      const deviceId = String(body.deviceId || randomId());
      if (!safeUsername(username)) return sendJson(res, 400, { ok: false, error: 'Niepoprawna nazwa konta.' });
      if (password.length < 8) return sendJson(res, 400, { ok: false, error: 'Haslo ma minimum 8 znakow.' });
      return await store.withAccountLock(`registration:${username}`, async () => {
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
      if (!isValidVaultKdf(body.vaultKdf)) {
        return sendJson(res, 400, { ok: false, error: 'Nowe konto wymaga bezpiecznych parametrow Argon2id.' });
      }
      const passwordHash = await hashPassword(password);
      if (registrationMode === 'invite' &&
          !store.consumeInvite(String(body.inviteToken || ''), username)) {
        return sendJson(res, 403, { ok: false, error: 'Niepoprawne lub wygasle zaproszenie.' });
      }

      const userId = randomId();
      const user = {
        userId,
        username,
        displayName: String(body.displayName || username).slice(0, 80),
        password: passwordHash,
        vaultSalt: typeof body.vaultSalt === 'string' && body.vaultSalt.length >= 16
          ? body.vaultSalt
          : crypto.randomBytes(16).toString('base64url'),
        keyAgreementPublicKey: body.keyAgreementPublicKey,
        identityPublicKey: body.identityPublicKey,
        keyAgreementPublicKeySignature: body.keyAgreementPublicKeySignature,
        identityRotationProof: isValidIdentityRotationProof(body.identityRotationProof) ? body.identityRotationProof : null,
        encryptedVault: isObject(body.encryptedVault) ? body.encryptedVault : null,
        vaultKdf: body.vaultKdf,
        devices: {},
        createdAt: nowIso(),
        updatedAt: nowIso()
      };
      store.users.users[userId] = user;
      let session;
      try {
        session = store.createSession(user, deviceId, body.deviceName);
      } catch (error) {
        console.error(JSON.stringify({ event: 'registration_session_failed', error: String(error?.stack || error) }));
        return sendJson(res, 403, { ok: false, error: 'REGISTRATION_FAILED' });
      }
      recordAuthSuccess(req, username);
      return sendJson(res, 200, {
        ok: true,
        token: session.token,
        expiresAt: session.expiresAt,
        user: store.publicUser(user),
        deviceId,
        vaultSalt: user.vaultSalt,
        encryptedVault: user.encryptedVault
      });
      });
    }

    if (method === 'POST' && url.pathname === '/v2/login') {
      const body = await readBody(req, AUTH_MAX_BODY_BYTES);
      if (!allowAuthAttempt(req, body.username)) return sendJson(res, 429, { ok: false, error: 'Sprobuj ponownie pozniej.' });
      const user = store.userByName(body.username);
      const passwordResult = user
        ? await verifyPasswordDetailed(String(body.password || ''), user.password)
        : { ok: false, needsUpgrade: false };
      if (!user || !passwordResult.ok) {
        return sendJson(res, 401, { ok: false, error: 'Niepoprawny login albo haslo.' });
      }
      recordAuthSuccess(req, body.username);
      if (passwordResult.needsUpgrade) {
        user.password = await hashPassword(String(body.password || ''));
        user.updatedAt = nowIso();
        store.persistUser(user);
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
        vaultHash: typeof user.vaultHash === 'string' ? user.vaultHash : '',
        vaultKdf: isValidVaultKdf(user.vaultKdf, { allowLegacy: true })
          ? user.vaultKdf
          : null
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
      return sendJson(res, 200, {
        ok: true,
        user: store.publicUser(auth.user),
        deviceId: auth.session.deviceId,
        session: store.publicSession(auth.tokenHash, auth.session, auth.tokenHash)
      });
    }

    if (method === 'GET' && url.pathname === '/v2/sessions') {
      const sessions = Object.entries(store.sessions.sessions)
        .filter(([, session]) => session.userId === auth.user.userId)
        .map(([hash, session]) => store.publicSession(hash, session, auth.tokenHash))
        .sort((a, b) => String(b.lastSeenAt).localeCompare(String(a.lastSeenAt)));
      return sendJson(res, 200, { ok: true, sessions });
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
      const exactUsername = normalizeUsername(url.searchParams.get('username'));
      if (!exactUsername) {
        return sendJson(res, 200, { ok: true, users: [] });
      }
      if (!safeUsername(exactUsername)) {
        return sendJson(res, 400, { ok: false, error: 'Wyszukiwanie wymaga dokladnego loginu.' });
      }
      if (!allowAuthAttempt(req, `directory:${exactUsername}`)) {
        return sendJson(res, 429, { ok: false, error: 'Sprobuj ponownie pozniej.' });
      }
      const visibleUserIds = new Set([auth.user.userId]);
      for (const conversation of store.conversationsForUser(auth.user.userId)) {
        for (const memberId of conversation.memberIds) visibleUserIds.add(memberId);
      }
      const users = Object.values(store.users.users)
        .filter((user) => user.userId !== auth.user.userId &&
          (visibleUserIds.has(user.userId) || user.username === exactUsername))
        .map((user) => store.publicUser(user, {
          includeDevices: visibleUserIds.has(user.userId)
        }))
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
      if (!isValidDeviceCertificate(body.deviceCertificate) ||
          body.deviceCertificate.accountId !== auth.user.userId ||
          body.deviceCertificate.deviceId !== auth.session.deviceId) {
        return sendJson(res, 400, { ok: false, error: 'Aktualizacja kluczy wymaga certyfikatu aktualnego urzadzenia.' });
      }
      const serverOrigin = body.deviceCertificate.serverOrigin;
      if ((auth.user.serverOrigin && auth.user.serverOrigin !== serverOrigin) ||
          (body.deviceList?.serverOrigin && body.deviceList.serverOrigin !== serverOrigin)) {
        return sendJson(res, 400, { ok: false, error: 'Origin kluczy nie zgadza sie z kontem.' });
      }
      const identityChanged = body.identityPublicKey !== auth.user.identityPublicKey;
      if (identityChanged && !verifyIdentityRotation(
        auth.user,
        body.identityPublicKey,
        body.keyAgreementPublicKey,
        body.identityRotationProof,
        serverOrigin
      )) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny kryptograficzny dowod rotacji tozsamosci.' });
      }
      if (!identityChanged && body.identityRotationProof !== undefined &&
          body.identityRotationProof !== null &&
          canonicalJson(body.identityRotationProof) !== canonicalJson(auth.user.identityRotationProof)) {
        return sendJson(res, 400, { ok: false, error: 'Nieoczekiwany dowod rotacji tozsamosci.' });
      }
      if (!verifyKeyAgreementBinding(
        auth.user.userId,
        serverOrigin,
        body.identityPublicKey,
        body.keyAgreementPublicKey,
        body.keyAgreementPublicKeySignature
      )) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny podpis klucza X25519.' });
      }
      if (!verifyDeviceCertificateSignature(
        auth.user.userId,
        body.identityPublicKey,
        body.deviceCertificate
      )) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny lub wygasly certyfikat urzadzenia.' });
      }
      if (!isValidDeviceList(body.deviceList) ||
          !verifyDeviceList(auth.user.userId, body.identityPublicKey, body.deviceList)) {
        return sendJson(res, 400, { ok: false, error: 'Niepoprawny podpis listy urzadzen.' });
      }
      {
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
        const calculatedListHash = sha256Hex(body.deviceList);
        const idempotentList = currentEpoch > 0 &&
          body.deviceList.deviceListEpoch === currentEpoch &&
          body.deviceListHash === currentHash &&
          canonicalJson(body.deviceList) === canonicalJson(auth.user.deviceList);
        const nextList = body.deviceList.deviceListEpoch === currentEpoch + 1 &&
          body.deviceList.previousDeviceListHash === currentHash &&
          body.deviceListHash === calculatedListHash;
        if (!idempotentList && !nextList) {
          return sendJson(res, 409, { ok: false, error: 'Lista urzadzen nie kontynuuje podpisanego lancucha.' });
        }
        const active = body.deviceList.devices.find((item) =>
          item.deviceId === auth.session.deviceId);
        if (!active ||
            active.deviceSigningPublicKey !== body.deviceCertificate.deviceSigningPublicKey ||
            active.deviceEpoch !== body.deviceCertificate.deviceEpoch ||
            active.certificateHash !== sha256Hex(body.deviceCertificate)) {
          return sendJson(res, 400, { ok: false, error: 'Lista urzadzen nie zawiera aktualnego certyfikatu.' });
        }
      }
      const previouslyRevoked = revokedDeviceIds(auth.user);
      auth.user.keyAgreementPublicKey = body.keyAgreementPublicKey;
      auth.user.identityPublicKey = body.identityPublicKey;
      auth.user.keyAgreementPublicKeySignature = body.keyAgreementPublicKeySignature;
      auth.user.serverOrigin = serverOrigin;
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
      store.persistUser(auth.user);
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
      if (!isValidVaultKdf(body.vaultKdf)) {
        return sendJson(res, 400, { ok: false, error: 'Zapis vaultu wymaga Argon2id.' });
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
        user.vaultKdf = body.vaultKdf;
        user.vaultEpoch = currentEpoch + 1;
        user.vaultHash = crypto.createHash('sha256').update(serialized).digest('base64url');
        user.updatedAt = nowIso();
        store.persistUser(user);
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
        ,vaultKdf: isValidVaultKdf(auth.user.vaultKdf, { allowLegacy: true })
          ? auth.user.vaultKdf
          : null
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
      const memberKeysError = validateMemberKeys(body.memberKeys || {}, memberIds, auth);
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
        store.persistConversation(conversation);
        store.broadcast(memberIds, { type: 'conversation', conversation });
      } else if (isObject(body.memberKeys)) {
        for (const [userId, envelope] of Object.entries(body.memberKeys)) {
          if (conversation.memberKeys[userId] === undefined) {
            conversation.memberKeys[userId] = envelope;
          }
        }
        conversation.updatedAt = nowIso();
        store.persistConversation(conversation);
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
        const memberKeysError = validateMemberKeys(body.memberKeys, conversation.memberIds, auth);
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
        store.persistConversation(conversation);
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
      if (conversation.type !== 'direct') {
        return sendJson(res, 409, {
          ok: false,
          error: 'Wysylanie do grup jest zablokowane do czasu bezpiecznej rotacji kluczy.'
        });
      }
      const payloadError = validateCloudMessagePayload(body.payload, body, auth);
      if (payloadError) {
        return sendJson(res, 400, { ok: false, error: payloadError });
      }
      if (body.payload.aad.keyEpoch !== conversation.keyEpoch) {
        return sendJson(res, 409, { ok: false, error: 'Wiadomosc uzywa nieaktualnej epoki klucza.' });
      }
      const payloadBytes = Buffer.byteLength(JSON.stringify(body.payload), 'utf8');
      if (payloadBytes > store.limits.messageBytes) {
        return sendJson(res, 413, { ok: false, error: 'Wiadomosc jest za duza.' });
      }
      const quotaError = storageQuotaError(
        store,
        auth.user.userId,
        conversationId,
        payloadBytes
      );
      if (quotaError) return sendJson(res, quotaError.status, { ok: false, error: quotaError.error });
      const counter = body.payload.aad.messageCounter;
      const previousHash = body.payload.aad.previousMessageHash;
      const list = store.messages.messages[conversationId] || [];
      const message = {
        messageId: String(body.messageId || randomId()),
        conversationId,
        senderUserId: auth.user.userId,
        senderDeviceId: auth.session.deviceId,
        messageCounter: counter,
        payloadHash: cloudMessageHash(body.payload),
        payloadBytes,
        createdAt: nowIso(),
        payload: body.payload
      };
      const nextConversation = { ...conversation, updatedAt: message.createdAt };
      try {
        store.persistMessageAndConversation(message, nextConversation, {
          previousMessageHash: previousHash,
          genesisHash: CLOUD_MESSAGE_GENESIS_HASH
        });
      } catch (error) {
        if (error?.code === 'MESSAGE_STREAM_CONFLICT') {
          return sendJson(res, 409, { ok: false, error: error.message });
        }
        if (String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
          return sendJson(res, 409, { ok: false, error: 'Wiadomosc narusza unikalnosc strumienia lub identyfikatora.' });
        }
        throw error;
      }
      list.push(message);
      store.messages.messages[conversationId] = list;
      conversation.updatedAt = nextConversation.updatedAt;
      store.broadcast(conversation.memberIds, { type: 'message', message });
      return sendJson(res, 200, { ok: true, message });
      });
    }

    return sendJson(res, 404, { ok: false, error: 'Nieznany endpoint v2.' });
  } catch (error) {
    const requestId = crypto.randomUUID();
    console.error(JSON.stringify({ requestId, error: String(error?.stack || error) }));
    if (error?.code === 'SERVER_BUSY') {
      return sendJson(res, 503, { ok: false, error: 'SERVER_BUSY', requestId });
    }
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

export const securityTestInternals = Object.freeze({
  allowAuthAttempt,
  canonicalJson,
  cloudMessageHash,
  genesisHash: CLOUD_MESSAGE_GENESIS_HASH,
  hashPassword,
  messageStreamError,
  recordAuthSuccess,
  resetAuthRateLimits,
  scryptAsync,
  storageQuotaError,
  validateCloudMessagePayload,
  validateMemberKeys,
  verifyPassword,
  verifyPasswordDetailed,
  verifyDeviceCertificate,
  verifyMemberKeyEnvelope
});
