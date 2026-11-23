#!/usr/bin/env python3
"""Minimal kanban tool-call proxy client — same wire format as KanbanProxy.forward.
Usage: kb.py '<json-args-object>'"""
import json, sys, os, urllib.request

def main():
    args = json.loads(sys.argv[1])
    env = {k: v for k, v in os.environ.items() if k.startswith('ARC_')}
    token = None
    for line in open(os.path.expanduser('~/.arc/.env')):
        line = line.strip()
        if line.startswith('ARC_KANBAN_PROXY_TOKEN='):
            token = line.split('=', 1)[1]
    req = urllib.request.Request(
        'http://127.0.0.1:8080/v1/kanban',
        data=json.dumps({'args': args, 'env': env}).encode(),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
        method='POST')
    with urllib.request.urlopen(req, timeout=20) as r:
        print(json.loads(r.read())['output'])

if __name__ == '__main__':
    main()
