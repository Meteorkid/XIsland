const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { observeTasks } = require('../out/task-observer');

const namespace = '0123456789abcdef01234567';
function fixture(agent = 'roo_code', source = namespace) {
    const api = new EventEmitter(), messages = [];
    for (const name of ['sendMessage', 'pressPrimaryButton', 'pressSecondaryButton', 'startNewTask', 'getConfiguration']) {
        api[name] = () => assert.fail('Observer must not call ' + name);
    }
    return { api, messages, observer: observeTasks(api, agent, source, value => messages.push(value)) };
}
function row(api, taskId, ts, fields, action = 'created') {
    api.emit('message', { taskId, action, message: { ts, type: 'say', ...fields } });
}

for (const agent of ['roo_code', 'pearai']) {
    test(agent + ': native identity, lifecycle and no synthetic shutdown', () => {
        const { api, messages, observer } = fixture(agent);
        api.emit('taskCreated', 'id / 中文');
        row(api, 'id / 中文', 1, { say: 'text', text: 'Initial user task' });
        assert.equal(messages.length, 0);
        api.emit('taskStarted', 'id / 中文');
        api.emit('taskCompleted', 'id / 中文', { totalTokensIn: 5, totalTokensOut: 3, totalCost: 0.02 }, {});
        assert.equal(messages[0].sessionId, `${agent}-${namespace}-${messages[0].sourceInstanceId}-${Buffer.from('id / 中文').toString('base64url')}`);
        assert.equal(messages[0].sourceNamespace, namespace);
        assert.match(messages[0].sourceInstanceId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
        assert.equal(messages[0].nativeTaskId, 'id / 中文');
        assert.equal(messages[0].type, 'session_start');
        assert.equal(messages[1].observedState, 'idle');
        assert.equal(messages[1].usageIsCumulative, true);
        assert.equal(messages[1].tokensIn, 5);
        observer.dispose(); observer.dispose();
        assert.equal(messages.length, 3);
        assert.equal(messages[2].type, 'observation_ended');
        assert.equal(messages[2].sessionId, `${agent}-${namespace}-${messages[0].sourceInstanceId}`);
        assert(!('nativeTaskId' in messages[2]));
        assert.deepEqual(messages.map(m => m.observationSequence), [1, 2, 3]);
        assert(!messages.some(m => m.type === 'session_end'));
        assert.equal(api.eventNames().length, 0);
    });
    test(agent + ': streaming IDs, duplicate suppression and user feedback', () => {
        const { api, messages, observer } = fixture(agent);
        api.emit('taskStarted', 'task');
        row(api, 'task', 10, { say: 'text', text: '半', partial: true });
        row(api, 'task', 10, { say: 'text', text: '完整', partial: false }, 'updated');
        row(api, 'task', 10, { say: 'text', text: '完整', partial: false }, 'updated');
        row(api, 'task', 11, { say: 'user_feedback', text: '继续' });
        assert.equal(messages.length, 4);
        assert.equal(messages[1].nativeMessageId, messages[2].nativeMessageId);
        assert.equal(messages[1].nativeMessagePartial, true);
        assert.equal(messages[2].statusIsAssistantReply, true);
        assert.equal(messages[3].prompt, '继续');
        assert.equal(messages[3].statusIsAssistantReply, false);
        assert(messages.every(m => m.sessionId && !('session_id' in m) && m.timestamp));
        observer.dispose();
    });
    test(agent + ': aborted tasks ignore late events and explicit start resumes', () => {
        const { api, messages, observer } = fixture(agent);
        api.emit('taskStarted', 'task'); api.emit('taskAborted', 'task');
        row(api, 'task', 30, { say: 'completion_result', text: 'Late' });
        api.emit('taskCompleted', 'task', {}); api.emit('taskCreated', 'task');
        assert.equal(messages.length, 2);
        api.emit('taskStarted', 'task'); row(api, 'task', 31, { say: 'text', text: 'Resumed' });
        assert.equal(messages.length, 4);
        observer.dispose();
    });
    test(agent + ': malformed data cannot create approval or crash provider', () => {
        const { api, messages, observer } = fixture(agent);
        for (const bad of [null, {}, { taskId: 'a', action: 'created', message: { ts: NaN, type: 'say' } }]) {
            assert.doesNotThrow(() => api.emit('message', bad));
        }
        api.emit('taskStarted', ''); api.emit('taskStarted', 'bad\0id');
        assert.equal(messages.length, 0);
        api.emit('taskStarted', 'good');
        row(api, 'good', 40, { type: 'ask', ask: 'command', text: 'dangerous command', partial: true });
        assert.equal(messages.length, 1);
        row(api, 'good', 40, { type: 'ask', ask: 'command', text: 'command', partial: false }, 'updated');
        assert.equal(messages.at(-1).type, 'status_update');
        assert(!messages.some(m => ['permission_request', 'question', 'plan_review'].includes(m.type)));
        observer.dispose();
    });
}

test('only Roo authoritative taskInteractive maps a complete ask to waiting', () => {
    const roo = fixture(), pear = fixture('pearai');
    for (const f of [roo, pear]) {
        f.api.emit('taskStarted', 'task');
        row(f.api, 'task', 50, { type: 'ask', ask: 'command_output', text: 'flow control' });
        f.api.emit('taskInteractive', 'task');
        assert.equal(f.messages.at(-1).observedState, undefined);
        row(f.api, 'task', 51, { type: 'ask', ask: 'followup', text: 'Question' });
        f.api.emit('taskInteractive', 'task');
    }
    assert.equal(roo.messages.at(-1).observedState, 'waitingAnswer');
    assert.equal(pear.messages.at(-1).observedState, undefined);
    roo.api.emit('taskAskResponded', 'task');
    assert.equal(roo.messages.at(-1).observedState, 'active');
    roo.observer.dispose(); pear.observer.dispose();
});

test('host/task identity separates namespaces and subtask IDs', () => {
    const a = fixture(), b = fixture('roo_code', 'fedcba9876543210fedcba98');
    a.api.emit('taskSpawned', 'parent', 'child'); b.api.emit('taskSpawned', 'parent', 'child');
    assert.notEqual(a.messages[0].sessionId, b.messages[0].sessionId);
    assert.notEqual(a.messages[0].subagentId, b.messages[0].subagentId);
    assert.equal(a.messages[0].parentSessionId, a.messages[0].sessionId);
    assert.equal(a.messages[0].subagentId, `roo_code-${namespace}-${a.messages[0].sourceInstanceId}-${Buffer.from('child').toString('base64url')}`);
    a.api.emit('taskDelegationCompleted', 'parent', 'child', 'result');
    assert.equal(a.messages[1].subagentId, a.messages[0].subagentId);
    assert.equal(a.messages[1].type, 'subagent_end');
    a.observer.dispose(); b.observer.dispose();
});

test('metrics reject nonfinite snapshots and do not confuse context with total usage', () => {
    const f = fixture();
    f.api.emit('taskTokenUsageUpdated', 'task', { totalTokensIn: NaN, totalTokensOut: 5, totalCost: 1 });
    assert.equal(f.messages.length, 0);
    f.api.emit('taskTokenUsageUpdated', 'task', { totalTokensIn: 10, totalTokensOut: 4, totalCost: 0.5, contextTokens: 2 });
    assert.equal(f.messages.at(-1).tokensIn, 10);
    assert.equal(f.messages.at(-1).totalTokens, undefined);
    f.observer.dispose();
});

test('observer detaches previously attached listeners when subscription fails', () => {
    const api = new EventEmitter(), original = api.on;
    api.on = function(event, listener) { if (event === 'taskAborted') throw new Error('fixture'); return original.call(this, event, listener); };
    assert.throws(() => observeTasks(api, 'roo_code', namespace, () => {}));
    assert.equal(api.eventNames().length, 0);
});

test('source namespace matches the receiver contract exactly, including trailing newline rejection', () => {
    for (const source of ['host', namespace.toUpperCase(), namespace.slice(1), namespace + '0', namespace + '\n']) {
        const api = new EventEmitter();
        assert.throws(() => observeTasks(api, 'roo_code', source, () => {}), /Invalid source identity/);
        assert.equal(api.eventNames().length, 0);
    }
});

test('native identity rejects all C0 controls and malformed Unicode before UTF-8 encoding', () => {
    const f = fixture();
    for (let code = 0; code < 32; code++) f.api.emit('taskStarted', 'bad' + String.fromCharCode(code));
    for (const id of ['', 'x'.repeat(4097), 'bad\ud800', 'bad\udc00']) f.api.emit('taskStarted', id);
    assert.equal(f.messages.length, 0);
    const task = '任'.repeat(4096);
    f.api.emit('taskStarted', task);
    assert.equal(f.messages[0].nativeTaskId, task);
    assert(Buffer.byteLength(task, 'utf8') <= 16_384);
    f.observer.dispose();
});

test('every subscription has an independent instance even for the same profile and native task', () => {
    const a = fixture(), b = fixture();
    a.api.emit('taskStarted', 'shared-task'); b.api.emit('taskStarted', 'shared-task');
    assert.equal(a.messages[0].sourceNamespace, b.messages[0].sourceNamespace);
    assert.notEqual(a.messages[0].sourceInstanceId, b.messages[0].sourceInstanceId);
    assert.notEqual(a.messages[0].sessionId, b.messages[0].sessionId);
    a.observer.dispose(); b.observer.dispose();
});

test('heartbeats begin only after business activity and stop on disposal', context => {
    context.mock.timers.enable({ apis: ['setInterval'] });
    const f = fixture();
    context.mock.timers.tick(20_000);
    assert.equal(f.messages.length, 0);
    f.api.emit('taskStarted', 'task');
    context.mock.timers.tick(10_000);
    assert.equal(f.messages.at(-1).type, 'observation_heartbeat');
    assert.equal(f.messages.at(-1).sourceInstanceId, f.messages[0].sourceInstanceId);
    assert.equal(f.messages.at(-1).sessionId, `roo_code-${namespace}-${f.messages[0].sourceInstanceId}`);
    assert(!('nativeTaskId' in f.messages.at(-1)));
    f.api.emit('taskActive', 'task');
    context.mock.timers.tick(10_000);
    f.observer.dispose();
    assert.deepEqual(f.messages.map(m => m.observationSequence), [1, 2, 3, 4, 5]);
    assert.equal(f.messages.at(-1).type, 'observation_ended');
    context.mock.timers.tick(30_000);
    f.api.emit('taskStarted', 'late');
    assert.equal(f.messages.length, 5);
});

test('subscriptions without business activity produce no lifecycle frames', context => {
    context.mock.timers.enable({ apis: ['setInterval'] });
    const f = fixture();
    f.api.emit('taskCreated', 'history');
    context.mock.timers.tick(30_000); f.observer.dispose();
    assert.equal(f.messages.length, 0);
});

test('previews are bounded without splitting surrogate pairs or reading hidden reasoning', () => {
    const f = fixture(); f.api.emit('taskStarted', 'task');
    row(f.api, 'task', 60, { say: 'reasoning', text: 'hidden reasoning' });
    assert.equal(f.messages.length, 1);
    row(f.api, 'task', 61, { say: 'text', text: 'a'.repeat(32767) + '😀'.repeat(1000) });
    assert(f.messages.at(-1).status.length < 32800);
    assert(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(f.messages.at(-1).status));
    f.observer.dispose();
});

test('partial UTF-16 fragments become valid UTF-8 before crossing the Swift boundary', () => {
    const f = fixture(); f.api.emit('taskStarted', 'task');
    row(f.api, 'task', 90, { say: 'text', text: 'half' + String.fromCharCode(0xd800), partial: true });
    assert.equal(f.messages.at(-1).status, 'half�');
    row(f.api, 'task', 90, { say: 'text', text: 'whole😀', partial: false }, 'updated');
    assert.equal(f.messages.at(-1).status, 'whole😀');
    assert.equal(f.messages.at(-1).nativeMessageId, '90');
    f.observer.dispose();
});

test('Roo idle retains the meaning of a failed request or exhausted approval budget', () => {
    const f = fixture(); f.api.emit('taskStarted', 'task');
    row(f.api, 'task', 101, { type: 'ask', ask: 'api_req_failed', text: 'Retry?' });
    f.api.emit('taskIdle', 'task'); assert.equal(f.messages.at(-1).observedState, 'error');
    row(f.api, 'task', 102, { type: 'ask', ask: 'auto_approval_max_req_reached', text: 'Limit' });
    f.api.emit('taskIdle', 'task'); assert.equal(f.messages.at(-1).observedState, 'waitingAnswer');
    f.api.emit('taskAskResponded', 'task'); f.api.emit('taskIdle', 'task');
    assert.equal(f.messages.at(-1).observedState, 'idle');
    f.observer.dispose();
});
