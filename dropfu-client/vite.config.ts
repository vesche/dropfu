import { defineConfig, type Plugin } from "vite";
import solidPlugin from "vite-plugin-solid";
import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "node:http";
import type { Socket } from "node:net";

function wsProxy(): Plugin {
  return {
    name: "dropfu-ws-proxy",
    configureServer(server) {
      const wss = new WebSocketServer({ noServer: true });

      wss.on("connection", (clientWs) => {
        const upstream = new WebSocket("ws://127.0.0.1:8443");

        upstream.on("open", () => {
          clientWs.on("message", (data, isBinary) => {
            if (upstream.readyState === WebSocket.OPEN)
              upstream.send(data, { binary: isBinary });
          });
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
          if (req.url === "/ws") {
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
  server: { port: 3000 },
  build: { target: "esnext" },
});
