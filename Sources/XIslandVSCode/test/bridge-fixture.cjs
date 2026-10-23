const fs = require('node:fs');

// 仅供队列单元测试模拟原生入口；真实 Swift 入口另由跨进程测试验证。
exports.createBridge = root => {
    const bridgePath = root + "/native bridge ' $(literal)";
    fs.writeFileSync(bridgePath, `#!${process.execPath}
const fs = require('node:fs'), net = require('node:net');
if (JSON.stringify(process.argv.slice(2)) !== '["vscode-observation"]') process.exit(64);
fs.appendFileSync(process.env.DI_SOCKET_PATH + '.spawned', '1');
const socket = net.createConnection(process.env.DI_SOCKET_PATH);
let connected = false;
socket.setTimeout(2000, () => { socket.destroy(); process.exitCode = 74; });
socket.on('error', () => { process.exitCode = connected ? 74 : 75; });
socket.on('connect', () => {
    connected = true;
    process.stdout.write('ready\\n');
    process.stdin.pipe(socket);
});
socket.on('close', () => { process.stdin.destroy(); });
`);
    fs.chmodSync(bridgePath, 0o700);
    return bridgePath;
};
