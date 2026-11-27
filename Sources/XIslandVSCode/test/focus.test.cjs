const { test } = require('node:test');
const assert = require('node:assert/strict');
const { normalizeTTY, parseFocusRequest, selectTerminal, ttyFromPSOutput } = require('../out/focus');

test('focus URI accepts only one exact, local terminal locator', () => {
    assert.deepEqual(parseFocusRequest('/focus', 'tty=%2Fdev%2Fttys004&cwd=%2FUsers%2Fme%2Fproject'),
        { tty: '/dev/ttys004', cwd: '/Users/me/project' });
    assert.deepEqual(parseFocusRequest('/focus/', 'pid=123'), { pid: 123 });
    assert.equal(parseFocusRequest('/other', 'tty=%2Fdev%2Fttys004'), undefined);
    assert.equal(parseFocusRequest('/focus', 'tty=ttys004'), undefined);
    assert.equal(parseFocusRequest('/focus', 'tty=%2Fdev%2Fttys004%3Becho'), undefined);
    assert.equal(parseFocusRequest('/focus', 'pid=0'), undefined);
    assert.equal(parseFocusRequest('/focus', 'pid=99999999999999999999'), undefined);
    assert.equal(parseFocusRequest('/focus', 'cwd=relative'), undefined);
    assert.equal(parseFocusRequest('/focus', ''), undefined);
});

test('tty normalization handles ps output and bare device names', () => {
    assert.equal(normalizeTTY('/dev/ttys004'), '/dev/ttys004');
    assert.equal(normalizeTTY('ttys004\n'), '/dev/ttys004');
    assert.equal(normalizeTTY('??'), undefined);
    assert.equal(ttyFromPSOutput('ttys004\n'), '/dev/ttys004');
    assert.equal(ttyFromPSOutput('??\n'), undefined);
});

test('selection prefers tty, then pid, then exact cwd and fails closed when ambiguous', () => {
    const terminals = [
        { index: 0, name: 'one', pid: 10, tty: '/dev/ttys001', cwd: '/tmp/a' },
        { index: 1, name: 'two', pid: 11, tty: '/dev/ttys002', cwd: '/tmp/b' },
        { index: 2, name: 'duplicate tty', pid: 12, tty: '/dev/ttys002', cwd: '/tmp/c' },
    ];
    assert.equal(selectTerminal(terminals, { tty: '/dev/ttys001', pid: 11 }), 0);
    assert.equal(selectTerminal(terminals, { tty: '/dev/ttys002' }), undefined);
    assert.equal(selectTerminal(terminals, { pid: 11, cwd: '/tmp/b' }), 1);
    assert.equal(selectTerminal(terminals, { cwd: '/tmp/a' }), 0);
    assert.equal(selectTerminal(terminals, { cwd: '/tmp/missing' }), undefined);
});
