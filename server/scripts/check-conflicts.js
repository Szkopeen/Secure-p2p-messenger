import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');
const ignoredDirs = new Set([
  '.dart_tool',
  '.git',
  'build',
  'node_modules',
  'vendor'
]);
const ignoredExtensions = new Set([
  '.apk',
  '.dll',
  '.exe',
  '.ico',
  '.jar',
  '.png',
  '.so',
  '.zip'
]);
const findings = [];

function walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (ignoredDirs.has(entry.name)) continue;
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath);
      continue;
    }
    if (!entry.isFile() || ignoredExtensions.has(path.extname(entry.name))) {
      continue;
    }
    scanFile(fullPath);
  }
}

function scanFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.startsWith('<<<<<<< ') || line === '=======' || line.startsWith('>>>>>>> ')) {
      findings.push(`${path.relative(repoRoot, filePath)}:${index + 1}:${line}`);
    }
  }
}

walk(repoRoot);

if (findings.length > 0) {
  console.error('Znaleziono nierozwiazane markery konfliktu Git:');
  for (const finding of findings) console.error(finding);
  process.exit(1);
}

console.log('Brak markerow konfliktu Git.');