#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { config } from '../src/config.js';
import { SqliteStateStore } from '../src/sqliteStore.js';

function usage() {
  console.error('Uzycie: npm run backup-sqlite -- --out /sciezka/secure-chat.sqlite');
  process.exit(2);
}

function integrityCheck(file) {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return db.prepare('PRAGMA integrity_check').all()
      .map((row) => row.integrity_check);
  } finally {
    db.close();
  }
}

let out = '';
for (let index = 2; index < process.argv.length; index += 1) {
  if (process.argv[index] === '--out') {
    out = process.argv[index + 1] || '';
    index += 1;
  }
}

if (!out) usage();

const target = path.resolve(out);
const source = path.resolve(config.v2DataDir, 'secure-chat.sqlite');
if (!fs.existsSync(source)) {
  console.error(`Nie znaleziono bazy SQLite: ${source}`);
  process.exit(1);
}
if (target === source) {
  console.error('Plik backupu nie moze byc aktywna baza SQLite.');
  process.exit(1);
}

const store = new SqliteStateStore(config.v2DataDir);
const integrity = store.integrityCheck();
if (integrity.length !== 1 || integrity[0] !== 'ok') {
  throw new Error(`SQLite integrity_check nie zwrocil ok: ${integrity.join(', ')}`);
}
store.backupTo(target);
const backupIntegrity = integrityCheck(target);
if (backupIntegrity.length !== 1 || backupIntegrity[0] !== 'ok') {
  throw new Error(`Backup SQLite integrity_check nie zwrocil ok: ${backupIntegrity.join(', ')}`);
}
console.log(`Backup SQLite zapisany: ${target}`);
