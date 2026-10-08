"""Fixed loopback management proxy. Configuration remains owned by Elixir."""
import http.client
import json
from urllib.parse import urlsplit


def validate_management(url, origin):
    if not isinstance(url, str) or not isinstance(origin, str):
        raise ValueError("model management settings must be strings")
    if not url:
        return
    if any(ord(char) < 32 for char in url + origin):
        raise ValueError("model management origins contain invalid characters")
    try:
        target, public = urlsplit(url), urlsplit(origin)
        target_port, public_port = target.port, public.port
    except ValueError:
        raise ValueError("invalid model management origin") from None
    if (target.scheme != "http" or target.hostname != "127.0.0.1" or
            not target_port or target.path not in ("", "/") or target.query or
            target.fragment or target.username or target.password):
        raise ValueError("model_settings_url must be a fixed loopback HTTP origin")
    if (public.scheme not in ("http", "https") or not public.hostname or
            public.path or public.query or public.fragment or public.username or public.password):
        raise ValueError("model_settings_origin must be an explicit browser origin")


def forward(url, method, path, headers, body=None):
    target = urlsplit(url)
    connection = http.client.HTTPConnection("127.0.0.1", target.port, timeout=15)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("management response too large")
        value = json.loads(raw)
        return response.status, value
    except (OSError, ValueError, http.client.HTTPException):
        return 503, {"error": "model_settings_unavailable"}
    finally:
        connection.close()
