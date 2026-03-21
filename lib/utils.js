const fs = require("fs");
const path = require("path");

function ensureDirectory(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function ensureParentDirectory(filePath) {
  ensureDirectory(path.dirname(filePath));
}

module.exports = { ensureDirectory, ensureParentDirectory };
