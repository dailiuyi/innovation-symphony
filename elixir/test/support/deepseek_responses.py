"""Offline TLS Responses fixture: actual Codex tool round trip, never a provider account."""
import http.server
import json
import os
import threading
from pathlib import Path
import ssl
import sys

root = Path(sys.argv[1])
# Port.close closes stdin; end the fixture so it cannot keep check pipes alive.
def parent_closed():
    sys.stdin.buffer.read()
    os._exit(0)
threading.Thread(target=parent_closed, daemon=True).start()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (root/'requests.jsonl').open('a') as stream:
            stream.write(json.dumps({'path': self.path, 'body': body, 'auth': self.headers.get('Authorization')})+'\n')
        tool_results = [item for item in body.get('input', []) if item.get('type') == 'function_call_output']
        completed_tool = bool(tool_results)
        if completed_tool and not any('offline-tool-token' in item.get('output', '') for item in tool_results):
            self.send_error(500, 'The tool did not read the fixture token')
            return
        if completed_tool:
            output = [{'id':'msg_fixture', 'type':'message', 'role':'assistant', 'status':'completed',
                       'content':[{'type':'output_text', 'text':'{"token":"offline-tool-token"}', 'annotations':[]}]}]
        else:
            tools = body.get('tools', [])
            names = [t.get('name') for t in tools if t.get('type') == 'function']
            name = 'exec_command' if 'exec_command' in names else 'shell'
            arguments = {'cmd':'cat model-probe.txt'} if name == 'exec_command' else {'command':['/bin/sh','-c','cat model-probe.txt']}
            output = [{'id':'fc_fixture', 'type':'function_call', 'call_id':'call_fixture', 'name':name, 'arguments':json.dumps(arguments), 'status':'completed'}]
        response = {'id':'resp_fixture', 'object':'response', 'status':'completed', 'model':body['model'], 'output':output,
                    'usage':{'input_tokens':10,'output_tokens':5,'total_tokens':15}}
        events = [{'type':'response.created', 'response':{**response, 'status':'in_progress','output':[]}}]
        for i, item in enumerate(output):
            events += [{'type':'response.output_item.added','output_index':i,'item':item}]
            if item['type'] == 'message':
                events += [{'type':'response.content_part.added','item_id':item['id'],'output_index':i,'content_index':0,'part':{'type':'output_text','text':'','annotations':[]}},
                           {'type':'response.output_text.delta','item_id':item['id'],'output_index':i,'content_index':0,'delta':item['content'][0]['text']}]
            events += [{'type':'response.output_item.done','output_index':i,'item':item}]
        events += [{'type':'response.completed', 'response':response}]
        raw = ''.join('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n' for event in events).encode()
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(root/'cert.pem',root/'key.pem')
server.socket = context.wrap_socket(server.socket,server_side=True)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
