#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const platforms = ['windows', 'linux', 'android'];

function loadDotEnv(file = '.env') {
  const envPath = path.resolve(file);
  if (!fs.existsSync(envPath)) return;
  const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    const key = trimmed.slice(0, separator).trim();
    let value = trimmed.slice(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    process.env[key] ||= value;
  }
}

function usage() {
  return `
Uzycie:
  node scripts/publish-update.js --version 1.0.1 --build 2 --windows ./secure-p2p-windows.zip --linux ./secure-p2p-linux.zip --android ./secure-p2p-android.apk --notes "Opis zmian"

Opcje:
  --version      Wersja widoczna w aplikacji, np. 1.0.1
  --build        Numer builda. Musi rosnac przy kazdej aktualizacji.
  --windows      Sciezka do paczki ZIP dla Windows.
  --linux        Sciezka do paczki ZIP dla Linuxa.
  --android      Sciezka do APK dla Androida.
  --notes        Opis zmian. Mozesz podac kilka razy.
  --manifest     Sciezka manifestu. Domyslnie UPDATE_MANIFEST_FILE albo ./updates/manifest.json.
  --files-dir    Katalog plikow. Domyslnie UPDATE_FILES_DIR albo ./updates/files.
  --signing-key  Prywatny klucz Ed25519 PEM. Domyslnie UPDATE_SIGNING_KEY_FILE.
`.trim();
}

function readArgs(argv) {
  const args = { notes: [] };
  for (let index = 0; index < argv.length; index++) {
    const key = argv[index];
    if (!key.startsWith('--')) {
      throw new Error(`Nieznany argument: ${key}`);
    }
    const name = key.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new Error(`Brak wartosci dla --${name}`);
    }
    index++;
    if (name === 'notes') {
      args.notes.push(value);
    } else {
      args[name] = value;
    }
  }
  return args;
}

function requireText(args, key) {
  const value = args[key]?.trim();
  if (!value) throw new Error(`Brak wymaganego --${key}`);
  return value;
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  const data = fs.readFileSync(filePath);
  hash.update(data);
  return hash.digest('hex');
}

function copyArtifact(filesDir, sourcePath) {
  const absoluteSource = path.resolve(sourcePath);
  if (!fs.existsSync(absoluteSource)) {
    throw new Error(`Plik nie istnieje: ${absoluteSource}`);
  }
  const stat = fs.statSync(absoluteSource);
  if (!stat.isFile()) {
    throw new Error(`To nie jest plik: ${absoluteSource}`);
  }

  fs.mkdirSync(filesDir, { recursive: true });
  const fileName = path.basename(absoluteSource);
  const destination = path.join(filesDir, fileName);
  fs.copyFileSync(absoluteSource, destination);

  return {
    file: fileName,
    sha256: sha256File(destination),
    size: fs.statSync(destination).size
  };
}

function canonicalJson(value) {
  if (value === null || typeof value === 'number' || typeof value === 'boolean' || typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(',')}]`;
  }
  if (typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  throw new Error(`Nieobslugiwany typ JSON: ${typeof value}`);
}

function signManifestLatest(latest, signingKeyFile) {
  const keyPath = path.resolve(signingKeyFile);
  if (!fs.existsSync(keyPath)) {
    throw new Error(`Brak prywatnego klucza podpisu: ${keyPath}`);
  }
  const privateKey = crypto.createPrivateKey(fs.readFileSync(keyPath, 'utf8'));
  const payload = Buffer.from(canonicalJson({
    protocol: 'secure-chat-update-manifest/v1',
    latest
  }), 'utf8');
  return crypto.sign(null, payload, privateKey).toString('base64url');
}

function main() {
  loadDotEnv();
  const args = readArgs(process.argv.slice(2));
  const version = requireText(args, 'version');
  const buildNumber = Number.parseInt(requireText(args, 'build'), 10);
  if (!Number.isInteger(buildNumber) || buildNumber < 1) {
    throw new Error('--build musi byc dodatnia liczba calkowita.');
  }

  const manifestFile = path.resolve(
    args.manifest || process.env.UPDATE_MANIFEST_FILE || './updates/manifest.json'
  );
  const filesDir = path.resolve(
    args['files-dir'] || process.env.UPDATE_FILES_DIR || './updates/files'
  );
  const signingKeyFile = args['signing-key'] || process.env.UPDATE_SIGNING_KEY_FILE;
  if (!signingKeyFile) {
    throw new Error('Brak --signing-key albo UPDATE_SIGNING_KEY_FILE. Nie publikuje niepodpisanego manifestu.');
  }

  const artifacts = {};
  for (const platform of platforms) {
    if (args[platform]) {
      artifacts[platform] = copyArtifact(filesDir, args[platform]);
    }
  }
  if (Object.keys(artifacts).length === 0) {
    throw new Error('Podaj przynajmniej jedna paczke: --windows, --linux albo --android.');
  }

  const latest = {
    version,
    buildNumber,
    releasedAt: new Date().toISOString(),
    notes: args.notes.length > 0 ? args.notes : ['Nowa wersja aplikacji.'],
    artifacts
  };
  const manifest = {
    v: 2,
    latest,
    signature: {
      protocol: 'secure-chat-update-manifest/v1',
      algorithm: 'Ed25519',
      signature: signManifestLatest(latest, signingKeyFile)
    }
  };

  fs.mkdirSync(path.dirname(manifestFile), { recursive: true });
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

  console.log(`Zapisano manifest: ${manifestFile}`);
  console.log(`Pliki aktualizacji: ${filesDir}`);
  for (const [platform, artifact] of Object.entries(artifacts)) {
    console.log(`${platform}: ${artifact.file} sha256=${artifact.sha256}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  console.error('');
  console.error(usage());
  process.exit(1);
}
