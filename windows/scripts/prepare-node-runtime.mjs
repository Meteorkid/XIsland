import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cache = path.resolve(root, '../.build/windows-node-runtime');
const resources = path.join(root, 'src-tauri/resources');
const version = 'v24.21.0';
const expected = 'ba4e6d110e8c1592a1ecd390f6b05f3da124b13871a5be62b341a07a853c6c32';
const source = `https://nodejs.org/dist/${version}/win-x64/node.exe`;
await mkdir(cache, { recursive: true }); await mkdir(resources, { recursive: true });
const node = path.join(cache, `${version}-node.exe`);
const digest = async file => createHash('sha256').update(await readFile(file)).digest('hex');
if (await digest(node).catch(() => '') !== expected) {
  await run('curl', ['--http1.1', '--fail', '--silent', '--show-error', '--location', '--retry', '2', '--max-time', '240', source, '--output', node], { maxBuffer: 1024 * 1024 });
  if (await digest(node) !== expected) throw new Error('官方 Node.js 运行时 SHA-256 不匹配，停止打包');
}
const license = path.join(cache, `${version}-LICENSE.txt`);
try { await readFile(license); }
catch { await run('curl', ['--http1.1', '--fail', '--silent', '--show-error', '--location', '--retry', '2', '--max-time', '60', `https://raw.githubusercontent.com/nodejs/node/${version}/LICENSE`, '--output', license]); }
if (!(await readFile(license, 'utf8')).includes('Node.js')) throw new Error('Node.js 许可文件不完整');
await copyFile(node, path.join(resources, 'node.exe'));
await copyFile(license, path.join(resources, 'LICENSE-node.txt'));
await copyFile(path.resolve(root, '../LICENSE'), path.join(resources, 'LICENSE-XIsland.txt'));
await writeFile(path.join(resources, 'node-runtime.json'), JSON.stringify({ version, platform: 'win32-x64', source,
  sha256: expected, checksumSource: `https://nodejs.org/dist/${version}/SHASUMS256.txt`,
  license: 'LICENSE-node.txt', globalInstallation: false }, null, 2) + '\n');
console.log(`已准备隔离的 Windows Node.js ${version}；未安装全局运行时或修改 PATH。`);
