#!/usr/bin/env node
// Stdio-to-HTTP proxy for Tenun MCP server.
// Claude Code connects via stdio; this script proxies to the HTTP endpoint.
//
// Handles both JSON and SSE response formats from the server.

import { createInterface } from "readline";

const MCP_URL = process.env.MCP_URL || "https://mcp.davewil.dev/mcp";
const MCP_TOKEN = process.env.MCP_TOKEN;

if (!MCP_TOKEN) {
  process.stderr.write("MCP_TOKEN env var required\n");
  process.exit(1);
}

let sessionId = null;
let pending = 0;
let stdinClosed = false;

function maybeExit() {
  if (stdinClosed && pending === 0) process.exit(0);
}

async function handleRequest(line) {
  pending++;
  try {
    const request = JSON.parse(line);

    // Notifications have method but no id — don't expect a response
    const isNotification = "method" in request && !("id" in request);

    const headers = {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
    };
    if (MCP_TOKEN) headers["Authorization"] = `Bearer ${MCP_TOKEN}`;
    if (sessionId) headers["Mcp-Session-Id"] = sessionId;

    const resp = await fetch(MCP_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    });

    // Capture session ID from server
    const sid = resp.headers.get("mcp-session-id");
    if (sid) sessionId = sid;

    // 202 = accepted notification, no body expected
    if (resp.status === 202 || isNotification) {
      return;
    }

    const contentType = resp.headers.get("content-type") || "";

    if (contentType.includes("application/json")) {
      // Plain JSON response — forward directly
      const body = await resp.text();
      if (body.trim()) {
        process.stdout.write(body.trim() + "\n");
      }
    } else if (contentType.includes("text/event-stream")) {
      // SSE response — extract data lines
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let gotResponse = false;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop();

        for (const l of lines) {
          if (l.startsWith("data: ") && l !== "data: finished") {
            const json = l.slice(6);
            if (json.startsWith("{")) {
              const parsed = JSON.parse(json);
              if ("id" in parsed && ("result" in parsed || "error" in parsed)) {
                process.stdout.write(json + "\n");
                gotResponse = true;
              }
              if (!("id" in parsed) && "method" in parsed && parsed.method !== "ping") {
                process.stdout.write(json + "\n");
              }
            }
          }
        }

        if (gotResponse) {
          reader.cancel().catch(() => {});
          break;
        }
      }
    } else {
      // Unknown content type — try as plain text
      const body = await resp.text();
      if (body.trim().startsWith("{")) {
        process.stdout.write(body.trim() + "\n");
      }
    }
  } catch (err) {
    process.stderr.write(`mcp-proxy error: ${err.message}\n`);
  } finally {
    pending--;
    maybeExit();
  }
}

const rl = createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => handleRequest(line));
rl.on("close", () => {
  stdinClosed = true;
  maybeExit();
});
