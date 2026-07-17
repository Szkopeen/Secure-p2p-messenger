import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import {
  V2Store,
  handleV2Http,
  securityTestInternals as security
} from '../src/v2Store.js';
import { safeOpenUpdateFile } from '../src/updateFiles.js';

async function httpRequest(store, method, pathname, { body, rawBody, token, headers = {} } = {}) {
  const chunks = rawBody !== undefined
    ? [Buffer.from(rawBody)]
    : body === undefined
      ? []
      : [Buffer.from(JSON.stringify(body))];
  const req = Readable.from(chunks);
  req.method = method;
  req.headers = { ...headers };
  if (token) req.headers.authorization = `Bearer ${token}`;
  req.clientIp = '127.0.0.1';
  let status = 0;
  let responseBody = '';
  const res = {
    writeHead(code) { status = code; },
    end(chunk = '') { responseBody += String(chunk); }
  };
  await handleV2Http(
    store,
    req,
    res,
    new URL(pathname, 'https://chat.example'),
    { registrationMode: 'disabled', adminToken: '' }
  );
  return { status, body: responseBody ? JSON.parse(responseBody) : null };
}

function rawPublicKey(publicKey) {
  return publicKey.export({ format: 'der', type: 'spki' })
    .subarray(-32)
    .toString('base64url');
}

function sha256Canonical(value) {
  return crypto.createHash('sha256')
    .update(Buffer.from(security.canonicalJson(value)))
    .digest('hex');
}

function authReq(ip) {
  return {
    clientIp: ip,
    socket: { remoteAddress: ip }
  };
}

function createFileSymlinkOrSkip(t, target, link) {
  try {
    fs.symlinkSync(target, link, 'file');
    return true;
  } catch (error) {
    t.skip(`System nie pozwala utworzyc symlinkow w tym srodowisku: ${error.code || error.message}`);
    return false;
  }
}

async function importFreshConfig() {
  const url = new URL('../src/config.js', import.meta.url);
  url.search = crypto.randomUUID();
  return import(url.href);
}

function signedProtocolFixture() {
  const identity = crypto.generateKeyPairSync('ed25519');
  const device = crypto.generateKeyPairSync('ed25519');
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const createdAt = new Date().toISOString();
  const unsignedCertificate = {
    v: 1,
    protocol: 'secure-chat/device-certificate/v1',
    accountId: userId,
    serverOrigin: 'https://chat.example',
    deviceId,
    deviceSigningPublicKey: rawPublicKey(device.publicKey),
    deviceEpoch: 1,
    createdAt
  };
  const certificate = {
    ...unsignedCertificate,
    signature: crypto.sign(
      null,
      Buffer.from(security.canonicalJson(unsignedCertificate)),
      identity.privateKey
    ).toString('base64url')
  };
  const user = {
    userId,
    identityPublicKey: rawPublicKey(identity.publicKey),
    keyAgreementPublicKey: 'agreement-key-public',
    deviceList: {
      v: 1,
      accountId: userId,
      serverOrigin: 'https://chat.example',
      deviceListEpoch: 1,
      previousDeviceListHash: '',
      identityRotationEpoch: 0,
      devices: [{
        deviceId,
        deviceSigningPublicKey: rawPublicKey(device.publicKey),
        certificateHash: sha256Canonical(certificate),
        addedAt: createdAt,
        deviceEpoch: 1
      }],
      revokedDevices: [],
      signature: 'signed-device-list',
      updatedAt: createdAt
    }
  };
  const messageId = crypto.randomUUID();
  const unsignedMessage = {
    v: 1,
    protocol: 'secure-p2p-cloud-message/v1',
    messageId,
    aad: {
      v: 1,
      protocol: 'secure-p2p-cloud-message/v1',
      protocolVersion: 2,
      conversationId: 'conversation-1',
      messageId,
      senderUserId: userId,
      senderDeviceId: deviceId,
      keyEpoch: 1,
      messageCounter: 1,
      previousMessageHash: security.genesisHash,
      contentType: 'text',
      createdAt,
      plaintextBytes: 4
    },
    nonce: 'nonce-value',
    ciphertext: 'ciphertext-value',
    mac: 'mac-value',
    compression: 'zlib'
  };
  const digest = crypto.createHash('sha256').update(Buffer.from(
    security.canonicalJson({
      v: 1,
      protocol: 'secure-chat/device-message/v1',
      envelope: unsignedMessage
    })
  )).digest();
  const payload = {
    ...unsignedMessage,
    deviceCertificate: certificate,
    deviceSignature: crypto.sign(null, digest, device.privateKey).toString('base64url')
  };
  const auth = { user, session: { deviceId } };
  return { auth, certificate, device, identity, payload, user };
}

function signedMemberKeyEnvelope({
  auth,
  identity,
  conversationId = 'conversation-1',
  keyEpoch = 1,
  recipientUserId = auth.user.userId,
  recipientPublicKey = auth.user.keyAgreementPublicKey,
  legacy = false
}) {
  const unsigned = {
    v: 1,
    protocolVersion: 1,
    algorithm: 'X25519-HKDF-SHA256-AES-256-GCM',
    conversationId,
    keyEpoch,
    senderUserId: auth.user.userId,
    senderDeviceId: auth.session.deviceId,
    recipientUserId,
    senderPublicKey: auth.user.keyAgreementPublicKey,
    senderIdentityPublicKey: auth.user.identityPublicKey,
    ...(legacy ? {} : {
      recipientPublicKey,
      keyWrapAadVersion: 2
    }),
    nonce: `nonce-${keyEpoch}`,
    ciphertext: `ciphertext-${keyEpoch}`,
    mac: `mac-${keyEpoch}`
  };
  return {
    ...unsigned,
    signature: crypto.sign(
      null,
      Buffer.from(security.canonicalJson(unsigned)),
      identity.privateKey
    ).toString('base64url')
  };
}

function resignMessage(payload, privateKey) {
  const unsigned = { ...payload };
  delete unsigned.deviceCertificate;
  delete unsigned.deviceSignature;
  const digest = crypto.createHash('sha256').update(Buffer.from(
    security.canonicalJson({
      v: 1,
      protocol: 'secure-chat/device-message/v1',
      envelope: unsigned
    })
  )).digest();
  return {
    ...payload,
    deviceSignature: crypto.sign(null, digest, privateKey).toString('base64url')
  };
}

function messageRequestBody(payload, overrides = {}) {
  return {
    messageId: payload.messageId,
    conversationId: payload.aad?.conversationId,
    ...overrides
  };
}

function fixture() {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-test-'));
  const store = new V2Store({ dataDir });
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const rawPublicKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  const user = {
    userId: crypto.randomUUID(), username: 'alice', displayName: 'Alice',
    identityPublicKey: rawPublicKey, keyAgreementPublicKey: 'x'.repeat(32),
    keyAgreementPublicKeySignature: 's'.repeat(32), devices: {}, updatedAt: new Date().toISOString()
  };
  store.users.users[user.userId] = user;
  store.persistUsers();
  return { dataDir, store, user, privateKey };
}

test('wektor klient-serwer ma identyczny canonical JSON i SHA-256', () => {
  const vector = JSON.parse(fs.readFileSync(
    new URL('../../test-vectors/protocol-canonical-v1.json', import.meta.url),
    'utf8'
  ));
  assert.equal(security.canonicalJson(vector.value), vector.canonical);
  assert.equal(sha256Canonical(vector.value), vector.sha256);
});

test('konfiguracja akceptuje produkcyjny limit WebSocket 16 MiB', async () => {
  const previousPayload = process.env.MAX_PAYLOAD_BYTES;
  const previousAdmin = process.env.ADMIN_TOKEN;
  try {
    process.env.MAX_PAYLOAD_BYTES = String(16 * 1024 * 1024);
    process.env.ADMIN_TOKEN = '';
    const { config } = await importFreshConfig();
    assert.equal(config.maxPayloadBytes, 16 * 1024 * 1024);
  } finally {
    if (previousPayload === undefined) delete process.env.MAX_PAYLOAD_BYTES;
    else process.env.MAX_PAYLOAD_BYTES = previousPayload;
    if (previousAdmin === undefined) delete process.env.ADMIN_TOKEN;
    else process.env.ADMIN_TOKEN = previousAdmin;
  }
});

test('body HTTP zwraca precyzyjne statusy dla media type, rozmiaru i JSON', async () => {
  const store = new V2Store({ dataDir: fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-body-')) });
  const unsupported = await httpRequest(store, 'POST', '/v2/login', {
    rawBody: '{}',
    headers: { 'content-type': 'text/plain' }
  });
  assert.equal(unsupported.status, 415);
  assert.equal(unsupported.body.error, 'UNSUPPORTED_MEDIA_TYPE');

  const tooLarge = await httpRequest(store, 'POST', '/v2/login', {
    rawBody: '"'.padEnd(33 * 1024, 'x'),
    headers: { 'content-type': 'application/json' }
  });
  assert.equal(tooLarge.status, 413);
  assert.equal(tooLarge.body.error, 'PAYLOAD_TOO_LARGE');

  const invalid = await httpRequest(store, 'POST', '/v2/login', {
    rawBody: '{"username":',
    headers: { 'content-type': 'application/json' }
  });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.error, 'INVALID_JSON');
});

test('pliki aktualizacji odrzucaja symlink manifestu i artefaktu', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-updates-'));
  const updatesDir = path.join(root, 'updates');
  const filesDir = path.join(updatesDir, 'files');
  fs.mkdirSync(filesDir, { recursive: true });
  const secret = path.join(root, 'secret.txt');
  fs.writeFileSync(secret, 'tajny plik spoza katalogu aktualizacji', 'utf8');

  const manifestLink = path.join(updatesDir, 'manifest.json');
  if (!createFileSymlinkOrSkip(t, secret, manifestLink)) return;
  assert.throws(
    () => safeOpenUpdateFile(updatesDir, 'manifest.json', { maxBytes: 1024 * 1024 }),
    { code: 'NOT_FOUND' }
  );

  const artifactLink = path.join(filesDir, 'client.zip');
  if (!createFileSymlinkOrSkip(t, secret, artifactLink)) return;
  assert.throws(
    () => safeOpenUpdateFile(filesDir, 'client.zip'),
    { code: 'NOT_FOUND' }
  );

  const manifest = path.join(updatesDir, 'valid-manifest.json');
  fs.writeFileSync(manifest, '{}', 'utf8');
  const opened = safeOpenUpdateFile(updatesDir, 'valid-manifest.json', { maxBytes: 1024 * 1024 });
  try {
    assert.equal(opened.stat.size, 2);
  } finally {
    fs.closeSync(opened.fd);
  }
});

test('limiter autoryzacji nie blokuje globalnie konta z nowych adresow IP', () => {
  security.resetAuthRateLimits();
  try {
    for (let index = 0; index < 20; index += 1) {
      assert.equal(security.allowAuthAttempt(authReq(`10.0.0.${index + 1}`), 'alice'), true);
    }
    assert.equal(security.allowAuthAttempt(authReq('10.0.1.1'), 'alice'), true);
    assert.equal(security.allowAuthAttempt(authReq('10.0.1.1'), 'bob'), true);
    security.recordAuthSuccess(authReq('10.0.0.1'), 'alice');
    assert.equal(security.allowAuthAttempt(authReq('10.0.0.1'), 'alice'), true);
  } finally {
    security.resetAuthRateLimits();
  }
});

test('limiter autoryzacji blokuje powtarzane proby z tej samej pary IP i konta', () => {
  security.resetAuthRateLimits();
  try {
    const req = authReq('192.0.2.10');
    for (let index = 0; index < 10; index += 1) {
      assert.equal(security.allowAuthAttempt(req, 'alice'), true);
    }
    assert.equal(security.allowAuthAttempt(req, 'alice'), false);
    assert.equal(security.allowAuthAttempt(req, 'bob'), true);
  } finally {
    security.resetAuthRateLimits();
  }
});

test('limiter autoryzacji nie usuwa aktywnej blokady IP przy zalewaniu loginami', () => {
  security.resetAuthRateLimits();
  try {
    const lockedIp = authReq('198.51.100.10');
    for (let index = 0; index < 80; index += 1) {
      assert.equal(security.allowAuthAttempt(lockedIp, `spray-${index}`), true);
    }
    assert.equal(security.allowAuthAttempt(lockedIp, 'victim'), false);

    for (let index = 0; index < 6000; index += 1) {
      security.allowAuthAttempt(authReq(`203.0.113.${(index % 250) + 1}`), `flood-${index}`);
    }

    assert.equal(security.allowAuthAttempt(lockedIp, 'after-flood'), false);
  } finally {
    security.resetAuthRateLimits();
  }
});

test('limiter autoryzacji nie pozwala zalewaniem wielu kont zablokowac ofiary globalnie', () => {
  security.resetAuthRateLimits();
  try {
    for (let index = 0; index < 20; index += 1) {
      assert.equal(security.allowAuthAttempt(authReq(`10.10.0.${index + 1}`), 'alice'), true);
    }
    assert.equal(security.allowAuthAttempt(authReq('10.10.1.1'), 'alice'), true);

    for (let index = 0; index < 6000; index += 1) {
      security.allowAuthAttempt(authReq(`203.0.113.${(index % 250) + 1}`), `flood-${index}`);
    }

    assert.equal(security.allowAuthAttempt(authReq('10.10.1.2'), 'alice'), true);
  } finally {
    security.resetAuthRateLimits();
  }
});

test('weryfikacja hasla respektuje zapisane parametry scrypt i oznacza upgrade', async () => {
  const legacy = await security.hashPassword('correct horse', 'fixed-salt', { N: 16384, r: 8, p: 1 });
  const legacyResult = await security.verifyPasswordDetailed('correct horse', legacy);
  assert.equal(legacyResult.ok, true);
  assert.equal(legacyResult.needsUpgrade, true);

  const upgraded = await security.hashPassword('correct horse', 'fixed-salt');
  const upgradedResult = await security.verifyPasswordDetailed('correct horse', upgraded);
  assert.equal(upgradedResult.ok, true);
  assert.equal(upgradedResult.needsUpgrade, false);

  const tamperedParams = { ...legacy, params: { N: 32768, r: 8, p: 1 } };
  const tamperedResult = await security.verifyPasswordDetailed('correct horse', tamperedParams);
  assert.equal(tamperedResult.ok, false);
});

test('jednorazowa normalizacja stanu nie czyta ponownie legacy messages.json', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-normalized-'));
  const firstStore = new V2Store({ dataDir });
  assert.equal(firstStore.database.readState('normalized-state-v1', false), true);
  fs.writeFileSync(path.join(dataDir, 'messages.json'), 'to nie jest json', 'utf8');
  assert.doesNotThrow(() => new V2Store({ dataDir }));
});

test('pelna sesja powstaje dopiero po podpisaniu challenge kluczem z vaultu', () => {
  const { store, user, privateKey } = fixture();
  const pending = store.createPendingLogin(user, crypto.randomUUID(), 'test', 'https://chat.example');
  assert.equal(Object.keys(store.sessions.sessions).length, 0);
  const payload = Buffer.from(JSON.stringify({
    protocol: 'secure-chat/login-challenge/v1',
    serverOrigin: pending.serverOrigin,
    challenge: pending.challenge,
    userId: pending.userId,
    deviceId: pending.deviceId,
    issuedAtMs: pending.issuedAtMs,
    expiresAtMs: pending.expiresAtMs
  }));
  const signature = crypto.sign(null, payload, privateKey).toString('base64');
  assert.ok(store.completePendingLogin(pending.token, signature));
  assert.equal(Object.keys(store.sessions.sessions).length, 1);
  assert.equal(store.completePendingLogin(pending.token, signature), null, 'challenge jest jednorazowy');
});

test('ticket WebSocket jest jednorazowy, a revoke zamyka aktywny socket', () => {
  const { store, user } = fixture();
  const session = store.createSession(user, crypto.randomUUID(), 'test');
  const tokenHash = crypto.createHash('sha256').update(session.token).digest('base64url');
  const auth = { tokenHash, session: store.sessions.sessions[tokenHash], user };
  const ticket = store.issueWsTicket(auth);
  const consumed = store.consumeWsTicket(ticket);
  assert.ok(consumed);
  assert.equal(store.consumeWsTicket(ticket), null);
  class FakeSocket extends EventEmitter {
    readyState = 1;
    closed = false;
    close() { this.closed = true; this.emit('close'); }
  }
  const socket = new FakeSocket();
  store.attachSocket(user.userId, auth.session.deviceId, tokenHash, socket);
  store.revokeSession(tokenHash);
  assert.equal(socket.closed, true);
});

test('key transparency zapisuje append-only lancuch zmian kluczy', async () => {
  const { dataDir, store, user } = fixture();
  const first = store.appendKeyTransparencyEntry(user, 'register');
  assert.ok(first);
  user.keyAgreementPublicKey = 'y'.repeat(32);
  user.keyAgreementPublicKeySignature = 'z'.repeat(32);
  user.updatedAt = new Date(Date.now() + 1000).toISOString();
  store.persistUser(user);
  const second = store.appendKeyTransparencyEntry(user, 'key_update');
  assert.ok(second);
  assert.equal(second.previousRootHash, first.rootHash);
  assert.notEqual(second.rootHash, first.rootHash);

  const session = store.createSession(user, crypto.randomUUID(), 'test');
  const response = await httpRequest(store, 'GET', `/v2/key-transparency?userId=${user.userId}`);
  const denied = await httpRequest(store, 'GET', `/v2/key-transparency?userId=${user.userId}`);
  assert.equal(denied.status, 401);
  const authenticated = await httpRequest(store, 'GET', `/v2/key-transparency?userId=${user.userId}`, {
    token: session.token
  });
  assert.equal(response.status, 401);
  assert.equal(authenticated.status, 200);
  assert.equal(authenticated.body.transparency.entries.length, 2);
  assert.equal(authenticated.body.transparency.entries[1].previousRootHash, first.rootHash);

  const reopened = new V2Store({ dataDir });
  const replayed = reopened.keyTransparencyForUser(user.userId);
  assert.equal(replayed.entries.length, 2);
});

test('limiter pre-auth WebSocket blokuje nadmiar globalnie, per IP i per okno', () => {
  security.resetWsPreAuthLimits();
  const limits = {
    maxGlobal: 2,
    maxPerIp: 1,
    maxPerWindow: 2,
    windowMs: 60 * 1000,
    timeoutMs: 5000
  };
  try {
    const first = security.acquireWsPreAuthSlot(authReq('203.0.113.10'), limits);
    assert.ok(first);
    assert.equal(security.acquireWsPreAuthSlot(authReq('203.0.113.10'), limits), null);
    const second = security.acquireWsPreAuthSlot(authReq('203.0.113.11'), limits);
    assert.ok(second);
    assert.equal(security.acquireWsPreAuthSlot(authReq('203.0.113.12'), limits), null);

    first.release();
    const third = security.acquireWsPreAuthSlot(authReq('203.0.113.12'), limits);
    assert.ok(third);
    third.release();
    const rateLimitedAgain = security.acquireWsPreAuthSlot(authReq('203.0.113.10'), {
      ...limits,
      maxPerIp: 10
    });
    assert.ok(rateLimitedAgain);
    rateLimitedAgain.release();
    assert.equal(security.acquireWsPreAuthSlot(authReq('203.0.113.10'), {
      ...limits,
      maxPerIp: 10
    }), null);
    second.release();

    security.resetWsPreAuthLimits();
    const cappedLimits = {
      maxGlobal: 10,
      maxPerIp: 1,
      maxPerWindow: 10,
      windowMs: 60 * 1000,
      timeoutMs: 5000,
      maxUniqueIps: 2
    };
    const cappedFirst = security.acquireWsPreAuthSlot(authReq('198.51.100.1'), cappedLimits);
    assert.ok(cappedFirst);
    const cappedSecond = security.acquireWsPreAuthSlot(authReq('198.51.100.2'), cappedLimits);
    assert.ok(cappedSecond);
    assert.equal(security.acquireWsPreAuthSlot(authReq('198.51.100.3'), cappedLimits), null);
    cappedFirst.release();
    const cappedThird = security.acquireWsPreAuthSlot(authReq('198.51.100.3'), cappedLimits);
    assert.ok(cappedThird);
    cappedThird.release();
    cappedSecond.release();
  } finally {
    security.resetWsPreAuthLimits();
  }
});

test('wiadomosci sa trwale, indeksowane i stronicowane w SQLite', () => {
  const { dataDir, store } = fixture();
  for (let seq = 1; seq <= 3; seq += 1) {
    store.persistMessages({
      conversationId: 'conversation-1', seq, messageId: `message-${seq}`,
      senderUserId: 'sender', senderDeviceId: 'device', createdAt: new Date().toISOString(), payload: { seq }
    });
  }
  const reopened = new V2Store({ dataDir });
  const page = reopened.messagesForConversation('conversation-1', 1, 1);
  assert.equal(page.length, 1);
  assert.equal(page[0].seq, 2);
  assert.equal(reopened.database.nextMessageSequence('conversation-1'), 4);
  assert.equal(reopened.database.hasEntities('users'), true);
  assert.equal(reopened.database.hasState('users'), false,
    'konta nie sa juz zapisywane jako jeden blob JSON');
});

test('serwer odrzuca downgrade legacy i losowy podpis wiadomosci', () => {
  const { auth, payload } = signedProtocolFixture();
  assert.equal(
    security.validateCloudMessagePayload(payload, messageRequestBody(payload), auth),
    null
  );
  const legacy = structuredClone(payload);
  delete legacy.deviceCertificate;
  delete legacy.deviceSignature;
  delete legacy.aad.messageCounter;
  delete legacy.aad.previousMessageHash;
  assert.match(
    security.validateCloudMessagePayload(legacy, messageRequestBody(legacy), auth),
    /licznik|wymaga/
  );
  const forged = { ...payload, deviceSignature: crypto.randomBytes(64).toString('base64url') };
  assert.match(
    security.validateCloudMessagePayload(forged, messageRequestBody(forged), auth),
    /podpis/
  );
});

test('serwer odrzuca wiadomosc z conversationId AAD innej rozmowy', () => {
  const { auth, payload } = signedProtocolFixture();
  assert.match(
    security.validateCloudMessagePayload(
      payload,
      messageRequestBody(payload, { conversationId: 'conversation-other' }),
      auth
    ),
    /conversationId/
  );
});

test('serwer odrzuca certyfikat obcego lub uniewaznionego urzadzenia', () => {
  const { auth, payload } = signedProtocolFixture();
  const foreignIdentity = crypto.generateKeyPairSync('ed25519');
  const foreignCertificate = {
    ...payload.deviceCertificate,
    signature: crypto.sign(
      null,
      Buffer.from(security.canonicalJson({
        v: 1,
        protocol: 'secure-chat/device-certificate/v1',
        accountId: payload.deviceCertificate.accountId,
        serverOrigin: payload.deviceCertificate.serverOrigin,
        deviceId: payload.deviceCertificate.deviceId,
        deviceSigningPublicKey: payload.deviceCertificate.deviceSigningPublicKey,
        deviceEpoch: payload.deviceCertificate.deviceEpoch,
        createdAt: payload.deviceCertificate.createdAt
      })),
      foreignIdentity.privateKey
    ).toString('base64url')
  };
  assert.match(security.validateCloudMessagePayload(
    { ...payload, deviceCertificate: foreignCertificate },
    messageRequestBody(payload),
    auth
  ), /certyfikat|podpis/);
  auth.user.deviceList.revokedDevices.push({
    deviceId: auth.session.deviceId,
    revokedDeviceEpoch: 1,
    revokedAt: new Date().toISOString(),
    reasonCode: 'test'
  });
  auth.user.deviceList.devices = [];
  assert.match(security.validateCloudMessagePayload(
    payload,
    messageRequestBody(payload),
    auth
  ), /certyfikat|podpis/);
});

test('serwer odrzuca wygasly certyfikat i podpis innego urzadzenia', () => {
  const { auth, device, identity, payload } = signedProtocolFixture();
  const expiredAt = new Date(Date.now() - 366 * 24 * 60 * 60 * 1000).toISOString();
  const unsignedCertificate = {
    ...payload.deviceCertificate,
    createdAt: expiredAt
  };
  delete unsignedCertificate.signature;
  const expiredCertificate = {
    ...unsignedCertificate,
    signature: crypto.sign(
      null,
      Buffer.from(security.canonicalJson(unsignedCertificate)),
      identity.privateKey
    ).toString('base64url')
  };
  auth.user.deviceList.devices[0].certificateHash = sha256Canonical(expiredCertificate);
  const expiredPayload = resignMessage({
    ...payload,
    deviceCertificate: expiredCertificate
  }, device.privateKey);
  assert.match(security.validateCloudMessagePayload(
    expiredPayload,
    messageRequestBody(expiredPayload),
    auth
  ), /certyfikat|podpis/);

  auth.user.deviceList.devices[0].certificateHash = sha256Canonical(payload.deviceCertificate);
  const otherDevice = crypto.generateKeyPairSync('ed25519');
  const wrongDevicePayload = resignMessage(payload, otherDevice.privateKey);
  assert.match(security.validateCloudMessagePayload(
    wrongDevicePayload,
    messageRequestBody(wrongDevicePayload),
    auth
  ), /podpis/);
});

test('memberKeys wymagaja kluczy konta i poprawnego podpisu', () => {
  const { auth, identity } = signedProtocolFixture();
  const envelope = signedMemberKeyEnvelope({ auth, identity });
  assert.equal(security.validateMemberKeys(
    { [auth.user.userId]: envelope },
    [auth.user.userId],
    auth
  ), null);
  assert.match(security.validateMemberKeys(
    { [auth.user.userId]: { ...envelope, senderPublicKey: 'attacker-key' } },
    [auth.user.userId],
    auth
  ), /podpis|kluczy/);
  assert.match(security.validateMemberKeys(
    { [auth.user.userId]: { ...envelope, senderIdentityPublicKey: 'attacker-key' } },
    [auth.user.userId],
    auth
  ), /podpis|kluczy/);
  assert.match(security.validateMemberKeys(
    { [auth.user.userId]: { ...envelope, signature: crypto.randomBytes(64).toString('base64url') } },
    [auth.user.userId],
    auth
  ), /podpis|kluczy/);
  const legacyEnvelope = signedMemberKeyEnvelope({ auth, identity, legacy: true });
  assert.match(security.validateMemberKeys(
    { [auth.user.userId]: legacyEnvelope },
    [auth.user.userId],
    auth
  ), /AAD v2/);
});

test('rotacja klucza rozmowy podbija epoke i odrzuca stare wiadomosci', async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-rotate-'));
  const store = new V2Store({ dataDir, limits: { minFreeDiskBytes: 0 } });
  const { auth, identity, payload, user } = signedProtocolFixture();
  user.username = `rotate-${crypto.randomBytes(6).toString('hex')}`;
  user.displayName = 'Rotate test';
  user.devices = {};
  user.updatedAt = new Date().toISOString();
  store.users.users[user.userId] = user;
  store.persistUsers();
  const session = store.createSession(user, auth.session.deviceId, 'test');
  store.conversations.conversations['conversation-1'] = {
    conversationId: 'conversation-1',
    type: 'direct',
    memberIds: [user.userId],
    keyEpoch: 1,
    memberKeys: {
      [user.userId]: signedMemberKeyEnvelope({ auth, identity, keyEpoch: 1 })
    },
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  store.persistConversations();

  const rotatedEnvelope = signedMemberKeyEnvelope({
    auth,
    identity,
    keyEpoch: 2
  });
  const rotated = await httpRequest(
    store,
    'PUT',
    '/v2/conversations/conversation-1/keys',
    {
      token: session.token,
      body: {
        expectedKeyEpoch: 1,
        memberKeys: { [user.userId]: rotatedEnvelope }
      }
    }
  );
  assert.equal(rotated.status, 200);
  assert.equal(rotated.body.conversation.keyEpoch, 2);
  assert.deepEqual(
    rotated.body.conversation.memberKeys[user.userId],
    rotatedEnvelope
  );

  const staleRotation = await httpRequest(
    store,
    'PUT',
    '/v2/conversations/conversation-1/keys',
    {
      token: session.token,
      body: {
        expectedKeyEpoch: 1,
        memberKeys: { [user.userId]: rotatedEnvelope }
      }
    }
  );
  assert.equal(staleRotation.status, 409);

  const staleMessage = await httpRequest(store, 'POST', '/v2/messages', {
    token: session.token,
    body: {
      conversationId: 'conversation-1',
      messageId: payload.messageId,
      payload
    }
  });
  assert.equal(staleMessage.status, 409);
  assert.match(staleMessage.body.error, /epoki/);
});

test('licznik i previousMessageHash nie pozwalaja na replay ani fork', () => {
  const { store } = fixture();
  assert.equal(security.messageStreamError(
    store.database,
    'conversation-chain',
    'sender-chain',
    'device-chain',
    1,
    security.genesisHash
  ), null);
  store.persistMessages({
    conversationId: 'conversation-chain',
    seq: 1,
    messageId: 'chain-message-1',
    senderUserId: 'sender-chain',
    senderDeviceId: 'device-chain',
    messageCounter: 1,
    payloadHash: 'payload-hash-1',
    payloadBytes: 10,
    createdAt: new Date().toISOString(),
    payload: {}
  });
  assert.match(security.messageStreamError(
    store.database,
    'conversation-chain',
    'sender-chain',
    'device-chain',
    1,
    'payload-hash-1'
  ), /Licznik/);
  assert.match(security.messageStreamError(
    store.database,
    'conversation-chain',
    'sender-chain',
    'device-chain',
    2,
    'forked-hash'
  ), /previousMessageHash/);
  assert.equal(security.messageStreamError(
    store.database,
    'conversation-chain',
    'sender-chain',
    'device-chain',
    2,
    'payload-hash-1'
  ), null);
});

test('SQLite wymusza unikalny licznik strumienia urzadzenia', () => {
  const { store } = fixture();
  const base = {
    conversationId: 'conversation-unique',
    senderUserId: 'sender-unique',
    senderDeviceId: 'device-unique',
    messageCounter: 1,
    payloadHash: 'payload-hash-unique',
    payloadBytes: 10,
    createdAt: new Date().toISOString(),
    payload: {}
  };
  store.persistMessages({ ...base, seq: 1, messageId: 'unique-message-1' });
  assert.throws(
    () => store.persistMessages({
      ...base,
      seq: 2,
      messageId: 'unique-message-2',
      payloadHash: 'payload-hash-fork'
    }),
    /constraint|UNIQUE/i
  );
});

test('publiczny profil moze ukryc liste urzadzen przed katalogiem', () => {
  const { store, user } = fixture();
  user.devices = {
    device: {
      deviceName: 'Laptop',
      deviceCertificate: {
        v: 1,
        accountId: user.userId,
        serverOrigin: 'https://chat.example',
        deviceId: 'device',
        deviceSigningPublicKey: 'x'.repeat(32),
        deviceEpoch: 1,
        createdAt: new Date().toISOString(),
        signature: 's'.repeat(32)
      }
    }
  };
  user.deviceList = {
    v: 1,
    accountId: user.userId,
    serverOrigin: 'https://chat.example',
    deviceListEpoch: 1,
    previousDeviceListHash: '',
    identityRotationEpoch: 0,
    devices: [],
    revokedDevices: [],
    signature: 's'.repeat(32),
    updatedAt: new Date().toISOString()
  };
  const minimal = store.publicUser(user, { includeDevices: false });
  assert.deepEqual(minimal.devices, {});
  assert.equal(minimal.deviceList, null);
  assert.equal(minimal.deviceListHash, '');
});

test('publiczny profil zapisuje avatar na serwerze i zwraca go w sesji', async () => {
  const { store, user } = fixture();
  const session = store.createSession(user, 'profile-device', 'Device');
  const profile = {
    v: 1,
    avatarMimeType: 'image/png',
    avatarBytes: Buffer.from([1, 2, 3, 4]).toString('base64url'),
    updatedAt: new Date().toISOString()
  };

  const saved = await httpRequest(store, 'PUT', '/v2/profile', {
    token: session.token,
    body: { profile }
  });

  assert.equal(saved.status, 200);
  assert.equal(saved.body.user.profile.avatarMimeType, 'image/png');
  assert.equal(saved.body.user.profile.avatarBytes, profile.avatarBytes);
  assert.equal(store.users.users[user.userId].profile.avatarBytes, profile.avatarBytes);

  const loaded = await httpRequest(store, 'GET', '/v2/session', {
    token: session.token
  });
  assert.equal(loaded.status, 200);
  assert.equal(loaded.body.user.profile.avatarBytes, profile.avatarBytes);
});

test('katalog bez zapytania zwraca znanych rozmowcow z profilem', async () => {
  const { store, user } = fixture();
  const peer = {
    userId: crypto.randomUUID(),
    username: 'bob',
    displayName: 'Bob',
    identityPublicKey: 'i'.repeat(32),
    keyAgreementPublicKey: 'k'.repeat(32),
    keyAgreementPublicKeySignature: 's'.repeat(32),
    devices: {},
    profile: {
      v: 1,
      avatarMimeType: 'image/png',
      avatarBytes: Buffer.from([9, 8, 7]).toString('base64url'),
      updatedAt: new Date().toISOString()
    },
    updatedAt: new Date().toISOString()
  };
  store.users.users[peer.userId] = peer;
  store.persistUsers();
  store.conversations.conversations['known-peer'] = {
    conversationId: 'known-peer',
    type: 'direct',
    memberIds: [user.userId, peer.userId].sort(),
    keyEpoch: 1,
    memberKeys: {},
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  store.persistConversations();
  const session = store.createSession(user, 'directory-device', 'Device');

  const result = await httpRequest(store, 'GET', '/v2/users', {
    token: session.token
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.users.length, 1);
  assert.equal(result.body.users[0].username, 'bob');
  assert.equal(result.body.users[0].profile.avatarBytes, peer.profile.avatarBytes);
});

test('migracja vault key zmienia haslo i vault atomowo', async () => {
  const { store, user } = fixture();
  user.password = await security.hashPassword('legacy-password');
  user.encryptedVault = { nonce: 'old', ciphertext: 'old', mac: 'old' };
  user.vaultKdf = {
    algorithm: 'argon2id',
    version: 19,
    memoryKiB: 8192,
    iterations: 2,
    lanes: 1,
    keyBytes: 32
  };
  user.vaultEpoch = 1;
  user.vaultHash = crypto.createHash('sha256')
    .update(JSON.stringify(user.encryptedVault))
    .digest('base64url');
  store.persistUser(user);
  const session = store.createSession(user, 'migration-device', 'Device');
  const encryptedVault = { nonce: 'new', ciphertext: 'new', mac: 'new' };

  const migrated = await httpRequest(store, 'PUT', '/v2/vault/migrate-key', {
    token: session.token,
    body: {
      newPassword: 'sc-auth-v1.new-separated-password',
      encryptedVault,
      expectedVaultEpoch: 1,
      expectedVaultHash: user.vaultHash,
      vaultKdf: user.vaultKdf
    }
  });

  assert.equal(migrated.status, 200);
  assert.equal(store.users.users[user.userId].vaultEpoch, 2);
  assert.deepEqual(store.users.users[user.userId].encryptedVault, encryptedVault);
  assert.equal(
    await security.verifyPassword('sc-auth-v1.new-separated-password', store.users.users[user.userId].password),
    true
  );
  assert.equal(
    await security.verifyPassword('legacy-password', store.users.users[user.userId].password),
    false
  );
});

test('serwer odrzuca duplikaty w podpisanej liscie urzadzen', () => {
  const baseDevice = {
    deviceId: 'device-duplicate',
    deviceSigningPublicKey: 'x'.repeat(32),
    certificateHash: 'h'.repeat(32),
    addedAt: new Date().toISOString(),
    deviceEpoch: 1
  };
  const baseRevoked = {
    deviceId: 'device-revoked',
    deviceSigningPublicKey: 'x'.repeat(32),
    deviceCertificateHash: 'h'.repeat(32),
    revokedDeviceEpoch: 1,
    revokedAt: new Date().toISOString(),
    reasonCode: 'test'
  };
  const list = {
    v: 1,
    accountId: crypto.randomUUID(),
    serverOrigin: 'https://chat.example',
    deviceListEpoch: 1,
    previousDeviceListHash: '',
    identityRotationEpoch: 0,
    devices: [baseDevice],
    revokedDevices: [baseRevoked],
    signature: 's'.repeat(32),
    updatedAt: new Date().toISOString()
  };
  assert.equal(security.isValidDeviceList(list), true);
  assert.equal(security.isValidDeviceList({
    ...list,
    devices: [baseDevice, { ...baseDevice }]
  }), false);
  assert.equal(security.isValidDeviceList({
    ...list,
    revokedDevices: [baseRevoked, { ...baseRevoked }]
  }), false);
  assert.equal(security.isValidDeviceList({
    ...list,
    devices: [baseDevice],
    revokedDevices: [{ ...baseRevoked, deviceId: baseDevice.deviceId }]
  }), false);
});

test('serwer anonimizuje nazwy urzadzen przed zapisem i publikacja', () => {
  const { store, user } = fixture();
  const legacyDeviceId = 'legacy-device';
  user.devices = {
    [legacyDeviceId]: {
      deviceName: 'KAMIL-DESKTOP'
    }
  };
  store.persistUser(user);

  store.anonymizeStoredDeviceNames();

  assert.equal(user.devices[legacyDeviceId].deviceName, 'Device');
  assert.equal(store.publicUser(user).devices[legacyDeviceId].deviceName, 'Device');

  const session = store.createSession(user, 'new-device', 'PRIVATE-HOSTNAME');
  const hash = crypto.createHash('sha256').update(session.token).digest('base64url');
  assert.equal(user.devices['new-device'].deviceName, 'Device');
  assert.equal(store.publicSession(hash, store.sessions.sessions[hash]).deviceName, 'Device');

  const pending = store.createPendingLogin(user, 'pending-device', 'Windows device', 'https://chat.example');
  assert.equal(pending.deviceName, 'Windows device');
});

test('endpoint HTTP przyjmuje tylko podpisany ciag wiadomosci z aktualna epoka', async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-http-'));
  const store = new V2Store({ dataDir, limits: { minFreeDiskBytes: 0 } });
  const { auth, payload, user } = signedProtocolFixture();
  user.username = `user-${crypto.randomBytes(6).toString('hex')}`;
  user.displayName = 'HTTP test';
  user.devices = {};
  user.updatedAt = new Date().toISOString();
  store.users.users[user.userId] = user;
  store.persistUsers();
  const session = store.createSession(user, auth.session.deviceId, 'test');
  store.conversations.conversations['conversation-1'] = {
    conversationId: 'conversation-1',
    type: 'direct',
    memberIds: [user.userId],
    keyEpoch: 1,
    memberKeys: {},
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  store.persistConversations();

  const accepted = await httpRequest(store, 'POST', '/v2/messages', {
    token: session.token,
    body: {
      conversationId: 'conversation-1',
      messageId: payload.messageId,
      payload
    }
  });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.message.messageCounter, 1);

  const replay = await httpRequest(store, 'POST', '/v2/messages', {
    token: session.token,
    body: {
      conversationId: 'conversation-1',
      messageId: payload.messageId,
      payload
    }
  });
  assert.equal(replay.status, 409);

  store.conversations.conversations['conversation-1'].keyEpoch = 2;
  store.persistConversations();
  const staleEpoch = await httpRequest(store, 'POST', '/v2/messages', {
    token: session.token,
    body: {
      conversationId: 'conversation-1',
      messageId: payload.messageId,
      payload
    }
  });
  assert.equal(staleEpoch.status, 409);
  assert.match(staleEpoch.body.error, /epoki/);
});

test('kolejka KDF ma twardy limit i odrzuca nadmiar', async () => {
  const requests = Array.from({ length: 40 }, (_, index) =>
    security.scryptAsync(`password-${index}`, `salt-${index}`));
  const results = await Promise.allSettled(requests);
  assert.ok(results.some((result) =>
    result.status === 'rejected' && result.reason?.code === 'SERVER_BUSY'));
});

test('zaproszenie jest hashowane, ograniczone i jednorazowe', () => {
  const { store } = fixture();
  const invite = store.createInvite({ restrictedUsername: 'alice', maxUses: 1 });
  const stored = store.invites.invites[invite.inviteId];
  assert.notEqual(stored.tokenHash, invite.token);
  assert.equal(store.consumeInvite(invite.token, 'bob'), false);
  assert.equal(store.consumeInvite(invite.token, 'alice'), true);
  assert.equal(store.consumeInvite(invite.token, 'alice'), false);
});

test('quota bajtowa blokuje konto przed wyczerpaniem dysku', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-quota-'));
  const store = new V2Store({
    dataDir,
    limits: {
      messageBytes: 100,
      messagesPerConversation: 100,
      conversationBytes: 100,
      accountBytes: 10,
      instanceBytes: 100,
      dailyAccountBytes: 100,
      minFreeDiskBytes: 0
    }
  });
  store.persistMessages({
    conversationId: 'conversation-1',
    seq: 1,
    messageId: 'quota-message-1',
    senderUserId: 'quota-user',
    senderDeviceId: 'quota-device',
    payloadBytes: 8,
    createdAt: new Date().toISOString(),
    payload: {}
  });
  assert.match(
    security.storageQuotaError(store, 'quota-user', 'conversation-2', 3)?.error || '',
    /Konto/
  );
});

test('backup SQLite online odtwarza dane z WAL i wykrywa uszkodzona kopie', () => {
  const { dataDir, store } = fixture();
  const conversationId = 'conversation-backup';
  store.conversations.conversations[conversationId] = {
    conversationId,
    type: 'direct',
    memberIds: ['backup-user'],
    keyEpoch: 1,
    memberKeys: {},
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  store.persistConversation(store.conversations.conversations[conversationId]);
  for (let seq = 1; seq <= 25; seq += 1) {
    store.persistMessages({
      conversationId,
      seq,
      messageId: `backup-message-${seq}`,
      senderUserId: 'backup-user',
      senderDeviceId: 'backup-device',
      messageCounter: seq,
      payloadHash: `backup-hash-${seq}`,
      payloadBytes: 12,
      createdAt: new Date(Date.now() + seq).toISOString(),
      payload: { seq }
    });
  }

  assert.deepEqual(store.database.integrityCheck(), ['ok']);
  const backupFile = path.join(dataDir, 'backup.sqlite');
  store.database.backupTo(backupFile);

  const restoreDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-restore-'));
  fs.copyFileSync(backupFile, path.join(restoreDir, 'secure-chat.sqlite'));
  const restored = new V2Store({ dataDir: restoreDir });
  assert.deepEqual(restored.database.integrityCheck(), ['ok']);
  const restoredMessages = restored.messagesForConversation(conversationId, 0, 30);
  assert.equal(restoredMessages.length, 25);
  assert.equal(restoredMessages.at(-1).messageId, 'backup-message-25');

  const corruptDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-corrupt-'));
  fs.writeFileSync(path.join(corruptDir, 'secure-chat.sqlite'), crypto.randomBytes(256));
  assert.throws(() => new V2Store({ dataDir: corruptDir }), /malformed|file is not a database|database/i);
});

test('dynamiczny zapis wielu wiadomosci zachowuje sekwencje i limity strumienia', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-chat-load-'));
  const store = new V2Store({
    dataDir,
    limits: {
      messageBytes: 1024,
      messagesPerConversation: 300,
      conversationBytes: 1024 * 1024,
      accountBytes: 1024 * 1024,
      instanceBytes: 1024 * 1024,
      dailyAccountBytes: 1024 * 1024,
      minFreeDiskBytes: 0
    }
  });
  const conversationId = 'conversation-load';
  store.conversations.conversations[conversationId] = {
    conversationId,
    type: 'direct',
    memberIds: ['load-user'],
    keyEpoch: 1,
    memberKeys: {},
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  store.persistConversation(store.conversations.conversations[conversationId]);

  let previousHash = security.genesisHash;
  for (let counter = 1; counter <= 300; counter += 1) {
    const payloadHash = `load-hash-${counter}`;
    const message = store.persistMessageAndConversation(
      {
        conversationId,
        messageId: `load-message-${counter}`,
        senderUserId: 'load-user',
        senderDeviceId: 'load-device',
        messageCounter: counter,
        payloadHash,
        payloadBytes: 32,
        createdAt: new Date(Date.now() + counter).toISOString(),
        payload: { counter }
      },
      {
        ...store.conversations.conversations[conversationId],
        updatedAt: new Date().toISOString()
      },
      {
        previousMessageHash: previousHash,
        genesisHash: security.genesisHash
      }
    );
    assert.equal(message.seq, counter);
    previousHash = payloadHash;
  }

  assert.equal(store.database.messageCount(conversationId), 300);
  assert.equal(store.database.nextMessageSequence(conversationId), 301);
  assert.match(
    security.storageQuotaError(store, 'load-user', conversationId, 32)?.error || '',
    /Rozmowa/
  );
});
