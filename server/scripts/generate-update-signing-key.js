#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

function usage() {
  return `
Uzycie:
  node scripts/generate-update-signing-key.js --out ./secrets/update-signing-key.pem

Wynik:
  - prywatny klucz Ed25519 PEM zapisany w --out
  - publiczny klucz raw base64url wypisany do wklejenia w Flutter build:
    --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=...
`.trim();
}

function readArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index++) {
    const key = argv[index];
    if (!key.startsWith('--')) throw new Error(`Nieznany argument: ${key}`);
    const name = key.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new Error(`Brak wartosci dla --${name}`);
    }
    index++;
    args[name] = value;
  }
  return args;
}

function rawEd25519PublicKey(publicKey) {
  const der = publicKey.export({ type: 'spki', format: 'der' });
  if (der.length < 32) throw new Error('Nie mozna odczytac publicznego klucza.');
  return der.subarray(der.length - 32);
}

function main() {
  const args = readArgs(process.argv.slice(2));
  const out = path.resolve(args.out || './secrets/update-signing-key.pem');
  if (fs.existsSync(out)) {
    throw new Error(`Plik juz istnieje, nie nadpisuje: ${out}`);
  }

  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(
    out,
    privateKey.export({ type: 'pkcs8', format: 'pem' }),
    { encoding: 'utf8', mode: 0o600 }
  );

  const publicKeyRaw = rawEd25519PublicKey(publicKey).toString('base64url');
  const publicOut = out.replace(/\.pem$/i, '.public.txt');
  fs.writeFileSync(publicOut, `${publicKeyRaw}\n`, 'utf8');

  console.log(`Zapisano prywatny klucz: ${out}`);
  console.log(`Zapisano publiczny klucz: ${publicOut}`);
  console.log('');
  console.log('Dodaj do builda klienta:');
  console.log(`--dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=${publicKeyRaw}`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  console.error('');
  console.error(usage());
  process.exit(1);
}
