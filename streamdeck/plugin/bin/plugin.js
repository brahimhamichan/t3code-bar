// T3code Bar Stream Deck plugin: renders ~/.config/t3code-bar/limits.json (written by the menubar app) onto keys.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const FILE = path.join(os.homedir(), ".config/t3code-bar/limits.json");
const IMGS = path.join(path.dirname(fileURLToPath(import.meta.url)), "../imgs");
const S = 144;

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith("-") ? [...acc, [v.slice(1), a[i + 1]]] : acc), []));
// `-preview <dir>` writes sample keys as SVG instead of connecting to Stream Deck.
const sd = args.preview ? { readyState: 0, on() {} } : new WebSocket(`ws://127.0.0.1:${args.port}`);
const keys = new Map(); // context → settings
let data = { agents: [] };

const send = (msg) => sd.readyState === WebSocket.OPEN && sd.send(JSON.stringify(msg));

// Brand marks: inner markup + viewBox of icons/*.svg, recolored per key.
const marks = Object.fromEntries(["claude", "openai", "grok"].map((n) => {
  const svg = fs.readFileSync(path.join(IMGS, `${n}.svg`), "utf8");
  return [n, { viewBox: svg.match(/viewBox="([^"]+)"/)[1], body: svg.replace(/^<svg[^>]*>|<\/svg>\s*$/g, "") }];
}));
const tints = { claude: "#D97757", openai: "#E5E5E5", grok: "#E5E5E5" };
const mark = (name, x, y, size) => {
  const m = marks[name];
  return m ? `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="${m.viewBox}" fill="${tints[name]}">${m.body}</svg>` : "";
};

const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const short = (t, n = 12) => (t.length > n ? `${t.slice(0, n - 1)}…` : t);
const level = (p) => (p <= 10 ? "#F87171" : p <= 30 ? "#FBBF24" : "#F5F5F5");
const text = (x, y, s, size, fill = "#F5F5F5", weight = 600, anchor = "middle") =>
  `<text x="${x}" y="${y}" text-anchor="${anchor}" font-family="-apple-system, Helvetica, Arial" font-size="${size}" font-weight="${weight}" fill="${fill}">${esc(s)}</text>`;
const bar = (x, y, w, p, tint) => `<rect x="${x}" y="${y}" width="${w}" height="8" rx="4" fill="#262626"/><rect x="${x}" y="${y}" width="${Math.max(0, (w * p) / 100)}" height="8" rx="4" fill="${tint}"/>`;
const countdown = (iso) => {
  if (!iso) return "";
  const m = Math.max(0, Math.round((Date.parse(iso) - Date.now()) / 60000));
  return m >= 1440 ? `${Math.floor(m / 1440)}d ${Math.floor((m % 1440) / 60)}h` : m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
};
const frame = (body) => `data:image/svg+xml;base64,${Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}"><rect width="${S}" height="${S}" fill="#0A0A0A"/>${body}</svg>`).toString("base64")}`;

function render({ target = "all" } = {}) {
  const agents = data.agents ?? [];
  if (!agents.length) return frame(text(72, 66, "T3code Bar", 18) + text(72, 90, "not running", 15, "#7D7D7D", 500));
  if (target === "all") {
    const rows = agents.slice(0, 3), h = S / rows.length;
    return frame(rows.map((a, i) => {
      const cy = h * i + h / 2;
      return mark(a.icon, 12, cy - 14, 28) + text(132, cy + 11, `${a.left}%`, 31, level(a.left), 700, "end");
    }).join(""));
  }
  const [agentId, account] = target.split("/");
  const agent = agents.find((a) => a.id === agentId);
  if (!agent) return frame(text(72, 78, "No data", 18, "#7D7D7D"));
  const tint = tints[agent.icon] ?? "#F5F5F5";
  if (!account) {
    const reset = agent.accounts.map((a) => a.resetsAt).filter(Boolean).sort()[0];
    return frame(mark(agent.icon, 50, 14, 44) + text(72, 102, `${agent.left}%`, 42, level(agent.left), 700) + text(72, 130, reset ? `↻ ${countdown(reset)}` : agent.name, 17, "#7D7D7D", 500));
  }
  const acc = agent.accounts.find((a) => a.name === account);
  if (!acc) return frame(mark(agent.icon, 50, 20, 44) + text(72, 100, short(account), 16, "#7D7D7D"));
  return frame(mark(agent.icon, 12, 12, 26) + text(46, 32, short(acc.name, 9), 17, "#F5F5F5", 600, "start")
    + text(72, 88, `${acc.left}%`, 42, level(acc.left), 700) + bar(14, 102, 116, acc.left, tint)
    + text(72, 134, acc.resetsAt ? `↻ ${countdown(acc.resetsAt)}` : acc.window, 16, "#7D7D7D", 500));
}

const draw = (context) => send({ event: "setImage", context, payload: { image: render(keys.get(context)), target: 0 } });
const drawAll = () => keys.forEach((_, c) => draw(c));

// Choices for the property inspector dropdown.
const options = () => [{ value: "all", label: "All agents" }, ...(data.agents ?? []).flatMap((a) => [
  { value: a.id, label: a.name },
  ...a.accounts.map((acc) => ({ value: `${a.id}/${acc.name}`, label: `${a.name} · ${acc.name}` })),
])];

function load() {
  try { data = JSON.parse(fs.readFileSync(FILE, "utf8")); } catch { data = { agents: [] }; }
  drawAll();
}

sd.on("open", () => { send({ event: args.registerEvent, uuid: args.pluginUUID }); load(); });
sd.on("message", (raw) => {
  const { event, context, payload } = JSON.parse(raw);
  if (event === "willAppear" || event === "didReceiveSettings") { keys.set(context, payload.settings ?? {}); draw(context); }
  else if (event === "willDisappear") keys.delete(context);
  else if (event === "propertyInspectorDidAppear") send({ event: "sendToPropertyInspector", context, payload: { options: options() } });
  else if (event === "keyDown") execFile("open", ["-a", "T3 Code (Nightly)"], (e) => e && execFile("open", ["-a", "T3 Code"], () => {}));
});

// The app rewrites the file atomically every minute; also redraw countdowns.
fs.watchFile(FILE, { interval: 5000 }, load);
setInterval(drawAll, 60000);

if (args.preview) {
  load();
  for (const t of ["all", "claudeAgent", "claudeAgent/Claude_MM", "codex/Codex_MM", "grok/Grok"])
    fs.writeFileSync(path.join(args.preview, `${t.replace("/", "-")}.svg`), Buffer.from(render({ target: t }).split(",")[1], "base64"));
  process.exit(0);
}
