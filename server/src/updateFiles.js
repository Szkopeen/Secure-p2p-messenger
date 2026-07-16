import fs from 'node:fs';
import path from 'node:path';

export class SafeUpdateFileError extends Error {
  constructor(code = 'NOT_FOUND') {
    super(code);
    this.code = code;
  }
}

function isOutsideDirectory(baseDir, file) {
  const relativePath = path.relative(baseDir, file);
  return relativePath.startsWith('..') || path.isAbsolute(relativePath);
}

export function safeOpenUpdateFile(baseDir, fileName, { maxBytes = Number.MAX_SAFE_INTEGER } = {}) {
  const resolvedBaseDir = path.resolve(baseDir);
  const file = path.resolve(resolvedBaseDir, fileName);
  if (!fileName || isOutsideDirectory(resolvedBaseDir, file)) {
    throw new SafeUpdateFileError('NOT_FOUND');
  }

  let fd;
  try {
    const baseRealPath = fs.realpathSync(resolvedBaseDir);
    const linkStat = fs.lstatSync(file);
    if (linkStat.isSymbolicLink() || !linkStat.isFile()) {
      throw new SafeUpdateFileError('NOT_FOUND');
    }

    const fileRealPath = fs.realpathSync(file);
    if (isOutsideDirectory(baseRealPath, fileRealPath)) {
      throw new SafeUpdateFileError('NOT_FOUND');
    }

    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) {
      throw new SafeUpdateFileError('NOT_FOUND');
    }
    if (stat.size > maxBytes) {
      throw new SafeUpdateFileError('TOO_LARGE');
    }
    return { fd, file, stat };
  } catch (error) {
    if (fd != null) fs.closeSync(fd);
    if (error instanceof SafeUpdateFileError) throw error;
    throw new SafeUpdateFileError('NOT_FOUND');
  }
}
