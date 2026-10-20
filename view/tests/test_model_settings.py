import http.client
import json
import socket
import os
import sys
import threading
import unittest
from unittest.mock import patch
APP = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'app'))
if APP not in sys.path:
    sys.path.insert(0, APP)
from symphony_board.api import serve, RawRef
from symphony_board.config import BoardConfig, _from_dicts
from symphony_board.state import BoardState
from symphony_board.model_settings import forward, validate_management

class ModelSettingsTests(unittest.TestCase):
    def test_configuration_limits_and_private_listener(self):
        validate_management('', '')
        validate_management('http://127.0.0.1:8765', 'https://view.internal')
        for url in ['http://evil:1', 'https://127.0.0.1:1', 'http://127.0.0.1:1/path', 'http://a:b@127.0.0.1:1', 'http://127.0.0.1:1?q=x']:
            with self.assertRaises(ValueError): validate_management(url, 'https://view.internal')
        with self.assertRaises(ValueError): validate_management('http://127.0.0.1:1', '')
        for url, origin in [(None, ''), ([], ''), ('http://127.0.0.1:bad', 'https://view.internal'),
                            ('http://127.0.0.1:1', None), ('http://127.0.0.1:1', 'https://view.internal:70000'),
                            ('http://127.0.0.1:1\n', 'https://view.internal')]:
            with self.assertRaises(ValueError): validate_management(url, origin)
        cfg = _from_dicts({'board': {'model_settings_url': 'http://127.0.0.1:8765', 'model_settings_origin': 'http://view.internal'}}, '', True)
        server = serve(BoardState(), cfg, RawRef(), port=0)
        self.assertEqual(server.server_address[0], '127.0.0.1')
        server.server_close()

    def test_proxy_scope_auth_origin_input_and_failure_are_bounded(self):
        cfg = BoardConfig(model_settings_url='http://127.0.0.1:8765', model_settings_origin='http://view.internal')
        server = serve(BoardState(), cfg, RawRef(), port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def request(method, path, body=None, **extra):
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            headers = {'Host': 'view.internal', **extra}
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse(); raw = response.read(); connection.close()
            return response.status, json.loads(raw)
        try:
            with patch('symphony_board.model_settings.forward', return_value=(200, {'revision': 1})) as proxy:
                path = '/api/model-settings/repositories/repo'
                self.assertEqual(request('GET', path)[0], 401)
                self.assertEqual(request('GET', path, Authorization='Bearer x', Host='evil')[0], 403)
                self.assertEqual(request('GET', path, Authorization='Bearer x', **{'Sec-Fetch-Site': 'cross-site'})[0], 403)
                self.assertEqual(request('GET', path+'?url=evil', Authorization='Bearer x')[0], 404)
                self.assertEqual(request('GET', '/api/model-settings/repositories/../secret', Authorization='Bearer x')[0], 404)
                self.assertEqual(request('POST', path, '{}', Authorization='Bearer x', Origin='http://evil', **{'Content-Type':'application/json'})[0], 403)
                self.assertEqual(request('POST', path, 'x'*20000, Authorization='Bearer x', Origin=cfg.model_settings_origin, **{'Content-Type':'application/json'})[0], 400)
                proxy.assert_not_called()
                self.assertEqual(request('POST', path, '{}', Authorization='Bearer x', Origin=cfg.model_settings_origin, **{'Content-Type':'application/json'})[0], 200)
                args = proxy.call_args.args
                self.assertEqual(args[2], '/repositories/repo')
                self.assertEqual(args[3]['Origin'], cfg.model_settings_origin)
                self.assertEqual(args[4], b'{}')
            # Own a non-listening endpoint instead of contacting a live backend.
            with socket.socket() as unavailable:
                unavailable.bind(('127.0.0.1', 0))
                cfg.model_settings_url = f'http://127.0.0.1:{unavailable.getsockname()[1]}'
                self.assertEqual(request('GET', path, Authorization='Bearer x')[0], 503)
            self.assertEqual(request('POST', '/api/start-task', '{}')[0], 404)
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_transport_returns_generic_errors_without_secrets(self):
        for error in [OSError('secret'), ValueError('secret')]:
            with patch('http.client.HTTPConnection.request', side_effect=error):
                self.assertEqual(forward('http://127.0.0.1:1', 'GET', '/repositories', {}), (503, {'error':'model_settings_unavailable'}))
