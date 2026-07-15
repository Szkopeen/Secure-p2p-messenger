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
      CREATE TABLE IF NOT EXISTS messages (
        conversation_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence > 0),
        message_id TEXT NOT NULL UNIQUE,
        json_value TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(conversation_id, sequence)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS messages_conversation_sequence
        ON messages(conversation_id, sequence);
      CREATE INDEX IF NOT EXISTS messages_created_at ON messages(created_at);
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
      INSERT INTO messages(conversation_id, sequence, message_id, json_value, created_at)
      VALUES(?, ?, ?, ?, ?)
    `);
    this.nextSequenceStatement = this.db.prepare(
      'SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence FROM messages WHERE conversation_id = ?'
    );
    this.messageCountStatement = this.db.prepare(
      'SELECT COUNT(*) AS count FROM messages WHERE conversation_id = ?'
    );
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

  readMessages(conversationId, afterSequence, limit) {
    return this.readMessagesStatement.all(conversationId, afterSequence, limit)
      .map((row) => JSON.parse(row.json_value));
  }

  appendMessage(message) {
    this.insertMessageStatement.run(
      message.conversationId,
      message.seq,
      message.messageId,
      JSON.stringify(message),
      message.createdAt
    );
  }

  appendMessageAndUpdateConversations(message, conversations) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.appendMessage(message);
      this.writeState('conversations', conversations);
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
