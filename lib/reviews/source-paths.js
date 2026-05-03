const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

function assertAbsolutePath(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} is required`);
  }
  if (!path.isAbsolute(value)) {
    throw new Error(`${label} must be an absolute path`);
  }
  return path.resolve(value);
}

function assertPathInside(parentDir, childPath, childLabel) {
  const relative = path.relative(parentDir, childPath);
  if (!relative || relative === '') return;
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${childLabel} must be inside workspaceDir`);
  }
}

function resolveGitTrackedSource(workspaceDir, sourcePath) {
  const resolvedWorkspaceDir = assertAbsolutePath(workspaceDir, 'workspaceDir');
  const resolvedSourcePath = assertAbsolutePath(sourcePath, 'sourcePath');
  assertPathInside(resolvedWorkspaceDir, resolvedSourcePath, 'sourcePath');
  const realWorkspaceDir = fs.realpathSync.native
    ? fs.realpathSync.native(resolvedWorkspaceDir)
    : fs.realpathSync(resolvedWorkspaceDir);
  const realSourcePath = fs.realpathSync.native
    ? fs.realpathSync.native(resolvedSourcePath)
    : fs.realpathSync(resolvedSourcePath);
  assertPathInside(realWorkspaceDir, realSourcePath, 'sourcePath');

  let gitRoot;
  try {
    gitRoot = execFileSync('git', ['-C', realWorkspaceDir, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    gitRoot = fs.realpathSync.native ? fs.realpathSync.native(gitRoot) : fs.realpathSync(gitRoot);
  } catch (_error) {
    throw new Error('workspaceDir must be inside a git repository');
  }

  const relativeToGitRoot = path.relative(gitRoot, realSourcePath);
  if (relativeToGitRoot.startsWith('..') || path.isAbsolute(relativeToGitRoot)) {
    throw new Error('sourcePath must be inside the git repository for workspaceDir');
  }

  try {
    execFileSync('git', ['-C', gitRoot, 'ls-files', '--error-unmatch', relativeToGitRoot], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
  } catch (_error) {
    throw new Error('sourcePath must point to a git-tracked file');
  }

  return {
    gitRoot,
    workspaceDir: resolvedWorkspaceDir,
    sourcePath: resolvedSourcePath,
    relativeToGitRoot,
  };
}

function readSourceDocument(sourcePath) {
  return fs.readFileSync(sourcePath, 'utf8');
}

module.exports = {
  assertAbsolutePath,
  assertPathInside,
  readSourceDocument,
  resolveGitTrackedSource,
};
