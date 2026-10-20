// node --expose-gc --import tsx scripts/benchmark-session-snapshots.ts [--store /absolute/path/session-store.ts]
// --store 可指向改动前的隔离 core 目录；每个样本使用独立进程，避免大样本污染下一组堆基线。
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { cpus, platform, arch } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import type { Session, StoreSnapshot } from '../src/core/types';

const args = process.argv.slice(2);
const argument = (name: string) => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
const modulePath = argument('--store') ?? fileURLToPath(new URL('../src/core/session-store.ts', import.meta.url));
const countArgument = argument('--case');
if (countArgument === undefined) {
  const samples = [0, 1000, 10_000, 50_000].map(count => {
    const result = spawnSync(process.execPath, ['--expose-gc', '--import', 'tsx', fileURLToPath(import.meta.url),
      '--store', modulePath, '--case', String(count)], { encoding: 'utf8' });
    if (result.status !== 0) throw new Error(result.stderr || result.stdout);
    return JSON.parse(result.stdout);
  });
  console.log(JSON.stringify({ measuredAt: new Date().toISOString(), host: `${platform()} ${arch()}`, cpu: cpus()[0]?.model,
    node: process.version, modulePath, storeSha256: createHash('sha256').update(readFileSync(modulePath)).digest('hex'),
    listeners: 4, warmups: 3, measuredRevisions: 20,
    method: 'Two completed sessions; fixed event payload; select toggles invalidate each revision. Four listeners retain latest snapshots. Heap after explicit GC. Timings cover select and all listener snapshots, not UI or Windows native IPC.', samples }, null, 2));
} else {
  if (!global.gc) throw new Error('Run node with --expose-gc');
  const { SessionStore } = await import(pathToFileURL(modulePath).href) as typeof import('../src/core/session-store');
  const count = Number(countArgument), timestamp = 1_760_227_200_000;
  const base: Session = { id: 'one', agentType: 'claude_code', status: 'completed', prompt: '', statusText: '', agentResponse: '',
    workingDirectory: 'C:\\benchmark', startedAt: timestamp, lastActivityAt: timestamp, completedAt: timestamp,
    subagentIds: [], events: [], chatHistory: [], pendingInteractions: [], backgroundTasks: [],
    usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, costUSD: 0, model: '' } };
  base.events = Array.from({ length: count }, (_, index) => ({ id: `event-${index}`, toolCallId: `call-${index}`, tool: 'Read',
    input: 'C:\\benchmark\\source.ts', result: 'Small fixed tool result', isComplete: true, completionUnconfirmed: false, timestamp }));
  const serialized = JSON.stringify({ version: 1, selectedSessionId: 'one', sessions: [base, { ...base, id: 'two', events: [] }] });
  base.events = [];
  global.gc(); const before = process.memoryUsage();
  const store = new SessionStore({ ownerInstanceId: 'benchmark-owner' }); store.restore(serialized);
  const retained: StoreSnapshot[] = [];
  for (let index = 0; index < 4; index++) store.subscribe(snapshot => { retained[index] = snapshot; });
  let selected = 'one';
  const durations: number[] = [];
  for (let index = 0; index < 23; index++) {
    selected = selected === 'one' ? 'two' : 'one'; const start = performance.now(); store.select(selected);
    if (index >= 3) durations.push(performance.now() - start);
  }
  const readStart = performance.now();
  for (let index = 0; index < 100; index++) store.snapshot();
  const repeatedReadMs = performance.now() - readStart;
  global.gc(); const after = process.memoryUsage();
  durations.sort((a, b) => a - b);
  const mib = (bytes: number) => Math.round(bytes / 1024 / 1024 * 1000) / 1000;
  console.log(JSON.stringify({ events: count, serializedMiB: mib(Buffer.byteLength(serialized)),
    snapshotP50Ms: durations[Math.floor(durations.length * 0.5)], snapshotP95Ms: durations[Math.ceil(durations.length * 0.95) - 1],
    repeatedRead100Ms: repeatedReadMs, heapBeforeMiB: mib(before.heapUsed), heapAfterMiB: mib(after.heapUsed),
    retainedHeapDeltaMiB: mib(after.heapUsed - before.heapUsed), rssBeforeMiB: mib(before.rss), rssAfterMiB: mib(after.rss),
    peakRssMiB: mib(process.resourceUsage().maxRSS * 1024), distinctListenerSnapshots: new Set(retained).size }));
}
