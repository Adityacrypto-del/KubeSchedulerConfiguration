"""Minimal Kubernetes REST client for the KubeSchedulerConfiguration benchmark.

Standard library only (no PyYAML, no kubernetes package). The kubeconfig is
read through `kubectl config view --raw --minify -o json`, so any kubeconfig
kubectl understands works. Each thread gets its own keep-alive connection.
"""

import base64
import http.client
import json
import os
import ssl
import subprocess
import tempfile
import threading
import urllib.parse


class Client:
    def __init__(self, kubeconfig):
        raw = subprocess.check_output(
            ["kubectl", "--kubeconfig", kubeconfig, "config", "view", "--raw", "--minify", "-o", "json"])
        cfg = json.loads(raw)
        cluster = cfg["clusters"][0]["cluster"]
        user = cfg["users"][0]["user"]
        url = urllib.parse.urlparse(cluster["server"])
        self.host, self.port = url.hostname, url.port or 443
        self._tmp = tempfile.mkdtemp(prefix="kube-bench-")
        ctx = ssl.create_default_context(cafile=self._file(cluster, "certificate-authority"))
        cert = self._file(user, "client-certificate")
        if cert:
            ctx.load_cert_chain(cert, self._file(user, "client-key"))
        self.ctx = ctx
        self.token = user.get("token")
        self._local = threading.local()

    def _file(self, section, key):
        """Return a path for `key`, writing `key-data` to a temp file if needed."""
        if section.get(key):
            return section[key]
        data = section.get(key + "-data")
        if not data:
            return None
        path = os.path.join(self._tmp, key)
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        return path

    def _conn(self, fresh=False):
        conn = getattr(self._local, "conn", None)
        if conn is None or fresh:
            conn = http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=60)
            self._local.conn = conn
        return conn

    def _headers(self):
        h = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        return h

    def request(self, method, path, body=None):
        """Send one request and return (status, parsed JSON body)."""
        payload = json.dumps(body).encode() if body is not None else None
        for attempt in (1, 2):
            conn = self._conn(fresh=attempt == 2)
            try:
                conn.request(method, path, body=payload, headers=self._headers())
                resp = conn.getresponse()
                data = resp.read()
                return resp.status, (json.loads(data) if data else None)
            except (http.client.HTTPException, OSError):
                if attempt == 2:
                    raise

    def create(self, path, obj):
        status, body = self.request("POST", path, obj)
        if status not in (200, 201):
            raise RuntimeError(f"POST {path} failed: {status} {body}")
        return body

    def list(self, path):
        """List all items, following continue tokens."""
        items, cont = [], ""
        while True:
            sep = "&" if "?" in path else "?"
            q = f"{path}{sep}limit=500" + (f"&continue={urllib.parse.quote(cont)}" if cont else "")
            status, body = self.request("GET", q)
            if status != 200:
                raise RuntimeError(f"GET {q} failed: {status} {body}")
            items += body["items"]
            cont = body["metadata"].get("continue")
            if not cont:
                return items, body["metadata"]["resourceVersion"]

    def watch(self, path, resource_version):
        """Yield (type, object) watch events. Uses its own connection."""
        conn = http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=None)
        sep = "&" if "?" in path else "?"
        conn.request("GET", f"{path}{sep}watch=1&allowWatchBookmarks=true&resourceVersion={resource_version}",
                     headers=self._headers())
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"watch {path} failed: {resp.status} {resp.read()[:300]}")
        try:
            while True:
                line = resp.readline()
                if not line:
                    return
                ev = json.loads(line)
                yield ev["type"], ev["object"]
        finally:
            conn.close()
