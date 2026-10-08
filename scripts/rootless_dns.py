#!/usr/bin/env python3
"""Task-local UDP resolver using a fixed, TLS-verified public DoH endpoint."""
import argparse
import http.client
import os
import socket
import ssl
import struct


def resolve(query):
    if not 12 <= len(query) <= 4096 or query[2] & 0x80:
        raise ValueError('invalid DNS query')
    connection = http.client.HTTPSConnection('1.1.1.1', timeout=5, context=ssl.create_default_context())
    try:
        connection.request('POST', '/dns-query', body=query,
                           headers={'Content-Type': 'application/dns-message', 'Accept': 'application/dns-message'})
        response = connection.getresponse()
        data = response.read(4097)
        if (response.status != 200 or response.getheader('Content-Type', '').split(';')[0] != 'application/dns-message'
                or not 12 <= len(data) <= 4096 or data[:2] != query[:2] or not data[2] & 0x80):
            raise ValueError('invalid DoH response')
        return data
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--gid', type=int, required=True)
    parser.add_argument('--host-network', required=True)
    args = parser.parse_args()
    if args.uid <= 0 or args.gid <= 0 or os.readlink('/proc/self/ns/net') == args.host_network:
        raise ValueError('dedicated worker and task network required')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as service:
        service.bind(('127.0.0.1', 53))
        os.setgroups([])
        os.setgid(args.gid)
        os.setuid(args.uid)
        print('ready', flush=True)
        while True:
            query, peer = service.recvfrom(4097)
            try:
                data = resolve(query)
            except (OSError, ValueError, http.client.HTTPException):
                if len(query) < 12:
                    continue
                # Fail closed with SERVFAIL; never use host DNS or a plaintext fallback.
                data = query[:2] + struct.pack('!5H', 0x8182, 0, 0, 0, 0)
            service.sendto(data, peer)


if __name__ == '__main__':
    main()
