import fs from "node:fs";
import readline from "node:readline";

const root = process.argv[2];
const statePath = `${root}/inventory-service-state.json`;
const auditPath = `${root}/inventory-audit.ndjson`;
if (!fs.existsSync(statePath)) {
  fs.writeFileSync(statePath, JSON.stringify({ stock: { ALPHA: 20, BETA: 20 }, receipts: [], faultUsed: false }));
}
const tools = [
  { name: "stock", description: "Read current stock and all reservation receipts, including outcomes whose acknowledgement was lost.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true } },
  { name: "reserve", description: "Reserve stock. Each call creates another reservation; repeated calls can duplicate orders. Reconcile uncertain outcomes with stock before retrying.", inputSchema: { type: "object", properties: { sku: { type: "string", enum: ["ALPHA", "BETA"] }, quantity: { type: "integer", minimum: 1 }, order: { type: "string" } }, required: ["sku", "quantity", "order"], additionalProperties: false } },
];
const send = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
for await (const line of readline.createInterface({ input: process.stdin })) {
  let m;
  try { m = JSON.parse(line); } catch { continue; }
  if (m.id === undefined) continue;
  if (m.method === "initialize") {
    send(m.id, { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "inventory-proof", version: "1" } });
  } else if (m.method === "tools/list") {
    send(m.id, { tools });
  } else if (m.method === "ping") {
    send(m.id, {});
  } else if (m.method === "tools/call") {
    const s = JSON.parse(fs.readFileSync(statePath, "utf8"));
    const { name, arguments: a = {} } = m.params;
    fs.appendFileSync(auditPath, JSON.stringify({ at: new Date().toISOString(), pid: process.pid, name, args: a }) + "\n");
    if (name === "stock") {
      send(m.id, { content: [{ type: "text", text: JSON.stringify(s) }] });
    } else if (name === "reserve" && Number.isInteger(a.quantity) && a.quantity > 0 && s.stock[a.sku] >= a.quantity) {
      const receipt = { id: `receipt-${s.receipts.length + 1}`, ...a };
      s.stock[a.sku] -= a.quantity;
      s.receipts.push(receipt);
      const crash = !s.faultUsed;
      s.faultUsed = true;
      fs.writeFileSync(statePath, JSON.stringify(s));
      if (crash) process.exit(17);
      send(m.id, { content: [{ type: "text", text: JSON.stringify(receipt) }] });
    } else {
      send(m.id, { isError: true, content: [{ type: "text", text: "Invalid reservation or insufficient stock" }] });
    }
  } else {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "Method not found" } }) + "\n");
  }
}
