import { defineConfig, type Plugin } from "vite";
import solidPlugin from "vite-plugin-solid";
import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";
const UPSTREAM_HOST = process.env.DROPFU_UPSTREAM_HOST || "127.0.0.1";
const UPSTREAM_PORT = Number(process.env.DROPFU_CLIENT_PORT || 8443);

function wsProxy(): Plugin {
  return {
    name: "dropfu-ws-proxy",
    configureServer(server) {
      const wss = new WebSocketServer({ noServer: true });

      wss.on("connection", (clientWs, req) => {
        const cookie = req.headers.cookie || "";
        const upstream = new WebSocket(`ws://${UPSTREAM_HOST}:${UPSTREAM_PORT}`, {
          headers: cookie ? { Cookie: cookie } : {},
        });

        const pending: Array<{ data: WebSocket.RawData; isBinary: boolean }> = [];

        clientWs.on("message", (data, isBinary) => {
          if (upstream.readyState === WebSocket.OPEN) {
            upstream.send(data, { binary: isBinary });
          } else {
            pending.push({ data, isBinary });
          }
        });

        upstream.on("open", () => {
          for (const p of pending) upstream.send(p.data, { binary: p.isBinary });
          pending.length = 0;
        });

        upstream.on("message", (data, isBinary) => {
          if (clientWs.readyState === WebSocket.OPEN)
            clientWs.send(data, { binary: isBinary });
        });

        upstream.on("close", () => clientWs.close());
        upstream.on("error", () => clientWs.close());
        clientWs.on("close", () => upstream.close());
        clientWs.on("error", () => upstream.close());
      });

      return () => {
        const httpServer = server.httpServer!;
        type UpgradeFn = (
          req: IncomingMessage,
          socket: Socket,
          head: Buffer,
        ) => void;
        const viteListeners = httpServer
          .listeners("upgrade")
          .slice() as UpgradeFn[];
        httpServer.removeAllListeners("upgrade");

        httpServer.on("upgrade", (req, socket: Socket, head: Buffer) => {
          if (req.url === "/ws" || req.url?.startsWith("/ws?")) {
            wss.handleUpgrade(req, socket, head, (ws) => {
              wss.emit("connection", ws, req);
            });
            return;
          }
          for (const fn of viteListeners) {
            fn.call(httpServer, req, socket, head);
          }
        });
      };
    },
  };
}

export default defineConfig({
  plugins: [solidPlugin(), wsProxy()],
  server: {
    port: 3000,
    host: "127.0.0.1",
    proxy: {
      "/login": {
        target: `http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`,
        changeOrigin: true,
      },
      "/health": {
        target: `http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`,
        changeOrigin: true,
      },
      "/plugins": {
        target: `http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`,
        changeOrigin: true,
      },
    },
  },
  build: { target: "esnext" },
});
