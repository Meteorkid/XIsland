const { test } = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const fs = require('node:fs');
const { ObservationTransport } = require('../out/transport');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) { const end = Date.now() + 3000; while (!predicate()) { assert(Date.now() < end, 'timed out'); await pause(10); } }
const message = (id, fields = {}) => ({ type: 'status_update', sessionId: id, agentType: 'roo_code', timestamp: '2026-09-24T00:00:00Z', ...fields });
async function fixture(body, receive = (_, socket) => socket.end(), now) {
    const root = fs.mkdtempSync('/tmp/xi-vsc-'), path = root + '/di.sock', packets = [], clients = new Set(), connections = [];
    const states = [], transport = new ObservationTransport(path, state => states.push(state), 20, now);
    const server = net.createServer({ allowHalfOpen: true }, socket => {
        const connection = { socket, raw: '' }; connections.push(connection);
        clients.add(socket); socket.on('close', () => clients.delete(socket)); socket.setEncoding('utf8');
        socket.on('error', () => {});
        // SocketServer.handleClient 只消费首个换行消息，然后关闭观察连接。
        let consumed = false;
        socket.on('end', () => { if (!consumed) socket.end(); });
        socket.on('data', data => {
            connection.raw += data;
            if (consumed) return;
            const newline = connection.raw.indexOf('\n');
            if (newline < 0) return;
            consumed = true;
            const packet = JSON.parse(connection.raw.slice(0, newline));
            packets.push(packet);
            receive(packet, socket, connections.length);
        });
    });
    try { await body({ transport, packets, states, server, clients, connections, listen: () => new Promise(resolve => server.listen(path, resolve)) }); }
    finally { transport.dispose(); for (const client of clients) client.destroy(); if (server.listening) await new Promise(resolve => server.close(resolve)); fs.rmSync(root, { recursive: true, force: true }); }
}

test('queues the first messages until connection is ready and retains event ordering', async () => fixture(async f => {
    f.transport.send(message('one', { type: 'session_start' }));
    f.transport.send(message('one', { nativeMessageId: '1', status: 'partial' }));
    f.transport.send(message('one', { nativeMessageId: '1', status: 'final' }));
    f.transport.send(message('one', { observedState: 'idle' }));
    await pause(40); await f.listen(); await until(() => f.packets.length === 3);
    assert.deepEqual(f.packets.map(p => p.type), ['session_start', 'status_update', 'status_update']);
    assert.equal(f.packets[1].status, 'final');
    assert.equal(f.packets[2].observedState, 'idle');
    await until(() => f.clients.size === 0);
    assert.equal(f.connections.length, 3);
    assert(f.connections.every(c => c.raw.split('\n').length === 2));
    await pause(60);
    assert.equal(f.connections.length, 3, 'an empty queue must not create idle reconnects');
}));

test('disable discards queued data and dispose does not reconnect or emit session_end', async () => fixture(async f => {
    f.transport.send(message('one')); f.transport.discard('roo_code');
    await f.listen(); await pause(100); assert.equal(f.packets.length, 0);
    f.transport.dispose(); f.transport.send(message('after-dispose')); await pause(60);
    assert.equal(f.packets.length, 0); assert.equal(f.clients.size, 0);
}));

test('dispose during connection setup prevents writes and reconnects', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('connecting'));
    f.transport.dispose();
    await pause(60);
    assert.equal(f.packets.length, 0);
    const attempts = f.connections.length;
    for (const client of f.clients) client.end();
    await until(() => f.clients.size === 0);
    await pause(60);
    assert.equal(f.connections.length, attempts);
}));

test('failed connections retain every unwritten event until a receiver is available', async () => fixture(async f => {
    f.transport.send(message('first'));
    f.transport.send(message('second'));
    await until(() => f.states.some(s => s.includes('暂未连接')));
    await f.listen();
    await until(() => f.packets.length === 2 && f.clients.size === 0);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['first', 'second']);
}));

test('bounded backlog drops accumulated stale observations on overflow', async () => fixture(async f => {
    for (let i = 0; i < 2200; i++) f.transport.send(message('task-' + i));
    assert(f.states.some(s => s.includes('溢出')));
    await f.listen(); await until(() => f.packets.length > 0);
    assert(f.packets.length < 2200);
    assert(f.packets.every(p => p.type !== 'session_end'));
}));

test('same message ID in different tasks is not merged', async () => fixture(async f => {
    f.transport.send(message('one', { nativeMessageId: 'same', status: 'first' }));
    f.transport.send(message('two', { nativeMessageId: 'same', status: 'second' }));
    await f.listen(); await until(() => f.packets.length === 2);
    assert.deepEqual(f.packets.map(p => p.status), ['first', 'second']);
}));

test('waits for the receiver to close before sending the next event', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('one', { type: 'session_start' }));
    f.transport.send(message('one', { type: 'session_end' }));
    await until(() => f.packets.length === 1);
    await pause(60);
    assert.equal(f.connections.length, 1);
    assert.equal(f.packets.length, 1);
    f.connections[0].socket.end();
    await until(() => f.packets.length === 2);
    assert.deepEqual(f.packets.map(p => p.type), ['session_start', 'session_end']);
}, (_, socket, number) => { if (number !== 1) socket.end(); }));

test('a disconnected receiver does not cause an already written event to be replayed', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('first'));
    f.transport.send(message('second'));
    await until(() => f.packets.length === 2 && f.clients.size === 0);
    await pause(60);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['first', 'second']);
    assert.equal(f.connections.length, 2);
}, (_, socket, number) => { if (number === 1) socket.destroy(); else socket.end(); }));

test('a receiver that never closes times out without replaying the in-flight event', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('stalled'));
    f.transport.send(message('next'));
    await until(() => f.packets.length === 2);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['stalled', 'next']);
    assert.equal(f.connections.length, 2);
}, (_, socket, number) => { if (number !== 1) socket.end(); }));

test('dispose cancels an in-flight connection and drops remaining events', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('in-flight'));
    f.transport.send(message('queued'));
    await until(() => f.packets.length === 1);
    f.transport.dispose();
    f.connections[0].socket.end();
    await until(() => f.clients.size === 0);
    f.transport.send(message('after-dispose'));
    await pause(60);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['in-flight']);
    assert.equal(f.connections.length, 1);
}, () => {}));

test('discard removes only the disabled agent while another event is in flight', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('in-flight'));
    await until(() => f.packets.length === 1);
    f.transport.send(message('roo-queued'));
    f.transport.send(message('pear-queued', { agentType: 'pearai' }));
    f.transport.discard('roo_code');
    f.connections[0].socket.end();
    await until(() => f.packets.length === 2 && f.clients.size === 0);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['in-flight', 'pear-queued']);
}, (_, socket, number) => { if (number !== 1) socket.end(); }));

test('large valid frames finish across chunks and oversized frames are rejected', async () => fixture(async f => {
    await f.listen();
    f.transport.send(message('too-large', { status: 'x'.repeat(256 * 1024) }));
    const status = '大'.repeat(80000);
    f.transport.send(message('large', { status }));
    f.transport.send(message('next'));
    await until(() => f.packets.length === 2 && f.clients.size === 0);
    assert(f.states.some(s => s.includes('消息过大')));
    assert.deepEqual(f.packets.map(p => p.sessionId), ['large', 'next']);
    assert.equal(f.packets[0].status, status);
}));

test('byte-limited backlog drops stale frames and recovers with later events', async () => fixture(async f => {
    for (let i = 0; i < 9; i++) f.transport.send(message('stale-' + i, { status: 'x'.repeat(240000) }));
    f.transport.send(message('fresh'));
    assert(f.states.some(s => s.includes('溢出')));
    await f.listen();
    await until(() => f.packets.length === 1 && f.clients.size === 0);
    assert.deepEqual(f.packets.map(p => p.sessionId), ['fresh']);
}));

test('business backlog expires after 30 seconds and a fresh event does not revive it', async () => {
    let now = 0;
    await fixture(async f => {
        f.transport.send(message('expired', { observationSequence: 1 }));
        await until(() => f.states.some(s => s.includes('暂未连接')));
        now = 30_000;
        f.transport.send(message('fresh', { observationSequence: 2 }));
        await f.listen(); await until(() => f.packets.length === 1 && f.clients.size === 0);
        assert.deepEqual(f.packets.map(m => m.sessionId), ['fresh']);
        assert.equal(f.packets[0].observationSequence, 2);
        assert.equal(f.packets[0].timestamp, '2026-09-24T00:00:00Z');
    }, undefined, () => now);
});

test('heartbeat backlog expires within three seconds without expiring newer business data', async () => {
    let now = 0;
    await fixture(async f => {
        f.transport.send(message('source', { type: 'observation_heartbeat' }));
        await until(() => f.states.some(s => s.includes('暂未连接')));
        now = 3000;
        f.transport.send(message('business'));
        await f.listen(); await until(() => f.packets.length === 1 && f.clients.size === 0);
        assert.deepEqual(f.packets.map(m => m.sessionId), ['business']);
    }, undefined, () => now);
});

test('a frame that expires while connecting is rechecked before writing', async () => {
    let now = 0;
    await fixture(async f => {
        await f.listen();
        f.transport.send(message('expired-on-connect'));
        now = 30_000;
        await pause(60); assert.equal(f.packets.length, 0);
        f.transport.send(message('new-event'));
        await until(() => f.packets.length === 1 && f.clients.size === 0);
        assert.equal(f.packets[0].sessionId, 'new-event');
    }, undefined, () => now);
});

test('discard then drain sends only observation_ended and refuses late events', async () => fixture(async f => {
    f.transport.send(message('stale-business'));
    f.transport.discard('roo_code');
    f.transport.send(message('source', { type: 'observation_ended' }));
    await f.listen();
    const finished = f.transport.drain();
    f.transport.send(message('too-late'));
    await finished;
    assert.deepEqual(f.packets.map(m => m.type), ['observation_ended']);
    assert.equal(f.packets[0].sessionId, 'source');
    await pause(60); assert.equal(f.packets.length, 1);
}));

test('drain completes within its bounded grace period when the receiver is absent', async () => fixture(async f => {
    f.transport.send(message('source', { type: 'observation_ended' }));
    const started = performance.now();
    await f.transport.drain(80);
    assert(performance.now() - started < 1000);
    await f.listen(); await pause(80);
    assert.equal(f.packets.length, 0);
    assert.equal(f.connections.length, 0);
}));
