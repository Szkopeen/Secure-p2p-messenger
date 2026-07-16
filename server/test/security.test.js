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

async function httpRequest(store, method, pathname, { body, token } = {}) {
  const req = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  req.method = method;
  req.headers = token ? { authorization: `Bearer ${token}` } : {};
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
    keyAgreementPublicKey: 'agreement-key',
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
  recipientUserId = auth.user.userId
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

test('pelna sesja powstaje dopiero po podpisaniu challenge kluczem z vaultu', () => {
  const { store, user, privateKey } = fixture();
  const pending = store.createPendingLogin(user, crypto.randomUUID(), 'test');
  assert.equal(Object.keys(store.sessions.sessions).length, 0);
  const payload = Buffer.from(JSON.stringify({
    protocol: 'secure-chat/login-challenge/v1', challenge: pending.challenge,
    userId: pending.userId, deviceId: pending.deviceId, expiresAtMs: pending.expiresAtMs
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
    security.validateCloudMessagePayload(payload, { messageId: payload.messageId }, auth),
    null
  );
  const legacy = structuredClone(payload);
  delete legacy.deviceCertificate;
  delete legacy.deviceSignature;
  delete legacy.aad.messageCounter;
  delete legacy.aad.previousMessageHash;
  assert.match(
    security.validateCloudMessagePayload(legacy, { messageId: legacy.messageId }, auth),
    /licznik|wymaga/
  );
  const forged = { ...payload, deviceSignature: crypto.randomBytes(64).toString('base64url') };
  assert.match(
    security.validateCloudMessagePayload(forged, { messageId: forged.messageId }, auth),
    /podpis/
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
    { messageId: payload.messageId },
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
    { messageId: payload.messageId },
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
    { messageId: expiredPayload.messageId },
    auth
  ), /certyfikat|podpis/);

  auth.user.deviceList.devices[0].certificateHash = sha256Canonical(payload.deviceCertificate);
  const otherDevice = crypto.generateKeyPairSync('ed25519');
  const wrongDevicePayload = resignMessage(payload, otherDevice.privateKey);
  assert.match(security.validateCloudMessagePayload(
    wrongDevicePayload,
    { messageId: wrongDevicePayload.messageId },
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
