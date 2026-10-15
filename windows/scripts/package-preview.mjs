import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectBuildInputs } from './build-inputs.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repository = path.dirname(root);
const packageData = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const delivery = path.join(repository, '.build', 'windows-delivery', packageData.version);
const target = path.join(root, 'src-tauri', 'target', 'x86_64-pc-windows-msvc', 'release');
const executable = path.join(target, 'xisland.exe');
const installer = path.join(target, 'bundle', 'nsis', `X Island_${packageData.version}_x64-setup.exe`);
const inspection = JSON.parse(await readFile(path.join(repository, 'docs/windows/evidence/installer-inspection.json'), 'utf8'));
if (inspection.installerSha256 !== createHash('sha256').update(await readFile(installer)).digest('hex')) {
  throw new Error('安装器与独立解包检查不一致，请先复核当前产物');
}
const buildInputs = JSON.parse(await readFile(path.join(repository, '.build/windows-build-inputs', `${packageData.version}.json`), 'utf8'));
const currentInputs = await collectBuildInputs();
if (currentInputs.digest !== buildInputs.digest) throw new Error('构建后源码或资源发生变化，不能把当前工作树标记为该安装包的来源；请重新构建');
const executableBytes = await readFile(executable);
const peOffset = executableBytes.readUInt32LE(0x3c);
if (executableBytes.toString('ascii', 0, 2) !== 'MZ' || executableBytes.readUInt16LE(peOffset + 4) !== 0x8664) {
  throw new Error('主程序不是 x64 Windows PE，停止打包');
}
await stat(installer);
const files = [
  [installer, `XIsland-Windows-${packageData.version}-preview-x64-setup.exe`],
  [path.join(root, 'scripts', 'Test-XIsland.ps1'), 'Test-XIsland.ps1'],
  [path.join(repository, 'docs/windows/windows-test-checklist.md'), 'Windows验收说明.md'],
  [path.join(root, 'README.md'), 'README.md'],
  [path.join(root, 'src-tauri/resources/LICENSE-node.txt'), 'LICENSE-node.txt'],
  [path.join(repository, 'LICENSE'), 'LICENSE-XIsland.txt'],
];
await mkdir(delivery, { recursive: true });
const artifacts = [];
for (const [source, name] of files) {
  const bytes = await readFile(source);
  await copyFile(source, path.join(delivery, name));
  artifacts.push({ name, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
}
const sourceFiles = [];
async function collect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (['node_modules', 'target', 'dist', 'gen', 'test-results', 'playwright-report', '.runtime'].includes(entry.name)) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) await collect(file);
    else if (/\.(?:ts|rs|json|toml|css|html|mjs|ps1|sh)$/.test(entry.name)) {
      sourceFiles.push({ path: path.relative(root, file), sha256: createHash('sha256').update(await readFile(file)).digest('hex') });
    }
  }
}
await collect(root);
sourceFiles.sort((a, b) => a.path.localeCompare(b.path));
const manifest = {
  product: 'XIsland for Windows', version: packageData.version, channel: 'development-preview',
  createdAt: new Date().toISOString(), target: 'x86_64-pc-windows-msvc',
  crossCompiled: true, signed: false, windowsRuntimeVerified: false, fullMacParityVerified: false,
  artifacts, unbundledExecutableSha256: createHash('sha256').update(executableBytes).digest('hex'),
  installedExecutableSha256: inspection.files.find(file => file.path === 'xisland.exe').sha256,
  bundleInspection: inspection, buildInputs,
  workingTreeSnapshot: { capturedAt: new Date().toISOString(), artifactSourceMatchVerified: true, files: sourceFiles },
};
await writeFile(path.join(delivery, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
await writeFile(path.join(repository, 'docs/windows/evidence/delivery-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`已打包 ${artifacts.length} 个测试材料；Windows 运行及完整功能对齐仍待验证。`);
for (const artifact of artifacts) console.log(`${artifact.name}  ${artifact.sha256}`);
