import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { V2Store } from '../src/v2Store.js';

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
});
