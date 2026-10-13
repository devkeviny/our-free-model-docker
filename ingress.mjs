/**
 * Ingress Reverse Proxy for Our Free Model Standalone
 *
 * Listens on 0.0.0.0:${PORT:-18900} and forwards traffic to the internal
 * loopback listener on 127.0.0.1:${INTERNAL_PORT:-18901}.
 * Rewrites the `Host` header to `127.0.0.1:${INTERNAL_PORT}` so that Our Free Model's
 * internal loopback trust fence accepts incoming requests from Docker bridge/Coolify.
 */
import http from 'node:http';

const EXTERNAL_PORT = Number(process.env.PORT) || 18900;
const INTERNAL_PORT = Number(process.env.INTERNAL_PORT) || 18901;
const INTERNAL_HOST = '127.0.0.1';

const server = http.createServer((req, res) => {
  const targetHost = `${INTERNAL_HOST}:${INTERNAL_PORT}`;
  
  // Clone and sanitize incoming headers
  const headers = { ...req.headers };
  headers.host = targetHost;
  
  // Forward original host and proto for logging and diagnostics if needed
  if (!headers['x-forwarded-for']) {
    headers['x-forwarded-for'] = req.socket.remoteAddress;
  }
  if (!headers['x-forwarded-proto']) {
    headers['x-forwarded-proto'] = 'http';
  }

  const options = {
    hostname: INTERNAL_HOST,
    port: INTERNAL_PORT,
    path: req.url,
    method: req.method,
    headers: headers,
  };

  const proxyReq = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        error: {
          message: `Ingress proxy error connecting to Our Free Model standalone: ${err.message}`,
          type: 'bad_gateway',
          code: 'upstream_unavailable'
        }
      }));
    } else {
      res.destroy();
    }
  });

  req.pipe(proxyReq);
});

// Handle upgrade requests (WebSockets if any)
server.on('upgrade', (req, socket, head) => {
  const options = {
    hostname: INTERNAL_HOST,
    port: INTERNAL_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `${INTERNAL_HOST}:${INTERNAL_PORT}` },
  };

  const proxyReq = http.request(options);
  proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
    socket.write(`HTTP/${proxyRes.httpVersion} ${proxyRes.statusCode} ${proxyRes.statusMessage}\r\n`);
    for (const [key, value] of Object.entries(proxyRes.headers)) {
      socket.write(`${key}: ${value}\r\n`);
    }
    socket.write('\r\n');
    proxySocket.pipe(socket);
    socket.pipe(proxySocket);
  });
  proxyReq.on('error', () => {
    socket.destroy();
  });
  proxyReq.end();
});

server.listen(EXTERNAL_PORT, '0.0.0.0', () => {
  console.log(`[ingress] Listening on 0.0.0.0:${EXTERNAL_PORT} -> forwarding to ${INTERNAL_HOST}:${INTERNAL_PORT}`);
});

const shutdown = () => {
  console.log('[ingress] Shutting down ingress listener...');
  server.close(() => process.exit(0));
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
