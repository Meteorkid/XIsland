#!/usr/bin/env python3
"""交叉验证 companion 与当前 Swift 首帧读取函数；不启动 XIsland 或厂商客户端。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time


def verify(repository: Path) -> dict:
    extension = repository / 'Sources/XIslandVSCode'
    receiver = repository / 'Sources/DynamicIsland/Managers/SocketServer.swift'
    protocol = repository / 'Sources/DIShared/Protocol.swift'
    source = receiver.read_text()
    reader = re.search(r'    static func readMessage\(from fd: Int32\) -> Data\? \{.*?\n    \}', source, re.S)
    limit = re.search(r'    static let maxMessageBytes = [^\n]+', source)
    assert reader and limit, 'SocketServer 读取函数结构已变，请更新交叉验证入口'
    with tempfile.TemporaryDirectory(prefix='xi-vsc-swift-', dir='/tmp') as folder:
        root = Path(folder)
        main = root / 'main.swift'
        main.write_text('import Foundation\nimport Darwin\nenum SocketServer {\n' + limit[0] + '\n' + reader[0] + '\n}\n' + r'''
let path = CommandLine.arguments[1]
let expected = Int(CommandLine.arguments[2])!
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fatalError("socket failed") }
defer { close(fd); unlink(path) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let bytes = path.utf8CString
precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
withUnsafeMutablePointer(to: &address.sun_path) { destination in
    bytes.withUnsafeBufferPointer { UnsafeMutableRawPointer(destination).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
}
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0, listen(fd, 128) == 0 else { fatalError("listen failed") }
FileManager.default.createFile(atPath: path + ".ready", contents: Data())
for _ in 0..<expected {
    let client = accept(fd, nil, nil)
    guard client >= 0 else { fatalError("accept failed") }
    guard let data = SocketServer.readMessage(from: client) else { fatalError("readMessage failed") }
    _ = try DIProtocol.decode(data)
    FileHandle.standardOutput.write(data)
    close(client)
}
FileManager.default.createFile(atPath: path + ".done", contents: Data())
''')
        subprocess.run(['node', str(extension / 'node_modules/typescript/bin/tsc'), '-p', str(extension),
                        '--outDir', str(root / 'js')], check=True, timeout=30)
        subprocess.run(['swiftc', str(protocol), str(main), '-o', str(root / 'receiver')], check=True, timeout=60)
        base = {'type': 'status_update', 'sessionId': 'transport-fixture', 'agentType': 'roo_code',
                'timestamp': '2026-09-24T00:00:00Z'}
        messages = [{**base, 'type': 'session_start'},
                    {**base, 'nativeMessageId': 'stream-1', 'status': 'partial'},
                    {**base, 'nativeMessageId': 'stream-1', 'status': 'final'},
                    {**base, 'status': '大' * 80000}]
        messages.extend({**base, 'agentType': 'pearai', 'sessionId': f'pear-{i}', 'status': f'event-{i}'} for i in range(64))
        messages.append({**base, 'type': 'session_end'})
        expected = messages[:1] + messages[2:]
        (root / 'messages.json').write_text(json.dumps(messages, ensure_ascii=False))
        sender = root / 'sender.cjs'
        sender.write_text(r'''
const fs = require('node:fs');
const { ObservationTransport } = require('./js/transport');
const socketPath = process.argv[2], deadline = Date.now() + 5000;
const transport = new ObservationTransport(socketPath, () => {}, 20);
for (const message of JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))) transport.send(message);
const timer = setInterval(() => {
    const complete = fs.existsSync(socketPath + '.done');
    if (!complete && Date.now() < deadline) return;
    clearInterval(timer); transport.dispose();
    if (!complete) { console.error('Swift receiver did not receive every queued event'); process.exitCode = 1; }
}, 10);
''')
        socket_path = str(root / 'di.sock')
        # 输出落在临时文件，避免大帧填满 stdout 管道后阻止接收器关闭连接。
        with (root / 'received.jsonl').open('wb') as output, (root / 'receiver.stderr').open('wb') as errors:
            process = subprocess.Popen([str(root / 'receiver'), socket_path, str(len(expected))], stdout=output, stderr=errors)
            try:
                deadline = time.monotonic() + 5
                while not Path(socket_path + '.ready').exists():
                    assert process.poll() is None and time.monotonic() < deadline, 'Swift receiver did not start'
                    time.sleep(.01)
                subprocess.run(['node', str(sender), socket_path, str(root / 'messages.json')], check=True, timeout=8)
                assert process.wait(timeout=5) == 0, 'Swift receiver failed'
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        received = [json.loads(line) for line in (root / 'received.jsonl').read_text().splitlines()]
        assert received == expected, '消息数量、内容或接收顺序不一致'
        assert not (root / 'receiver.stderr').read_bytes(), 'Swift receiver emitted errors'
    return {'scenarios': ['one-frame-per-connection', 'queued-stream-coalescing', 'roo-and-pear-burst-order',
                          'large-utf8-frame-through-production-reader-and-decoder'],
            'sentEvents': len(messages), 'receivedEvents': len(received),
            'receiverScope': 'Current SocketServer.readMessage and DIProtocol.decode; isolated accept/close harness',
            'sourceSha256': {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in [receiver, protocol, extension / 'src/transport.ts', Path(__file__).resolve()]},
            'realClientVerified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path)
    arguments = parser.parse_args()
    result = verify(Path(__file__).resolve().parent.parent)
    encoded = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.report:
        arguments.report.write_text(encoded + '\n')
    print(encoded)
