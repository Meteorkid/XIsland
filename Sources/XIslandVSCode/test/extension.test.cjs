const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const Module = require('node:module');

test('host discovery is version gated, passive, isolated and disposable', { skip: process.platform !== 'darwin' }, async () => {
    const changes = new EventEmitter(), settings = new EventEmitter(), roo = new EventEmitter(), pear = new EventEmitter();
    const received = [], discarded = [], statuses = [], subscriptions = [];
    const enabled = { observeRooCode: true, observePearAIExperimental: false };
    const peers = new Map([
        ['RooVeterinaryInc.roo-cline', { isActive: false, packageJSON: { version: '3.54.0' }, exports: roo, activate() { assert.fail('Must not activate vendor extension'); } }],
        ['PearAI.pearai-roo-cline', { isActive: true, packageJSON: { version: '3.15.3' }, exports: pear }],
    ]);
    const on = (emitter, event, listener) => { emitter.on(event, listener); return { dispose: () => emitter.removeListener(event, listener) }; };
    const vscode = {
        env: { machineId: 'fixture-machine', appName: 'Fixture VS Code', remoteName: undefined },
        workspace: { isTrusted: true, getConfiguration: () => ({ get: key => enabled[key] }), onDidChangeConfiguration: fn => on(settings, 'change', fn) },
        extensions: { getExtension: id => peers.get(id), onDidChange: fn => on(changes, 'change', fn) },
        window: { createStatusBarItem: () => { const status = { show() {}, dispose() {} }; statuses.push(status); return status; } },
        StatusBarAlignment: { Right: 1 },
    };
    class Transport { send(value) { received.push(value); } discard(agent) { discarded.push(agent); } drain() { return Promise.resolve(); } }
    const load = Module._load;
    Module._load = function(request, parent, main) {
        if (request === 'vscode') return vscode;
        if (request === './transport' && parent.filename.endsWith('/out/extension.js')) return { ObservationTransport: Transport };
        return load.call(this, request, parent, main);
    };
    const extension = require('../out/extension');
    try {
        extension.activate({ globalStorageUri: { toString: () => 'file:///fixture/storage' }, subscriptions });
        assert.equal(roo.eventNames().length, 0); assert.equal(pear.eventNames().length, 0);
        peers.get('RooVeterinaryInc.roo-cline').isActive = true; changes.emit('change');
        assert.equal(roo.listenerCount('message'), 1);
        changes.emit('change'); assert.equal(roo.listenerCount('message'), 1);
        roo.emit('taskStarted', 'task'); assert.equal(received.length, 1);
        enabled.observePearAIExperimental = true; settings.emit('change', { affectsConfiguration: () => true });
        pear.emit('taskStarted', 'task'); assert.equal(received.length, 2);
        assert.notEqual(received[0].sessionId, received[1].sessionId);
        peers.get('RooVeterinaryInc.roo-cline').packageJSON.version = '3.54.1'; changes.emit('change');
        assert.equal(roo.listenerCount('message'), 0); assert(discarded.includes('roo_code'));
        vscode.workspace.isTrusted = false; changes.emit('change'); assert.equal(pear.listenerCount('message'), 0);
        assert.equal(received.length, 4);
        assert.deepEqual(received.slice(2).map(m => m.type), ['observation_ended', 'observation_ended']);
        await extension.deactivate(); for (const disposable of subscriptions) await disposable.dispose();
        assert.equal(changes.listenerCount('change'), 0); assert.equal(settings.listenerCount('change'), 0);
        assert.equal(received.length, 4);
    } finally { await extension.deactivate(); Module._load = load; }
});

function host({ sessionId, Transport } = {}) {
    const settings = new EventEmitter(), roo = new EventEmitter(), pear = new EventEmitter();
    const received = [], operations = [], subscriptions = [];
    const enabled = { observeRooCode: true, observePearAIExperimental: true };
    const peers = new Map([
        ['RooVeterinaryInc.roo-cline', { isActive: true, packageJSON: { version: '3.54.0' }, exports: roo }],
        ['PearAI.pearai-roo-cline', { isActive: true, packageJSON: { version: '3.15.3' }, exports: pear }],
    ]);
    const vscode = {
        env: { machineId: 'same-machine', appName: 'Fixture VS Code', ...(sessionId === undefined ? {} : { sessionId }) },
        workspace: { isTrusted: true, getConfiguration: () => ({ get: key => enabled[key] }),
            onDidChangeConfiguration: listener => { settings.on('change', listener); return { dispose: () => settings.removeListener('change', listener) }; } },
        extensions: { getExtension: id => peers.get(id), onDidChange: () => ({ dispose() {} }) },
        window: { createStatusBarItem: () => ({ show() {}, dispose() {} }) }, StatusBarAlignment: { Right: 1 },
    };
    class RecordingTransport {
        send(message) { received.push(message); operations.push(message.type); }
        discard(agent) { operations.push('discard:' + agent); }
        drain() { operations.push('drain'); return Promise.resolve(); }
    }
    const load = Module._load;
    Module._load = function(request, parent, main) {
        if (request === 'vscode') return vscode;
        if (request === './transport' && parent.filename.endsWith('/out/extension.js')) return { ObservationTransport: Transport ?? RecordingTransport };
        return load.call(this, request, parent, main);
    };
    let extension;
    try {
        // 每个模块副本代表一个独立扩展宿主。
        delete require.cache[require.resolve('../out/extension')];
        extension = require('../out/extension');
    } finally { Module._load = load; }
    const context = { globalStorageUri: { toString: () => 'file:///same-profile/storage' }, subscriptions };
    return { roo, pear, enabled, received, operations,
        refresh: () => settings.emit('change', { affectsConfiguration: () => true }),
        activate: () => extension.activate(context), stop: () => extension.deactivate() };
}

for (const sessionId of [undefined, 'shared-vscode-session']) {
    test(`activate isolates same-profile windows with ${sessionId === undefined ? 'missing' : 'fixed'} env.sessionId`, { skip: process.platform !== 'darwin' }, async () => {
        const a = host({ sessionId }), b = host({ sessionId });
        try {
            for (const h of [a, b]) {
                h.activate();
                h.roo.emit('taskStarted', '同一个/task'); h.pear.emit('taskStarted', '同一个/task');
                h.roo.emit('taskSpawned', '同一个/task', '子任务'); h.pear.emit('taskSpawned', '同一个/task', '子任务');
            }
            for (let index = 0; index < 4; index++) {
                const left = a.received[index], right = b.received[index];
                assert.equal(left.sourceNamespace, right.sourceNamespace);
                assert.match(left.sourceNamespace, /^[0-9a-f]{24}$/);
                assert.notEqual(left.sourceInstanceId, right.sourceInstanceId);
                assert.notEqual(left.sessionId, right.sessionId);
                if (index >= 2) assert.notEqual(left.subagentId, right.subagentId);
                assert.equal(left.nativeTaskId, '同一个/task');
            }
            assert.equal(a.received[0].sourceInstanceId, a.received[2].sourceInstanceId);
            const first = a.received[0];
            a.enabled.observeRooCode = false; a.refresh();
            assert.deepEqual(a.operations.slice(-2), ['discard:roo_code', 'observation_ended']);
            a.enabled.observeRooCode = true; a.refresh(); a.roo.emit('taskStarted', '同一个/task');
            const next = a.received.at(-1);
            assert.equal(next.sourceNamespace, first.sourceNamespace);
            assert.notEqual(next.sourceInstanceId, first.sourceInstanceId);
            assert.equal(next.observationSequence, 1);
            b.roo.emit('taskActive', '同一个/task');
            assert.equal(b.received.at(-1).sourceInstanceId, b.received[0].sourceInstanceId);
            a.activate(); a.roo.emit('taskStarted', '同一个/task');
            assert.notEqual(a.received.at(-1).sourceInstanceId, next.sourceInstanceId);
            assert.equal(a.roo.listenerCount('taskStarted'), 1);
        } finally { await a.stop(); await b.stop(); }
    });
}

const fs = require('node:fs'), net = require('node:net');
const { ObservationTransport } = require('../out/transport');
const { createBridge } = require('./bridge-fixture.cjs');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) {
    const deadline = Date.now() + 3000;
    while (!predicate()) { assert(Date.now() < deadline, 'timed out'); await pause(10); }
}

test('activate keeps its instance across socket reconnects and drains observation_ended on deactivation', { skip: process.platform !== 'darwin' }, async () => {
    const root = fs.mkdtempSync('/tmp/xi-host-'), socketPath = root + '/di.sock';
    const packets = [], clients = new Set();
    const server = net.createServer({ allowHalfOpen: true }, socket => {
        clients.add(socket); socket.on('close', () => clients.delete(socket)); socket.on('error', () => {});
        let raw = '', consumed = false;
        socket.setEncoding('utf8'); socket.on('data', data => {
            raw += data;
            if (consumed || !raw.includes('\n')) return;
            consumed = true; packets.push(JSON.parse(raw.slice(0, raw.indexOf('\n'))));
            if (packets.length === 1) socket.destroy(); else socket.end();
        });
    });
    const bridgePath = createBridge(root);
    class LocalTransport extends ObservationTransport { constructor(_, status) { super(socketPath, status, 20, undefined, bridgePath); } }
    const h = host({ Transport: LocalTransport });
    try {
        await new Promise(resolve => server.listen(socketPath, resolve));
        h.activate(); h.roo.emit('taskStarted', 'same-task');
        await until(() => packets.length === 1);
        h.roo.emit('taskActive', 'same-task'); await until(() => packets.length === 2);
        h.roo.emit('taskPaused', 'same-task'); await until(() => packets.length === 3);
        await h.stop();
        assert.deepEqual(packets.map(m => m.type), ['session_start', 'status_update', 'status_update', 'observation_ended']);
        assert.equal(new Set(packets.map(m => m.sourceInstanceId)).size, 1);
        assert.equal(new Set(packets.slice(0, 3).map(m => m.sessionId)).size, 1);
        assert.deepEqual(packets.map(m => m.observationSequence), [1, 2, 3, 4]);
        assert(!('nativeTaskId' in packets.at(-1)));
    } finally {
        await h.stop(); for (const client of clients) client.destroy();
        if (server.listening) await new Promise(resolve => server.close(resolve));
        fs.rmSync(root, { recursive: true, force: true });
    }
});
