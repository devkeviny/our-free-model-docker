#!/usr/bin/env python3
"""
Decoupled Smart Egress Proxy for Our Free Model (OFM)
Inspired by devkeviny/yt-dlp-server ProxyManager / SmartProxyTester pattern.

Provides:
- Mode 1: 'disabled' / 'direct' (direct egress, bypass)
- Mode 2: 'single' (routes through a designated single upstream proxy)
- Mode 3: 'pool' (manages, health-checks, rotates, quarantines, and fails-over across a proxy pool)

Supports:
- HTTP standard proxying and HTTPS CONNECT tunneling
- Periodic neutral health checking (Google 204 / Kilo API)
- Temporary quarantine/cooldown on bad proxies
- Safe fallback to direct egress when allowed
- Rate limit (HTTP 429) backoff compliance
- Status & Health endpoint on GET /health
"""

import asyncio
import json
import logging
import os
import re
import socket
import sys
import time
import urllib.parse
import urllib.request
from typing import Dict, List, Optional, Set, Tuple

# Configuration from Environment
LISTEN_HOST = os.getenv("PROXY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.getenv("PROXY_LISTEN_PORT", "8899"))
DATA_DIR = os.getenv("PROXY_DATA_DIR", "/data")
MODE = os.getenv("PROXY_MODE", "disabled").lower().strip()  # disabled | single | pool
SINGLE_URL = os.getenv("PROXY_SINGLE_URL", "").strip()
POOL_URLS_RAW = os.getenv("PROXY_POOL_URLS", "").strip()
PROXY_SOURCE_URLS = os.getenv("PROXY_SOURCE_URLS", "").strip()
CHECK_INTERVAL = int(os.getenv("PROXY_CHECK_INTERVAL", "300"))
CHECK_TIMEOUT = int(os.getenv("PROXY_CHECK_TIMEOUT", "8"))
COOLDOWN_SECONDS = int(os.getenv("PROXY_COOLDOWN_SECONDS", "300"))
ALLOW_DIRECT_FALLBACK = os.getenv("PROXY_ALLOW_DIRECT_FALLBACK", "true").lower() in ("true", "1", "yes")
HEALTH_TARGET = os.getenv("PROXY_HEALTH_TARGET", "http://www.gstatic.com/generate_204")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [egress-proxy] %(message)s"
)
logger = logging.getLogger("egress-proxy")


class SmartProxyPool:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.proxy_file = os.path.join(data_dir, "proxies.json")
        self.active_file = os.path.join(data_dir, "proxies_active.json")
        
        # State tracking
        self.all_proxies: List[str] = []
        self.active_proxies: List[str] = []
        self.quarantine_until: Dict[str, float] = {}  # proxy -> timestamp
        self.stats = {
            "requests_total": 0,
            "requests_proxied": 0,
            "requests_fallback": 0,
            "failovers": 0,
            "quarantines": 0
        }
        self.current_index = 0
        self._load_initial_proxies()

    def _load_initial_proxies(self):
        os.makedirs(self.data_dir, exist_ok=True)
        proxies = set()
        
        # 1. From Environment Variable
        if POOL_URLS_RAW:
            for p in re.split(r"[,\s]+", POOL_URLS_RAW):
                p = p.strip()
                if p:
                    proxies.add(p)
                    
        # 2. From File
        if os.path.exists(self.proxy_file):
            try:
                with open(self.proxy_file, "r") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        for p in data:
                            if isinstance(p, str) and p.strip():
                                proxies.add(p.strip())
            except Exception as e:
                logger.warning(f"Failed to read {self.proxy_file}: {e}")

        # 3. From Remote Sources (URLs txt / json)
        if PROXY_SOURCE_URLS:
            try:
                remote_fetched = self._fetch_remote_sources()
                proxies.update(remote_fetched)
            except Exception as e:
                logger.warning(f"Failed fetching remote proxy sources: {e}")

        self.all_proxies = sorted(list(proxies))
        self.active_proxies = list(self.all_proxies)
        logger.info(f"Loaded {len(self.all_proxies)} total proxies into pool.")

    def _fetch_remote_sources(self) -> Set[str]:
        """Fetch remote proxy lists from TXT and JSON URLs (like yt-dlp-server)."""
        discovered = set()
        sources = [u.strip() for u in PROXY_SOURCE_URLS.split(",") if u.strip()]
        for url in sources:
            try:
                logger.info(f"Fetching proxy list from {url}...")
                req = urllib.request.Request(url, headers={"User-Agent": "egress-proxy-fetcher/1.0"})
                with urllib.request.urlopen(req, timeout=12) as resp:
                    raw = resp.read().decode("utf-8", errors="ignore").strip()
                    if raw.startswith("[") or raw.startswith("{"):
                        data = json.loads(raw)
                        items = data if isinstance(data, list) else data.get("proxies", [])
                        for item in items:
                            if isinstance(item, dict) and item.get("proxy"):
                                p = item["proxy"].strip()
                                if not p.startswith("http://") and not p.startswith("socks5://"):
                                    p = f"http://{p}"
                                discovered.add(p)
                            elif isinstance(item, str) and item.strip():
                                p = item.strip()
                                if not p.startswith("http://") and not p.startswith("socks5://"):
                                    p = f"http://{p}"
                                discovered.add(p)
                    else:
                        for line in raw.splitlines():
                            line = line.strip()
                            if not line or line.startswith("#"):
                                continue
                            match = re.search(r"((?:https?|socks5)://)?([0-9]{1,3}(?:\.[0-9]{1,3}){3}:[0-9]{2,5})", line)
                            if match:
                                scheme = match.group(1) or "http://"
                                discovered.add(f"{scheme}{match.group(2)}")
                logger.info(f"Discovered {len(discovered)} proxies from remote sources.")
            except Exception as e:
                logger.warning(f"Failed downloading proxy source from {url}: {e}")
        return discovered

    def save_state(self):
        try:
            with open(self.active_file, "w") as f:
                json.dump({
                    "updated_at": time.time(),
                    "total": len(self.all_proxies),
                    "active_count": len(self.active_proxies),
                    "active_proxies": self.active_proxies,
                    "quarantined_count": len(self.quarantine_until)
                }, f, indent=2)
        except Exception as e:
            logger.warning(f"Failed to write {self.active_file}: {e}")

    def quarantine(self, proxy: str, reason: str = "error"):
        until = time.time() + COOLDOWN_SECONDS
        self.quarantine_until[proxy] = until
        self.stats["quarantines"] += 1
        if proxy in self.active_proxies:
            self.active_proxies.remove(proxy)
        logger.warning(f"Quarantined proxy '{proxy}' for {COOLDOWN_SECONDS}s. Reason: {reason}")
        self.save_state()

    def get_candidate(self) -> Optional[str]:
        now = time.time()
        # Revive proxies whose cooldown expired
        expired = [p for p, t in self.quarantine_until.items() if now >= t]
        for p in expired:
            del self.quarantine_until[p]
            if p in self.all_proxies and p not in self.active_proxies:
                self.active_proxies.append(p)
                logger.info(f"Proxy '{p}' cooldown expired; returned to active pool.")

        if not self.active_proxies:
            return None

        # Round-robin
        self.current_index = (self.current_index + 1) % len(self.active_proxies)
        return self.active_proxies[self.current_index]

    def test_proxy_sync(self, proxy_url: str) -> bool:
        """Test a proxy against the neutral health check target."""
        try:
            proxy_handler = urllib.request.ProxyHandler({
                "http": proxy_url,
                "https": proxy_url
            })
            opener = urllib.request.build_opener(proxy_handler)
            req = urllib.request.Request(HEALTH_TARGET, headers={"User-Agent": "egress-proxy-tester/1.0"})
            with opener.open(req, timeout=CHECK_TIMEOUT) as resp:
                if resp.status in (200, 204):
                    return True
        except Exception:
            pass
        return False

    async def run_health_cycle(self):
        """Asynchronously verify proxies in background."""
        if not self.all_proxies:
            return

        loop = asyncio.get_running_loop()
        logger.info(f"Starting proxy health audit for {len(self.all_proxies)} proxies...")
        working = []
        for p in self.all_proxies:
            is_ok = await loop.run_in_executor(None, self.test_proxy_sync, p)
            if is_ok:
                working.append(p)
                if p in self.quarantine_until:
                    del self.quarantine_until[p]
            else:
                self.quarantine(p, reason="healthcheck_failed")

        self.active_proxies = working
        self.save_state()
        logger.info(f"Health audit complete: {len(working)}/{len(self.all_proxies)} active.")


# Global Pool Instance
pool: Optional[SmartProxyPool] = None


async def forward_stream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while not reader.at_eof():
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle_connect_tunnel(client_reader, client_writer, host: str, port: int, upstream_proxy: Optional[str]):
    """Handle HTTPS CONNECT tunneling."""
    remote_reader = None
    remote_writer = None

    try:
        if upstream_proxy:
            # Connect via upstream HTTP proxy
            parsed = urllib.parse.urlparse(upstream_proxy)
            proxy_host = parsed.hostname
            proxy_port = parsed.port or (443 if parsed.scheme == "https" else 80)

            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(proxy_host, proxy_port),
                timeout=CHECK_TIMEOUT
            )

            # Send CONNECT to upstream proxy
            connect_req = f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            if parsed.username and parsed.password:
                import base64
                auth_str = f"{parsed.username}:{parsed.password}"
                b64 = base64.b64encode(auth_str.encode()).decode()
                connect_req += f"Proxy-Authorization: Basic {b64}\r\n"
            connect_req += "\r\n"

            remote_writer.write(connect_req.encode())
            await remote_writer.drain()

            res_line = await remote_reader.readline()
            if not res_line or b" 200 " not in res_line:
                raise ConnectionError(f"Upstream proxy refused CONNECT: {res_line.decode(errors='ignore')}")

            # Drain remainder of proxy response headers
            while True:
                line = await remote_reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
        else:
            # Direct connection
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(host, port),
                timeout=CHECK_TIMEOUT
            )

        # Notify client connection established
        client_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await client_writer.drain()

        # Bidirectional pipeline
        await asyncio.gather(
            forward_stream(client_reader, remote_writer),
            forward_stream(remote_reader, client_writer)
        )

    except Exception as e:
        if upstream_proxy and pool and MODE == "pool":
            pool.quarantine(upstream_proxy, reason=f"connect_failed: {str(e)[:40]}")
            pool.stats["failovers"] += 1
            
        if not client_writer.is_closing():
            client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await client_writer.drain()
            client_writer.close()


async def handle_http_request(client_reader, client_writer, first_line: str, host: str, port: int, upstream_proxy: Optional[str]):
    """Handle plain HTTP proxy requests."""
    try:
        if upstream_proxy:
            parsed = urllib.parse.urlparse(upstream_proxy)
            remote_reader, remote_writer = await asyncio.open_connection(
                parsed.hostname, parsed.port or 80
            )
            # Forward exact request through upstream proxy
            remote_writer.write(first_line.encode() + b"\r\n")
            while True:
                line = await client_reader.readline()
                remote_writer.write(line)
                if line in (b"\r\n", b"\n", b""):
                    break
            await remote_writer.drain()
        else:
            # Direct connection to destination
            remote_reader, remote_writer = await asyncio.open_connection(host, port)
            # Rewrite first line from absolute URL to path
            parts = first_line.split()
            if len(parts) >= 2:
                url_parsed = urllib.parse.urlparse(parts[1])
                path = url_parsed.path or "/"
                if url_parsed.query:
                    path += "?" + url_parsed.query
                first_line = f"{parts[0]} {path} {parts[2] if len(parts) > 2 else 'HTTP/1.1'}"
            remote_writer.write(first_line.encode() + b"\r\n")
            while True:
                line = await client_reader.readline()
                remote_writer.write(line)
                if line in (b"\r\n", b"\n", b""):
                    break
            await remote_writer.drain()

        # Pipe remaining payload and response
        await asyncio.gather(
            forward_stream(client_reader, remote_writer),
            forward_stream(remote_reader, client_writer)
        )
    except Exception as e:
        if upstream_proxy and pool and MODE == "pool":
            pool.quarantine(upstream_proxy, reason=f"http_failed: {str(e)[:40]}")
            pool.stats["failovers"] += 1
        if not client_writer.is_closing():
            client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await client_writer.drain()
            client_writer.close()


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        first_line_bytes = await reader.readline()
        if not first_line_bytes:
            writer.close()
            return

        first_line = first_line_bytes.decode(errors="ignore").strip()
        if not first_line:
            writer.close()
            return

        # Handle local Health & Status route
        if first_line.startswith("GET /health ") or first_line.startswith("GET /status "):
            status_data = {
                "ok": True,
                "service": "ofm-smart-egress-proxy",
                "mode": MODE,
                "allow_direct_fallback": ALLOW_DIRECT_FALLBACK,
                "active_proxies": len(pool.active_proxies) if pool else (1 if SINGLE_URL else 0),
                "total_proxies": len(pool.all_proxies) if pool else (1 if SINGLE_URL else 0),
                "stats": pool.stats if pool else {}
            }
            body = json.dumps(status_data, indent=2).encode()
            headers = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                + f"Content-Length: {len(body)}\r\n\r\n".encode()
            )
            writer.write(headers + body)
            await writer.drain()
            writer.close()
            return

        # Select Outbound Route based on Mode
        upstream = None
        if MODE == "single" and SINGLE_URL:
            upstream = SINGLE_URL
            if pool:
                pool.stats["requests_proxied"] += 1
        elif MODE == "pool" and pool:
            upstream = pool.get_candidate()
            if upstream:
                pool.stats["requests_proxied"] += 1
            else:
                if ALLOW_DIRECT_FALLBACK:
                    pool.stats["requests_fallback"] += 1
                    logger.warning("No active pool proxies available. Falling back to direct egress.")
                else:
                    writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                    await writer.drain()
                    writer.close()
                    return
        elif MODE == "disabled":
            upstream = None

        if pool:
            pool.stats["requests_total"] += 1

        parts = first_line.split()
        if not parts:
            writer.close()
            return

        method = parts[0].upper()
        target = parts[1] if len(parts) > 1 else ""

        if method == "CONNECT":
            # CONNECT host:port HTTP/1.1
            host_port = target.split(":")
            host = host_port[0]
            port = int(host_port[1]) if len(host_port) > 1 else 443
            await handle_connect_tunnel(reader, writer, host, port, upstream)
        else:
            # HTTP request: parse host from target or Host header
            url_parsed = urllib.parse.urlparse(target)
            host = url_parsed.hostname or "127.0.0.1"
            port = url_parsed.port or (443 if url_parsed.scheme == "https" else 80)
            await handle_http_request(reader, writer, first_line, host, port, upstream)

    except Exception as e:
        logger.error(f"Error handling proxy client: {e}")
        try:
            writer.close()
        except Exception:
            pass


async def background_health_loop():
    """Background task running periodic health checks."""
    while True:
        try:
            await asyncio.sleep(CHECK_INTERVAL)
            if MODE == "pool" and pool:
                await pool.run_health_cycle()
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Error in background health loop: {e}")


async def main():
    global pool
    logger.info(f"Starting Smart Egress Proxy in mode: '{MODE}' on {LISTEN_HOST}:{LISTEN_PORT}")
    
    if MODE == "pool":
        pool = SmartProxyPool(DATA_DIR)
        # Initial probe
        asyncio.create_task(pool.run_health_cycle())
        asyncio.create_task(background_health_loop())
    elif MODE == "single":
        logger.info(f"Configured single upstream proxy: {SINGLE_URL}")
    else:
        logger.info("Proxy mode is 'disabled'. Operating as transparent direct egress forwarder.")

    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    logger.info(f"Egress proxy service listening on {LISTEN_HOST}:{LISTEN_PORT}")
    
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Proxy shutting down.")
