#!/usr/bin/env python3
"""Persistent MCP client for an installed tool schema that has not refreshed.

One JSON request per stdin line: {"command":"observe","app":"...",...}.
Default stdout contains metadata only. --include-images forwards real MCP image
blocks in ``images`` for an authorized wrapper to emit to the current model.
No shell interpolation, new model service, or action replay.
"""
import argparse
import json
from pathlib import Path
import selectors
import subprocess
import sys
import time
import os

MAX_RESPONSE_BYTES = 8 * 1024 * 1024


def client_payload(result, *, include_images=False):
    content = result.get('content', [])
    text_blocks = [c['text'] for c in content if c.get('type') == 'text']
    if len(text_blocks) == 1:
        try:
            payload = json.loads(text_blocks[0])
            if not isinstance(payload, dict):
                raise ValueError('MCP text envelope must be an object')
        except ValueError:
            payload = {'ok': False, 'error': {'code': 'mcp_error', 'message': text_blocks[0]}, 'automatic_replay_allowed': False}
    else:
        payload = {'ok': not result.get('isError', False), 'content': [c for c in content if c.get('type') != 'image']}
    images = [c for c in content if c.get('type') == 'image']
    if images:
        payload['image_blocks_received'] = len(images)
        payload['image_blocks_forwarded'] = include_images
        if include_images:
            payload['images'] = images
        else:
            payload['image_delivery'] = 'metadata_only; use --include-images to forward MCP image blocks to the current model'
    if result.get('isError'):
        payload['mcp_is_error'] = True
    return payload


class MCPClient:
    def __init__(self, config):
        root = str(Path(__file__).resolve().parents[1])
        command = config['command'].replace('${PLUGIN_ROOT}', root)
        arguments = [argument.replace('${PLUGIN_ROOT}', root) for argument in config['args']]
        cwd = config.get('cwd')
        cwd = cwd.replace('${PLUGIN_ROOT}', root) if isinstance(cwd, str) else None
        self.process = subprocess.Popen([command, *arguments], cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=sys.stderr, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer, self.sequence = b'', 0

    def request(self, method, params, timeout=180):
        self.sequence += 1
        packet = {'jsonrpc': '2.0', 'id': self.sequence, 'method': method, 'params': params}
        self.process.stdin.write((json.dumps(packet, ensure_ascii=False) + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                response = json.loads(line)
                if response.get('id') != self.sequence:
                    raise RuntimeError('MCP response ID mismatch; no replay')
                if 'error' in response:
                    raise RuntimeError(response['error'])
                return response['result']
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise RuntimeError('MCP timeout; completion unknown; inspect before retrying a mutation')
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise RuntimeError('MCP EOF; completion unknown; no replay')
            self.buffer += block
            if len(self.buffer) > MAX_RESPONSE_BYTES:
                raise RuntimeError('MCP response exceeds 8 MiB')

    def close(self):
        self.selector.close()
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-images', action='store_true', help='Forward native MCP image blocks in stdout images for an authorized model wrapper, not a text log.')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / '.mcp.json').read_text())['mcpServers']['intel_desktop']
    client = MCPClient(config)
    try:
        client.request('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                     'clientInfo': {'name': 'intel-desktop-client', 'version': '2'}})
        for line in sys.stdin:
            if len(line.encode('utf-8')) > 1024 * 1024:
                print(json.dumps({'ok': False, 'error': 'Request exceeds 1 MiB'}), flush=True)
                continue
            try:
                arguments = json.loads(line)
                if not isinstance(arguments, dict):
                    raise ValueError('One request object per line is required')
                command = arguments.pop('command')
                if not isinstance(command, str) or not command:
                    raise ValueError('command required')
                if command == '__exit__':
                    print(json.dumps({'ok': True, 'session_closed': True}), flush=True)
                    break
                result = client.request('tools/call', {'name': 'desktop_' + command, 'arguments': arguments})
                print(json.dumps(client_payload(result, include_images=options.include_images), ensure_ascii=False), flush=True)
            except (KeyError, ValueError) as error:
                print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False), flush=True)
            except Exception as error:
                print(json.dumps({'ok': False, 'completion_unknown': True,
                                  'automatic_replay_allowed': False, 'error': str(error)}, ensure_ascii=False), flush=True)
                break
    finally:
        client.close()


if __name__ == '__main__':
    main()
