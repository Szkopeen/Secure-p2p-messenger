import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export class SqliteStateStore {
  constructor(dataDir) {
    fs.mkdirSync(dataDir, { recursive: true });
    this.db = new DatabaseSync(path.join(dataDir, 'secure-chat.sqlite'));
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA synchronous = FULL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS app_state (
        state_key TEXT PRIMARY KEY,
        json_value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS users (
        user_id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE,
        identity_public_key TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        json_value TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS sessions (
        session_hash TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        expires_at_ms INTEGER NOT NULL,
        json_value TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS sessions_user_device ON sessions(user_id, device_id);
      CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at_ms);
      CREATE TABLE IF NOT EXISTS conversations (
        conversation_id TEXT PRIMARY KEY,
        conversation_type TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        json_value TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated_at);
      CREATE TABLE IF NOT EXISTS invitations (
        invite_id TEXT PRIMARY KEY,
        token_hash TEXT NOT NULL UNIQUE,
        expires_at TEXT NOT NULL,
        used_at TEXT,
        json_value TEXT NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS invitations_expiry ON invitations(expires_at);
      CREATE TABLE IF NOT EXISTS messages (
        conversation_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        message_id TEXT NOT NULL UNIQUE,
        sender_user_id TEXT,
        sender_device_id TEXT,
        message_counter INTEGER,
        payload_hash TEXT,
        payload_bytes INTEGER,
        json_value TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(conversation_id, sequence)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS messages_conversation_sequence
        ON messages(conversation_id, sequence);
      CREATE INDEX IF NOT EXISTS messages_created_at ON messages(created_at);
    `);
    this.ensureColumn('messages', 'sender_user_id', 'TEXT');
    this.ensureColumn('messages', 'sender_device_id', 'TEXT');
    this.ensureColumn('messages', 'message_counter', 'INTEGER');
    this.ensureColumn('messages', 'payload_hash', 'TEXT');
    this.ensureColumn('messages', 'payload_bytes', 'INTEGER');
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS messages_sender_stream
        ON messages(conversation_id, sender_user_id, sender_device_id, message_counter);
      CREATE INDEX IF NOT EXISTS messages_sender_created
        ON messages(sender_user_id, created_at);
    `);
    this.readStateStatement = this.db.prepare('SELECT json_value FROM app_state WHERE state_key = ?');
    this.writeStateStatement = this.db.prepare(`
      INSERT INTO app_state(state_key, json_value, updated_at) VALUES(?, ?, ?)
      ON CONFLICT(state_key) DO UPDATE SET json_value=excluded.json_value, updated_at=excluded.updated_at
    `);
    this.readMessagesStatement = this.db.prepare(`
      SELECT json_value FROM messages
      WHERE conversation_id = ? AND sequence > ?
      ORDER BY sequence ASC LIMIT ?
    `);
    this.insertMessageStatement = this.db.prepare(`
      INSERT INTO messages(
        conversation_id, sequence, message_id, sender_user_id,
        sender_device_id, message_counter, payload_hash, payload_bytes,
        json_value, created_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    this.nextSequenceStatement = this.db.prepare(
      'SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence FROM messages WHERE conversation_id = ?'
    );
    this.messageCountStatement = this.db.prepare(
      'SELECT COUNT(*) AS count FROM messages WHERE conversation_id = ?'
    );
    this.conversationBytesStatement = this.db.prepare(
      'SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM messages WHERE conversation_id = ?'
    );
    this.accountBytesStatement = this.db.prepare(
      'SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM messages WHERE sender_user_id = ?'
    );
    this.instanceBytesStatement = this.db.prepare(
      'SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM messages'
    );
    this.dailyAccountBytesStatement = this.db.prepare(`
      SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM messages
      WHERE sender_user_id = ? AND created_at >= ?
    `);
    this.streamHeadStatement = this.db.prepare(`
      SELECT message_counter, payload_hash FROM messages
      WHERE conversation_id = ? AND sender_user_id = ? AND sender_device_id = ?
        AND message_counter IS NOT NULL
      ORDER BY message_counter DESC LIMIT 1
    `);
    this.entityCountStatements = {
      users: this.db.prepare('SELECT COUNT(*) AS count FROM users'),
      sessions: this.db.prepare('SELECT COUNT(*) AS count FROM sessions'),
      conversations: this.db.prepare('SELECT COUNT(*) AS count FROM conversations'),
      invitations: this.db.prepare('SELECT COUNT(*) AS count FROM invitations')
    };
    this.entityReadStatements = {
      users: this.db.prepare('SELECT user_id AS entity_id, json_value FROM users'),
      sessions: this.db.prepare('SELECT session_hash AS entity_id, json_value FROM sessions'),
      conversations: this.db.prepare('SELECT conversation_id AS entity_id, json_value FROM conversations'),
      invitations: this.db.prepare('SELECT invite_id AS entity_id, json_value FROM invitations')
    };
    this.entityDeleteStatements = {
      users: this.db.prepare('DELETE FROM users'),
      sessions: this.db.prepare('DELETE FROM sessions'),
      conversations: this.db.prepare('DELETE FROM conversations'),
      invitations: this.db.prepare('DELETE FROM invitations')
    };
    this.userInsertStatement = this.db.prepare(`
      INSERT INTO users(user_id, username, identity_public_key, updated_at, json_value)
      VALUES(?, ?, ?, ?, ?)
    `);
    this.sessionInsertStatement = this.db.prepare(`
      INSERT INTO sessions(session_hash, user_id, device_id, expires_at_ms, json_value)
      VALUES(?, ?, ?, ?, ?)
    `);
    this.conversationInsertStatement = this.db.prepare(`
      INSERT INTO conversations(conversation_id, conversation_type, updated_at, json_value)
      VALUES(?, ?, ?, ?)
    `);
    this.conversationUpsertStatement = this.db.prepare(`
      INSERT INTO conversations(conversation_id, conversation_type, updated_at, json_value)
      VALUES(?, ?, ?, ?)
      ON CONFLICT(conversation_id) DO UPDATE SET
        conversation_type=excluded.conversation_type,
        updated_at=excluded.updated_at,
        json_value=excluded.json_value
    `);
    this.invitationInsertStatement = this.db.prepare(`
      INSERT INTO invitations(invite_id, token_hash, expires_at, used_at, json_value)
      VALUES(?, ?, ?, ?, ?)
    `);
  }

  ensureColumn(table, column, type) {
    const columns = this.db.prepare(`PRAGMA table_info(${table})`).all();
    if (!columns.some((item) => item.name === column)) {
      this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
    }
  }

  hasState(key) {
    return Boolean(this.readStateStatement.get(key));
  }

  readState(key, fallback) {
    const row = this.readStateStatement.get(key);
    return row ? JSON.parse(row.json_value) : fallback;
  }

  writeState(key, value) {
    this.writeStateStatement.run(key, JSON.stringify(value), new Date().toISOString());
  }

  hasEntities(kind) {
    const statement = this.entityCountStatements[kind];
    if (!statement) throw new Error(`Nieznany typ encji: ${kind}`);
    return statement.get().count > 0;
  }

  readEntities(kind, resultKey) {
    const statement = this.entityReadStatements[kind];
    if (!statement) throw new Error(`Nieznany typ encji: ${kind}`);
    const values = {};
    for (const row of statement.all()) values[row.entity_id] = JSON.parse(row.json_value);
    return { v: 1, [resultKey]: values };
  }

  replaceEntities(kind, values, { transaction = true } = {}) {
    const replace = () => {
      const deleteStatement = this.entityDeleteStatements[kind];
      if (!deleteStatement) throw new Error(`Nieznany typ encji: ${kind}`);
      deleteStatement.run();
      for (const [entityId, value] of Object.entries(values || {})) {
        const json = JSON.stringify(value);
        if (kind === 'users') {
          this.userInsertStatement.run(
            entityId, value.username, value.identityPublicKey,
            value.updatedAt || new Date().toISOString(), json
          );
        } else if (kind === 'sessions') {
          this.sessionInsertStatement.run(
            entityId, value.userId, value.deviceId, value.expiresAtMs, json
          );
        } else if (kind === 'conversations') {
          this.conversationInsertStatement.run(
            entityId, value.type || 'direct', value.updatedAt || new Date().toISOString(), json
          );
        } else if (kind === 'invitations') {
          this.invitationInsertStatement.run(
            entityId, value.tokenHash, value.expiresAt, value.usedAt || null, json
          );
        }
      }
    };
    if (!transaction) {
      replace();
      return;
    }
    this.db.exec('BEGIN IMMEDIATE');
    try {
      replace();
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  readMessages(conversationId, afterSequence, limit) {
    return this.readMessagesStatement.all(conversationId, afterSequence, limit)
      .map((row) => JSON.parse(row.json_value));
  }

  appendMessage(message) {
    const payloadBytes = Number.isInteger(message.payloadBytes)
      ? message.payloadBytes
      : Buffer.byteLength(JSON.stringify(message.payload || {}), 'utf8');
    this.insertMessageStatement.run(
      message.conversationId,
      message.seq,
      message.messageId,
      message.senderUserId || null,
      message.senderDeviceId || null,
      Number.isInteger(message.messageCounter) ? message.messageCounter : null,
      message.payloadHash || null,
      payloadBytes,
      JSON.stringify(message),
      message.createdAt
    );
  }

  appendMessageAndUpdateConversation(message, conversation) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.appendMessage(message);
      this.conversationUpsertStatement.run(
        conversation.conversationId,
        conversation.type || 'direct',
        conversation.updatedAt || new Date().toISOString(),
        JSON.stringify(conversation)
      );
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  nextMessageSequence(conversationId) {
    return this.nextSequenceStatement.get(conversationId).next_sequence;
  }

  messageCount(conversationId) {
    return this.messageCountStatement.get(conversationId).count;
  }

  conversationBytes(conversationId) {
    return this.conversationBytesStatement.get(conversationId).bytes;
  }

  accountBytes(userId) {
    return this.accountBytesStatement.get(userId).bytes;
  }

  instanceBytes() {
    return this.instanceBytesStatement.get().bytes;
  }

  dailyAccountBytes(userId, sinceIso) {
    return this.dailyAccountBytesStatement.get(userId, sinceIso).bytes;
  }

  streamHead(conversationId, senderUserId, senderDeviceId) {
    return this.streamHeadStatement.get(conversationId, senderUserId, senderDeviceId) || null;
  }

  importLegacyMessages(messagesByConversation) {
    const count = this.db.prepare('SELECT COUNT(*) AS count FROM messages').get().count;
    if (count > 0) return;
    this.db.exec('BEGIN IMMEDIATE');
    try {
      for (const messages of Object.values(messagesByConversation || {})) {
        for (const message of messages) this.appendMessage(message);
      }
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
}
