import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as net from "node:net";

const GODOT_HOST = "127.0.0.1";
const GODOT_PORT = 6800;
const CONNECT_TIMEOUT_MS = 3000;
const REQUEST_TIMEOUT_MS = 8000;

// ---- Godot TCP client -----------------------------------------------------

let godotSocket = null;
let pendingResolve = null;
let recvBuf = "";

function connectGodot() {
  return new Promise((resolve, reject) => {
    if (godotSocket && !godotSocket.destroyed) {
      resolve(godotSocket);
      return;
    }
    const sock = net.createConnection({ host: GODOT_HOST, port: GODOT_PORT });
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`Godot TCP connect timeout (${GODOT_HOST}:${GODOT_PORT})`));
    }, CONNECT_TIMEOUT_MS);

    sock.once("connect", () => {
      clearTimeout(timer);
      godotSocket = sock;
      recvBuf = "";
      resolve(sock);
    });
    sock.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.on("close", () => {
      godotSocket = null;
    });
    sock.on("data", (chunk) => {
      recvBuf += chunk.toString("utf-8");
      drainRecvBuf();
    });
  });
}

function drainRecvBuf() {
  while (true) {
    const nl = recvBuf.indexOf("\n");
    if (nl < 0) break;
    const line = recvBuf.slice(0, nl).trim();
    recvBuf = recvBuf.slice(nl + 1);
    if (!line) continue;
    try {
      const msg = JSON.parse(line);
      if (pendingResolve) {
        const r = pendingResolve;
        pendingResolve = null;
        r(msg);
      }
    } catch { /* ignore malformed */ }
  }
}

function sendRequest(method, params = {}) {
  return new Promise(async (resolve, reject) => {
    try {
      const sock = await connectGodot();
      const id = Date.now();
      const req = JSON.stringify({ id, method, params }) + "\n";
      pendingResolve = resolve;
      const timer = setTimeout(() => {
        pendingResolve = null;
        reject(new Error(`Godot request timeout: ${method}`));
      }, REQUEST_TIMEOUT_MS);
      const origResolve = resolve;
      pendingResolve = (msg) => {
        clearTimeout(timer);
        origResolve(msg);
      };
      sock.write(req);
    } catch (err) {
      reject(err);
    }
  });
}

// ---- MCP Server -----------------------------------------------------------

const server = new Server(
  { name: "godot-editor-bridge", version: "1.0.0" },
  { capabilities: { tools: {} } },
);

const TOOLS = [
  {
    name: "godot_ping",
    description: "Check if Godot editor is reachable via TCP bridge",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "godot_get_scene_tree",
    description: "Get the full scene tree hierarchy of the currently open scene",
    inputSchema: {
      type: "object",
      properties: {
        max_depth: { type: "number", description: "Max tree depth (default 4)" },
      },
    },
  },
  {
    name: "godot_select_node",
    description: "Select a node in the Godot editor by path (relative to scene root, or absolute)",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Node path, e.g. 'Terrain' or 'EditorAutoObjects/Leaf_0'" },
      },
      required: ["path"],
    },
  },
  {
    name: "godot_deselect_all",
    description: "Clear the editor selection",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "godot_get_selection",
    description: "Get currently selected nodes in the editor",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "godot_get_node_info",
    description: "Get detailed info about a node (type, position, metadata, script, etc.)",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Node path relative to scene root" },
      },
      required: ["path"],
    },
  },
  {
    name: "godot_set_node_property",
    description: "Set a property on a node. For position/rotation/scale, pass [x,y,z] array.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        property: { type: "string", description: "Property name, e.g. 'position', 'visible'" },
        value: { description: "Value to set. Use [x,y,z] for Vector3 properties." },
      },
      required: ["path", "property", "value"],
    },
  },
  {
    name: "godot_move_node",
    description: "Move a Node3D to a new position [x, y, z]",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        position: {
          type: "array", items: { type: "number" }, minItems: 3, maxItems: 3,
          description: "[x, y, z] world position",
        },
      },
      required: ["path", "position"],
    },
  },
  {
    name: "godot_get_children",
    description: "List children of a node. Use '.' or empty for scene root.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Parent node path (empty = scene root)" },
      },
    },
  },
  {
    name: "godot_call_method",
    description: "Call a method on a node",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Node path" },
        method: { type: "string", description: "Method name" },
        args: { type: "array", description: "Arguments array" },
      },
      required: ["path", "method"],
    },
  },
  {
    name: "godot_get_open_scene",
    description: "Get info about the currently open scene",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "godot_open_scene",
    description: "Open a scene in the editor by res:// path, making it the active edited scene",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Scene path, e.g. 'res://demos/foo/foo.tscn'" },
      },
      required: ["path"],
    },
  },
  {
    name: "godot_screenshot",
    description: "Capture the editor 3D viewport to a PNG file and return its absolute path",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Optional output path (res:// or absolute). Default res://_shots/mcp_screenshot.png" },
      },
    },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  const methodMap = {
    godot_ping: "ping",
    godot_get_scene_tree: "get_scene_tree",
    godot_select_node: "select_node",
    godot_deselect_all: "deselect_all",
    godot_get_selection: "get_selection",
    godot_get_node_info: "get_node_info",
    godot_set_node_property: "set_node_property",
    godot_move_node: "move_node",
    godot_get_children: "get_children",
    godot_call_method: "call_method",
    godot_get_open_scene: "get_open_scene",
    godot_open_scene: "open_scene",
    godot_screenshot: "screenshot",
  };

  const method = methodMap[name];
  if (!method) {
    return {
      content: [{ type: "text", text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }

  try {
    const response = await sendRequest(method, args || {});
    const result = response.result || response;
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  } catch (err) {
    return {
      content: [{ type: "text", text: `Error: ${err.message}` }],
      isError: true,
    };
  }
});

// ---- Start ----------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
