import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';

await mkdir('src-tauri/resources', { recursive: true });
await build({ entryPoints: ['src/hook.ts'], outfile: 'src-tauri/resources/xisland-hook.cjs', bundle: true, platform: 'node', target: 'node20', format: 'cjs' });
