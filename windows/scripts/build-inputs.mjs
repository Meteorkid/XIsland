import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const excluded = new Set(['node_modules', 'target', 'dist', 'gen', 'test-results', 'playwright-report', '.runtime']);
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export async function collectBuildInputs() {
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (excluded.has(entry.name)) continue;
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await visit(file);
      else if (!entry.name.endsWith('.cjs') && /\.(?:ts|rs|json|toml|lock|css|html|mjs|ps1|sh|png|ico|icns|exe|txt)$/.test(entry.name)) {
        files.push({ path: path.relative(projectRoot, file).replaceAll(path.sep, '/'), sha256: sha256(await readFile(file)) });
      }
    }
  }
  await visit(projectRoot);
  const license = path.resolve(projectRoot, '../LICENSE');
  files.push({ path: '../LICENSE', sha256: sha256(await readFile(license)) });
  files.sort((a, b) => a.path.localeCompare(b.path, 'en'));
  return { digest: sha256(JSON.stringify(files)), files };
}

export async function captureBuildInputs() {
  const { version } = JSON.parse(await readFile(path.join(projectRoot, 'package.json'), 'utf8'));
  const input = await collectBuildInputs();
  const output = path.resolve(projectRoot, `../.build/windows-build-inputs/${version}.json`);
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output, JSON.stringify({ version, capturedAt: new Date().toISOString(), ...input }, null, 2) + '\n');
  console.log(`构建输入已冻结：${input.files.length} 个文件，${input.digest}`);
  return input;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await captureBuildInputs();
