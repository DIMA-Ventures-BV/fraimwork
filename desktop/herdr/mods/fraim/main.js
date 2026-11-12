// fraim in Herdr, in the Linear/GitHub dark style. One mod, drawn by role (props().role):
//   top        the title bar strip
//   sidebar    the chief of staff, dashboards, who works now, the team and the automations as lists.
//              It loads everything from the fraim machine once a minute (shared "fraim.data").
//   today      the activity column: one line per report, newest first (can be hidden)
//   thread     the header over the work column (a running agent, the team, a dashboard)
//   chiefhead  the header over the chief's own column, which is always shown
//   team       every agent's rules and activity, as a tab in the work column
//   dashboard  ~/fraim/dashboards/NAME.json drawn as a tab in the work column
// The owner talks to the chief by typing in the chief's terminal, the same Claude as WhatsApp.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, hc, readTextFile, terminals, agents, spaces, machines, run, props, shared, setShared, notify, openOverlay, closeOverlay, layout, appHome } from "herdr";

const C = {
  bg: "#0b0b0c", side: "#0b0b0c", panel: "#101012", hover: "#17171a", sel: "#1c1d23",
  line: "#1f1f23", line2: "#2a2a2f",
  text: "#d4d4d8", strong: "#ededef", muted: "#8b8b94", faint: "#5f5f68",
  accent: "#5e6ad2", green: "#4cb782", yellow: "#f2c94c", red: "#eb5757", grey: "#6b6f76",
};
const H = 44;

const SCRIPT = `for d in "$HOME"/fraim/leads/*/; do
  [ -f "$d/lead.md" ] || continue
  n="$(basename "$d")"
  disp="$(sed -n 's/^display:[[:space:]]*//p' "$d/lead.md" | head -1)"
  area="$(awk '/^## Area/{f=1;next} f&&NF{print;exit}' "$d/lead.md" | cut -c1-300)"
  team="$(sed -n 's/^team:[[:space:]]*//p' "$d/lead.md" | head -1)"
  printf 'L\\t%s\\t%s\\t%s\\t%s\\n' "$n" "$disp" "$area" "$team"
  for f in $(ls -1 "$d"/runs/*.md 2>/dev/null | tail -3); do
    text="$(sed -n '1,/^---/p' "$f" | grep -v '^---' | tr '\\n\\t' '  ' | sed 's/  */ /g' | cut -c1-600)"
    printf 'R\\t%s\\t%s\\t%s\\n' "$n" "$(basename "$f" .md)" "$text"
  done
done
printf 'C\\t%s\\n' "$(fraim-lead display 2>/dev/null)"
fraim-lead list 2>/dev/null | sed 's/^/S\\t/'
fraim-auto list 2>/dev/null | grep -v '(lead)' | sed 's/^/A\\t/'
for f in "$HOME"/fraim/dashboards/*.json; do
  [ -f "$f" ] && printf 'D\\t%s\\t%s\\n' "$(basename "$f" .json)" "$(jq -r '.title // ""' "$f" 2>/dev/null)"
done`;

// One lead in depth: its last ten reports, the work it started, its cards in the owner's queue.
const leadScript = (n) => `d="$HOME/fraim/leads/${n}"
for f in $(ls -1 "$d"/runs/*.md 2>/dev/null | tail -10); do
  text="$(sed -n '1,/^---/p' "$f" | grep -v '^---' | tr '\\n\\t' '  ' | sed 's/  */ /g' | cut -c1-1200)"
  printf 'R\\t%s\\t%s\\n' "$(basename "$f" .md)" "$text"
done
for g in $(ls -d "$HOME"/fraim/goals/g*/ 2>/dev/null | sort -V | tail -300); do
  [ "$(cat "$g/lead" 2>/dev/null)" = "${n}" ] || continue
  printf 'G\\t%s\\t%s\\t%s\\n' "$(basename "$g")" "$(cat "$g/state" 2>/dev/null)" "$(head -1 "$g/goal.md" | cut -c1-200)"
done | tail -8
fraim-queue list --all --json --lead "${n}" 2>/dev/null | jq -r '.[:12][] | "Q\\t\\(.id)\\t\\(.state)\\t\\(.title)"'`;

// Everything that rules one agent: its brief, tool list and budget (a lead) or its
// automation file, then its recent activity.
const memberScript = (kind, n) => (kind === "auto"
  ? `cat "$HOME/fraim/automations/${n}/automation.md" 2>/dev/null`
  : `d="$HOME/fraim/leads/${n}"
echo "@@BRIEF"; cat "$d/lead.md" 2>/dev/null
echo "@@TOOLS"; cat "$d/tools" 2>/dev/null
echo "@@BUDGET"; cat "$d/budget" 2>/dev/null
echo "@@ACT"
${leadScript(n)}`);

const TOOL_NAMES = {
  mcp__posthog: "PostHog analytics", mcp__browser: "Server browser", mcp__google: "Google: Gmail, Calendar, Drive",
  mcp__linear: "Linear", "mcp__github-mcp": "GitHub", WebFetch: "Read web pages", WebSearch: "Web search",
  Read: "Read files", Grep: "Search files", Glob: "Find files", Edit: "Edit files", Write: "Write files", Bash: "Any command",
};
function toolLabel(t) {
  const s = t.trim();
  if (TOOL_NAMES[s]) return TOOL_NAMES[s];
  const cmd = /^Bash\((.+?)(:\*)?\)$/.exec(s);
  if (cmd) {
    const c = cmd[1];
    if (/^git (fetch|show|log|diff|status)/.test(c)) return "Read code history";
    if (/^git /.test(c)) return "Work with code";
    if (/^npm audit/.test(c)) return "Check packages for security issues";
    if (/^(npm|npx|pnpm|yarn) (test|run test)/.test(c)) return "Run tests";
    if (/^gh /.test(c)) return "GitHub";
    if (/^fraim-/.test(c)) return `fraim: ${c.replace(/^fraim-/, "").replace(/-/g, " ")}`;
    return `Run ${c.split(" ")[0]}`;
  }
  const web = /^WebFetch\(domain:(.+)\)$/.exec(s);
  if (web) return `Read ${web[1]}`;
  const mcp = /^mcp__(?:plugin_[^_]+_)?([^_]+(?:-[^_]+)*)(?:__(.+))?$/.exec(s);
  if (mcp) return `${titleCase(mcp[1].replace(/-mcp$/, ""))}${mcp[2] ? `: ${mcp[2].replace(/_/g, " ")}` : ""}`;
  return s;
}
// "## Heading" sections of a brief, without the front matter and the title line.
function briefSections(md) {
  const body = String(md ?? "").replace(/^---\n[\s\S]*?\n---\n/, "").replace(/^# .*\n/m, "");
  const out = [];
  let cur = null;
  for (const line of body.split("\n")) {
    const h = /^##\s+(.+)$/.exec(line);
    if (h) { cur = { title: h[1].trim(), body: [] }; out.push(cur); continue; }
    if (!cur) { if (line.trim()) { cur = { title: "About", body: [] }; out.push(cur); } else continue; }
    cur.body.push(line);
  }
  return out.map((s) => ({ title: s.title, body: s.body.join("\n").trim() })).filter((s) => s.body);
}
function frontMatter(md) {
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(String(md ?? ""));
  if (!m) return { fields: {}, body: String(md ?? "") };
  const fields = {};
  for (const line of m[1].split("\n")) {
    const kv = /^([a-z_]+):\s*(.*)$/.exec(line);
    if (kv) fields[kv[1]] = kv[2].replace(/^"(.*)"$/, "$1");
  }
  return { fields, body: m[2].trim() };
}

// ---- the Rules page in owner words ----
const DAYS_LONG = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"];
function plainSchedule(cron) {
  if (!cron) return "Not planned";
  if (cron === "paused") return "Paused: it does not run until you switch it back on";
  const p = cron.trim().split(/\s+/);
  if (p.length !== 5 || !/^\d+$/.test(p[0]) || !/^\d+$/.test(p[1])) return cron;
  const time = `${String(p[1]).padStart(2, "0")}:${String(p[0]).padStart(2, "0")}`;
  const days = p[4] === "*" ? "Every day" : p[4] === "1-5" ? "Weekdays" : p[4].split(",").map((d) => DAYS_LONG[Number(d) % 7] ?? d).join(" and ");
  const next = nextRun(cron);
  return `${days} at ${time}${next ? `  ·  next ${next.toLowerCase()}` : ""}`;
}
function plainLast(last) {
  if (!last || /^never/.test(last)) return "Has not run yet";
  const m = /^(\S+)\s+(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})/.exec(last);
  if (!m) return last;
  const [y, mo, d] = m[2].split("-").map(Number);
  const date = new Date(y, mo - 1, d);
  const diff = dayDiff(date);
  const day = diff === 0 ? "Today" : diff === 1 ? "Yesterday" : `${DAY[date.getDay()]} ${d}/${mo}`;
  const how = /^ok/.test(m[1]) ? "went fine" : /^silent/.test(m[1]) ? "nothing to report" : /^skip/.test(m[1]) ? "skipped" : "failed";
  return `${day} ${m[3]}, ${how}`;
}
function plainBudget(b) {
  const n = Number(b);
  if (!b || Number.isNaN(n)) return "Standard";
  return n >= 50 ? "No daily limit on new jobs" : `Starts at most ${n} job${n === 1 ? "" : "s"} a day`;
}
const TITLES = {
  job: "What it does", area: "What it looks after", "each run": "Every check-in", "where to look": "What it watches",
  "what good looks like": "What good looks like", limits: "What it may do alone", rules: "Rules", about: "About",
};
const plainTitle = (t) => TITLES[t.toLowerCase()] ?? t;
// Commands, paths and flags are for the agent, not for the owner.
function plainText(md) {
  return String(md ?? "")
    .replace(/\s*\((?=[^)]*(?:fraim-|~\/|--|\/[a-z]|mcp__|\bgit\b|\bnpm\b))[^)]*\)/g, "")
    .replace(/`([^`]*)`/g, (_, c) => (/fraim-|~\/|--|^\//.test(c) ? "" : c))
    .replace(/\b(Use|Run|run) fraim-[a-z-]+( [a-z]+)*( [A-Z]+)*( N)?\.?/g, "")
    .replace(/\s+([.,;:])/g, "$1")
    .replace(/[ \t]{2,}/g, " ");
}

const DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const pad = (n) => String(n).padStart(2, "0");
const titleCase = (s) => s.replace(/[-_]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
const cleanTask = (t) => {
  const s = String(t ?? "");
  const card = /queue item q\d+ \("(.+?)"\)/.exec(s);
  if (card) return /^Rework/.test(s) ? `Reworked: ${card[1]}` : card[1];
  return s.replace(/^In ~\/code\/[^ ]+ \([^)]*\)[,:]?\s*/, "").replace(/^./, (c) => c.toUpperCase());
};
const isNoise = (t) => /hit your (weekly |daily )?limit|usage limit|not logged in|Please run \/login/i.test(t ?? "");
const firstSentence = (t) => {
  const m = /^(.{12,220}?[.!?])(\s|$)/.exec(t ?? "");
  return m ? m[1] : (t ?? "").length > 200 ? `${t.slice(0, 200)}...` : t ?? "";
};
function stampDate(stamp) {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})/.exec(stamp ?? "");
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}
function dayDiff(d) {
  const now = new Date();
  return Math.round((new Date(now.getFullYear(), now.getMonth(), now.getDate()) - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 864e5);
}
function when(d) {
  if (!d) return "";
  const days = dayDiff(d);
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return days === 0 ? time : days === 1 ? `Yesterday ${time}` : days < 7 ? `${DAY[d.getDay()]} ${time}` : `${d.getDate()}/${d.getMonth() + 1}`;
}
function matches(field, value) {
  return field === "*" || field.split(",").some((p) => {
    const [a, b] = p.split("-").map(Number);
    return b === undefined ? a % 7 === value : value >= a && value <= b;
  });
}
function nextRun(cron, short) {
  const p = (cron ?? "").trim().split(/\s+/);
  if (p.length !== 5 || !/^\d+$/.test(p[0]) || !/^\d+$/.test(p[1])) return "";
  const now = new Date();
  for (let i = 0; i < 8; i++) {
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i, +p[1], +p[0]);
    if (d <= now || !matches(p[4], d.getDay())) continue;
    const t = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    return i === 0 ? t : i === 1 ? (short ? `Tmrw ${t}` : `Tomorrow ${t}`) : `${DAY[d.getDay()]} ${t}`;
  }
  return "";
}

const fraimSpace = () => spaces().find((s) => s.machine && s.name === "fraim");
const machine = () => fraimSpace()?.machine ?? "fraim";

// The server updates itself; this mod follows the version it runs, so the owner's Herdr app
// changes with a server update and needs no laptop update. refresh.sh installs only a release
// signed with the key the laptop already holds, and the app reloads on the new main.js.
const modDir = () => `${appHome()}/mods/fraim`;
const SERVER_VERSION = '. /etc/fraim/runtime.env 2>/dev/null; printf %s "${FRAIM_VERSION:-}"';
async function followServer() {
  const r = await exec("bash", ["-lc", SERVER_VERSION], { on: machine(), timeout: 20000 });
  const want = (r.stdout ?? "").trim();
  if (r.code !== 0 || !/^v\d+\.\d+\.\d+$/.test(want)) return;
  const have = ((await readTextFile(`${modDir()}/version`)) ?? "").trim();
  if (have === want) return;
  const u = await exec("sh", [`${modDir()}/refresh.sh`, want, modDir()], { timeout: 180000 });
  if (u.code === 0 || warned === want) return;
  warned = want;
  console.log(`fraim: could not follow the server to ${want}: ${(u.stderr ?? "").trim()}`);
  notify({ title: "fraim", body: `Herdr's fraim look could not update to ${want}. Ask Claude on this laptop: "fraim herdr link".`, level: "warning" });
}
let warned = "";
const data = () => shared("fraim.data") ?? { leads: [], reports: [], autos: [], boards: [], error: "", loaded: false };
const chiefName = () => data().chief || "Chief of staff";
const sel = () => shared("fraim.sel") ?? "chief";
const WAITING = /^(open|new|pending|asked|waiting)/;

function live() {
  const space = fraimSpace();
  const names = new Map(terminals().map((t) => [t.address, t.name]));
  return agents().filter((a) => space && a.space === space.id).map((a) => ({ ...a, tname: names.get(a.address) ?? "" }));
}

// ---- small pieces, all in one scale: 13 text, 12 meta, 11 labels ----

// Linear-style status icons: a ring for scheduled, a ring with a center for working, a
// filled circle for needs-you or failed, a faint ring for paused.
function status(kind) {
  const ring = (color) => div().size(12).rounded(6).flex_shrink(0).border(2).border_color(color);
  if (kind === "working") return ring(C.yellow).flex().items_center().justify_center()
    .child(div().size(4).rounded(2).bg(C.yellow).loop("opacity", { from: 0.3, to: 1, period: 1100 }));
  if (kind === "blocked") return div().size(12).rounded(6).flex_shrink(0).bg(C.yellow);
  if (kind === "failed") return div().size(12).rounded(6).flex_shrink(0).bg(C.red);
  if (kind === "done") return div().size(12).rounded(6).flex_shrink(0).bg(C.green);
  if (kind === "paused") return ring(C.line2);
  if (kind === "chief") return div().size(12).rounded(3).flex_shrink(0).bg(C.accent);
  if (kind === "board") return div().size(12).rounded(3).flex_shrink(0).border(2).border_color(C.accent);
  return ring(C.grey);
}
const btn = (id, label, onClick, primary) => h_flex().id(id).h(26).px(10).items_center().rounded(5).cursor_pointer()
  .bg(primary ? C.accent : C.panel).border(1).border_color(primary ? C.accent : C.line2)
  .hover((s) => s.bg(primary ? "#6c78e0" : C.hover)).on_click(onClick)
  .child(div().text_size(12).font_medium?.().text_color(primary ? "#ffffff" : C.text).child(label));
const header = (left, right) => h_flex().h(H).flex_shrink(0).px(16).gap(8).items_center().border_b(1).border_color(C.line)
  .child(h_flex().flex_1().min_w(0).gap(8).items_center().children(left)).children(right ?? []);
const crumb = (parts) => parts.map((p, i) => div().text_size(13).text_color(i === parts.length - 1 ? C.strong : C.muted).when(i === parts.length - 1, (e) => e.font_semibold()).child(i ? `/  ${p}` : p));

// The chief has its own column ("chief"), always shown. Everything else opens in the "work"
// column beside it, as a tab of the fraim space; closing that column never touches the chief.
function openTab(name, props) {
  const space = fraimSpace();
  if (!space) return;
  run("layout.show", { id: "work" });
  const tab = space.tabs.find((t) => t.name === name);
  if (tab) { run("tab.select", { id: tab.id }); return; }
  run("tab.new", { space: space.id, name, mod: "fraim", props });
}
function openBoard(b) {
  setShared("fraim.sel", `board:${b.name}`);
  openTab(b.title, { role: "dashboard", name: b.name, machine: machine() });
}
function openTeam(member) {
  if (member) setShared("fraim.member", member);
  setShared("fraim.sel", "team");
  openTab("Team", { role: "team" });
}
function showWorkTab(tabId, selKey) {
  setShared("fraim.sel", selKey);
  run("layout.show", { id: "work" });
  run("tab.select", { id: tabId });
}
function findNode(node, id) {
  if (node?.id === id) return node;
  for (const c of node?.children ?? []) { const f = findNode(c, id); if (f) return f; }
  return null;
}
const chiefTerminal = () => terminals().find((t) => t.name === "main" && t.state === "live" && String(t.address ?? "").startsWith(`${machine()}/`));
// Points the chief column at the live chief (its address changes when the server restarts
// it). The chief is never a tab: closing a tab ends its terminal. A chief that still has one
// (an older server labelled it into the space) loses the label and the tab, and keeps running.
function keepChief() {
  keepSpace();
  const t = chiefTerminal();
  if (!t) return;
  const tree = layout();
  const node = findNode(tree, "chief-term");
  if (node && node.content?.terminal !== t.address) {
    const copy = JSON.parse(JSON.stringify(tree));
    findNode(copy, "chief-term").content = { terminal: t.address };
    run("layout.set", { layout: copy });
  }
  if (agents().some((a) => a.address === t.address) && shared("fraim.parked") !== t.address) {
    setShared("fraim.parked", t.address);
    hc(["label", t.address, "herdr.space="]).finally(() => run("terminal.park", { terminal: t.address }));
  }
}
// Herdr removes a space with its last tab. Team, dashboards and agents open as tabs of
// fraim's space, so when it is gone, make it again (with the machine, once it answers) and
// tell the server its new id, where goals and sessions read it (~/.config/fraim/herdr-space).
function keepSpace() {
  const m = machines().find((x) => x.name && /^fraim(-|$)/.test(x.name) && x.layout === "ready");
  if (!m) return;
  const space = spaces().find((s) => s.machine === m.name && s.name === "fraim");
  if (!space) {
    if (shared("fraim.making") !== true) {
      setShared("fraim.making", true);
      run("space.new", { name: "fraim", machine: m.name, folder: "/home/claude/fraim" });
    }
    return;
  }
  setShared("fraim.making", false);
  const id = space.id.replace(/^[^/]+\//, "");
  if (shared("fraim.spaceSaved") !== id && /^sp[0-9a-f]{8,64}$/.test(id)) {
    setShared("fraim.spaceSaved", id);
    exec("bash", ["-lc", `mkdir -p ~/.config/fraim && printf '%s\\n' ${id} > ~/.config/fraim/herdr-space`], { on: m.name, timeout: 20000 }).catch(() => setShared("fraim.spaceSaved", ""));
  }
}
const chiefStatus = () => {
  const s = chiefTerminal()?.status;
  return typeof s === "string" ? s : s?.state ?? "";
};
function setTodayShown(shown) {
  run(shown ? "layout.show" : "layout.hide", { id: "today" });
  setShared("fraim.today", shown);
}

export default class FraimChat extends View {
  init(_props, cx) {
    const p = props() ?? {};
    this.role = p.role ?? "today";
    this.p = p;
    this.open = new Set();
    if (this.role === "sidebar") {
      cx.timer.every(60000, (cx) => this.refresh(cx));
      this.refresh(cx);
      const follow = () => cx.spawn(async () => { try { await followServer(); } catch {} });
      follow();
      cx.timer.every(3600000, () => follow());
    }
    if (this.role === "dashboard" && /^[a-z0-9-]+$/.test(p.name ?? "")) {
      this.loadBoard(cx);
      cx.timer.every(30000, (cx) => this.loadBoard(cx));
    }
  }

  refresh(cx) {
    cx.spawn(async (cx) => {
      const old = data();
      try {
        const r = await exec("bash", ["-lc", SCRIPT], { on: machine(), timeout: 20000 });
        const leads = new Map();
        const reports = [];
        const autos = [];
        const boards = [];
        let chief = "";
        for (const line of r.stdout.split("\n")) {
          const f = line.split("\t");
          if (f[0] === "L") leads.set(f[1], { name: f[1], disp: f[2] || titleCase(f[1]), area: f[3] || "", team: (f[4] ?? "").trim() });
          if (f[0] === "R" && f[3] && !/^\s*SILENT\b/.test(f[3]) && !isNoise(f[3])) reports.push({ lead: f[1], stamp: f[2], text: f[3].trim() });
          const m = line.match(/^S\t(\S+)\s{2}(\S+)\s{2}(.+?)\s{2}budget .*?last: (.*)$/);
          if (m && leads.has(m[1])) Object.assign(leads.get(m[1]), { kind: m[2], sched: m[3], last: m[4] });
          const am = line.match(/^A\t(\S+)\s+\[(\w+)\]\s+(.+?)\s+last: (.*)$/);
          if (am) autos.push({ name: am[1], state: am[2], trigger: am[3], last: am[4] });
          if (f[0] === "C") chief = (f[1] ?? "").trim();
          if (f[0] === "D" && /^[a-z0-9-]+$/.test(f[1] ?? "")) boards.push({ name: f[1], title: f[2] || titleCase(f[1]) });
        }
        const list = [...leads.values()];
        reports.sort((a, b) => b.stamp.localeCompare(a.stamp));
        setShared("fraim.data", { leads: list, reports, autos, boards, chief, error: list.length ? "" : "The server sent no team.", loaded: true });
      } catch (e) {
        setShared("fraim.data", { ...old, error: "The server is not reachable.", loaded: true });
      }
    });
  }

  showChief() {
    setShared("fraim.sel", "chief");
    const t = chiefTerminal();
    if (t) run("pane.focus", { terminal: t.address });
  }

  openLead(l) {
    const a = live().find((x) => x.tname === `lead-${l.name}`);
    if (a) { showWorkTab(a.tab, l.name); return; }
    openTeam({ kind: "lead", name: l.name });
  }

  // ---------------- top strip and sidebar ----------------

  top() {
    const d = data();
    const n = live().filter((a) => a.tname !== "main" && a.status === "working").length;
    return h_flex().size_full().bg(C.side).pl(84).pr(16).items_center().gap(8).border_b(1).border_color(C.line)
      .child(div().flex_1())
      .child(div().size(6).rounded(3).bg(d.error ? C.red : C.green))
      .child(div().text_size(11).text_color(C.faint).child(d.error ? "Server offline" : n ? `${n} working` : "Server online"));
  }

  row(id, { icon, name, meta, active, strong, onClick }) {
    return h_flex().id(id).h(28).mx(8).px(8).gap(8).items_center().rounded(5).cursor_pointer()
      .when(active, (e) => e.bg(C.sel)).hover((s) => s.bg(active ? C.sel : C.hover)).on_click(onClick)
      .child(icon)
      .child(div().flex_1().min_w(0).truncate().text_size(13).text_color(active || strong ? C.strong : C.text).child(name))
      .when(!!meta, (e) => e.child(div().flex_shrink(0).text_size(11).text_color(C.faint).child(meta)));
  }

  group(title, count) {
    return h_flex().px(16).mt(16).mb(4).h(20).items_center().justify_between()
      .child(div().text_size(11).font_semibold().text_color(C.faint).child(title))
      .when(count !== undefined, (e) => e.child(div().text_size(11).text_color(C.faint).child(String(count))));
  }

  sidebar() {
    keepChief();
    const d = data();
    const s = sel();
    const all = live();
    const main = { status: chiefStatus() };
    const others = all.filter((a) => a.tname !== "main");
    const team = d.leads.filter((l) => l.name !== "chief");
    const boards = d.boards ?? [];
    const autos = d.autos ?? [];
    const member = shared("fraim.member");
    return v_flex().size_full().bg(C.side)
      .child(header([div().text_size(13).font_semibold().text_color(C.strong).child("fraim")]))
      .child(v_flex().id("fc-side").flex_1().min_h(0).overflow_y_scrollbar().pt(8).pb(16)
        .child(this.row("fc-chief", {
          icon: status(main?.status === "working" ? "working" : main?.status === "blocked" ? "blocked" : "chief"),
          name: chiefName(), active: s === "chief", onClick: () => this.showChief(),
        }))
        .when(team.length > 0, (e) => e.child(this.group("Team", team.length)).children(team.map((l) =>
          this.row(`fc-l-${l.name}`, {
            icon: status(l.sched === "paused" ? "paused" : "idle"), name: l.disp,
            active: s === "team" && member?.kind === "lead" && member?.name === l.name,
            onClick: () => openTeam({ kind: "lead", name: l.name }),
          }))))
        .when(autos.length > 0, (e) => e.child(this.group("Automations", autos.length)).children(autos.map((a) =>
          this.row(`fc-a-${a.name}`, {
            icon: status(a.state !== "on" ? "paused" : "idle"), name: titleCase(a.name),
            active: s === "team" && member?.kind === "auto" && member?.name === a.name,
            onClick: () => openTeam({ kind: "auto", name: a.name }),
          }))))
        .when(boards.length > 0, (e) => e.child(this.group("Dashboards", boards.length)).children(boards.map((b) =>
          this.row(`fc-d-${b.name}`, { icon: status("board"), name: b.title, active: s === `board:${b.name}`, onClick: () => openBoard(b) }))))
        .when(others.length > 0, (e) => e.child(this.group("Working now", others.length)).children(others.map((a) =>
          this.row(`fc-o-${a.address}`, {
            icon: status(a.status === "blocked" ? "blocked" : a.status === "working" ? "working" : "done"),
            name: d.leads.find((l) => `lead-${l.name}` === a.tname)?.disp ?? (a.tab_name || a.tname), active: s === a.address,
            meta: a.status === "blocked" ? "Needs you" : "",
            onClick: () => showWorkTab(a.tab, a.address),
          }))))
        .when(!d.loaded, (e) => e.child(div().px(16).py(4).text_size(12).text_color(C.faint).child("Loading...")))
        .when(!!d.error, (e) => e.child(div().px(16).py(4).text_size(12).text_color(C.red).child(d.error))));
  }

  // ---------------- activity column ----------------

  today() {
    const d = data();
    const leadByName = new Map(d.leads.map((l) => [l.name, l]));
    const rows = [];
    let lastDay = null;
    for (const r of d.reports.slice(0, 50)) {
      const l = leadByName.get(r.lead);
      const date = stampDate(r.stamp);
      if (!l || !date || !firstSentence(r.text).trim()) continue;
      const diff = dayDiff(date);
      const day = diff === 0 ? "Today" : diff === 1 ? "Yesterday" : `${DAY[date.getDay()]} ${date.getDate()}/${date.getMonth() + 1}`;
      if (day !== lastDay) {
        rows.push(div().px(16).pt(14).pb(6).text_size(11).font_semibold().text_color(C.faint).child(day));
        lastDay = day;
      }
      const name = l.name === "chief" ? chiefName() : l.disp;
      rows.push(v_flex().id(`fc-t-${r.lead}-${r.stamp}`).px(16).py(8).gap(3).cursor_pointer()
        .border_b(1).border_color(C.line).hover((s) => s.bg(C.hover))
        .on_click(() => (l.name === "chief" ? this.showChief() : openTeam({ kind: "lead", name: l.name })))
        .child(h_flex().gap(8).items_center()
          .child(div().flex_1().min_w(0).truncate().text_size(12).font_semibold().text_color(C.strong).child(name))
          .child(div().text_size(11).text_color(C.faint).child(`${pad(date.getHours())}:${pad(date.getMinutes())}`)))
        .child(div().text_size(12).text_color(C.muted).child(firstSentence(r.text))));
    }
    return v_flex().size_full().bg(C.bg)
      .child(header([div().text_size(13).font_semibold().text_color(C.strong).child("Activity")],
        [btn("fc-collapse", "Hide", () => setTodayShown(false))]))
      .child(v_flex().id("fc-today").flex_1().min_h(0).overflow_y_scrollbar().pb(16)
        .when(rows.length === 0, (e) => e.child(div().px(16).py(12).text_size(12).text_color(C.faint).child(d.loaded ? "No activity yet." : "Loading...")))
        .children(rows));
  }

  // ---------------- middle header ----------------

  thread() {
    const f = fraimSpace();
    const tab = f?.tabs.find((t) => t.active);
    const main = live().find((a) => a.tname === "main");
    const isChief = !!main && tab?.id === main.tab;
    return v_flex().size_full().bg(C.bg)
      .child(header(crumb(this.crumbs(isChief, tab)), [btn("fc-close-work", "Close", () => { run("layout.hide", { id: "work" }); setShared("fraim.sel", "chief"); })]));
  }

  // The header over the chief's own column: always there.
  chiefHead() {
    const t = chiefTerminal();
    const a = t ? { status: chiefStatus() } : null;
    const state = !t ? "Restarting..." : a?.status === "working" ? "Thinking" : a?.status === "blocked" ? "Waiting for you" : "";
    const right = [div().text_size(11).text_color(C.faint).child(state)];
    const workHidden = !!findNode(layout(), "work")?.hidden;
    right.push(btn("fc-work", workHidden ? "Show workspace" : "Hide workspace", () => run(workHidden ? "layout.show" : "layout.hide", { id: "work" })));
    return v_flex().size_full().bg(C.bg)
      .child(header([status(a?.status === "working" ? "working" : a?.status === "blocked" ? "blocked" : "chief"),
        div().text_size(13).font_semibold().text_color(C.strong).child(chiefName())], right));
  }

  crumbs(isChief, tab) {
    if (isChief) return ["fraim", chiefName()];
    if ((data().boards ?? []).some((b) => b.title === tab?.name)) return ["Dashboards", tab.name];
    if (tab?.name === "Team") {
      const m = shared("fraim.member");
      if (!m) return ["fraim", "Team"];
      const l = (data().leads ?? []).find((x) => x.name === m.name);
      return [m.kind === "auto" ? "Automations" : "Team", m.name === "chief" ? chiefName() : l?.disp ?? titleCase(m.name)];
    }
    return ["Working now", tab?.name || "Live"];
  }

  section(title, count) {
    return h_flex().mt(20).mb(6).gap(6).items_center()
      .child(div().text_size(12).font_semibold().text_color(C.muted).child(title))
      .when(count !== undefined, (e) => e.child(div().text_size(12).text_color(C.faint).child(String(count))));
  }

  item(id, icon, text, meta) {
    return h_flex().id(id).h(32).px(8).gap(10).items_center().border_b(1).border_color(C.line).hover((s) => s.bg(C.hover))
      .child(icon)
      .child(div().flex_1().min_w(0).truncate().text_size(13).text_color(C.text).child(text || ""))
      .when(!!meta, (e) => e.child(div().flex_shrink(0).text_size(12).text_color(C.faint).child(meta)));
  }

  prop(label, value) {
    return h_flex().py(6).gap(8).items_start()
      .child(div().w(84).flex_shrink(0).text_size(12).text_color(C.faint).child(label))
      .child(div().flex_1().min_w(0).text_size(12).text_color(C.text).child(value || "-"));
  }

  runNow(kind, item, on, overlay) {
    const cmd = kind === "auto" ? "fraim-auto" : "fraim-lead";
    const name = kind === "auto" ? titleCase(item.name) : item.disp;
    exec("bash", ["-lc", `setsid -f ${cmd} run ${item.name} >/dev/null 2>&1 </dev/null`], { on, timeout: 20000 })
      .then((r) => {
        notify(r.code === 0 ? { title: `${name} started`, level: "success" } : { title: `${name} did not start`, level: "error" });
        if (r.code === 0 && overlay) closeOverlay(overlay);
      })
      .catch(() => notify({ title: "The server is not reachable", level: "error" }));
  }

  // ---------------- dashboard ----------------
  // ~/fraim/dashboards/NAME.json on the server, written by agents:
  // { title, subtitle, updated, source, tiles: [{label, value, note, tone}],
  //   bars: {title, unit, items: [{label, value, note, tone}]}, notes: ["..."] }
  // tone: good | warn | bad. Reread every 30 seconds while shown.

  loadBoard(cx) {
    const { name, machine: on } = this.p;
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(`/home/claude/fraim/dashboards/${name}.json`, { on });
        this.board = text ? JSON.parse(text) : { error: "This dashboard has no data yet." };
      } catch (e) {
        this.board = { error: "Could not read this dashboard." };
      }
      cx.notify();
    });
  }

  dashboard() {
    const b = this.board;
    if (!b || b.error) return v_flex().size_full().bg(C.bg)
      .child(div().p(24).text_size(13).text_color(b?.error ? C.red : C.faint).child(b?.error ?? "Loading..."));
    const meta = h_flex().gap(8).items_center()
      .child(div().flex_1().text_size(13).text_color(C.muted).child(String(b.subtitle ?? "")))
      .child(div().text_size(12).text_color(C.faint).child(`Updated ${b.updated ?? "?"}${b.source ? ` · ${b.source}` : ""}`));
    const tone = (t) => (t === "good" ? C.green : t === "warn" ? C.yellow : t === "bad" ? C.red : C.strong);
    const tiles = (b.tiles ?? []).slice(0, 8).map((t, i) => v_flex().id(`fd-t-${i}`).flex_1().min_w(150).px(16).py(14).gap(4)
      .when(i > 0, (e) => e.border_l(1).border_color(C.line))
      .child(div().text_size(12).text_color(C.muted).child(String(t.label ?? "")))
      .child(div().text_size(22).font_semibold().text_color(tone(t.tone)).child(String(t.value ?? "")))
      .when(!!t.note, (e) => e.child(div().text_size(12).text_color(C.faint).child(String(t.note)))));
    const items = b.bars?.items ?? [];
    const max = Math.max(1, ...items.map((x) => Number(x.value) || 0));
    const barTone = (t) => (t === "good" ? C.green : t === "warn" ? C.yellow : t === "bad" ? C.red : C.accent);
    const bars = items.slice(0, 12).map((x, i) => h_flex().id(`fd-b-${i}`).h(34).px(16).gap(12).items_center().border_b(1).border_color(C.line)
      .child(div().w(200).flex_shrink(0).truncate().text_size(13).text_color(C.text).child(String(x.label ?? "")))
      .child(div().flex_1().h(6).rounded(3).bg(C.hover)
        .child(div().h(6).rounded(3).bg(barTone(x.tone)).w(`${Math.max(2, Math.round(((Number(x.value) || 0) / max) * 100))}%`)))
      .child(div().w(72).flex_shrink(0).text_size(13).text_color(C.strong).child(`${b.bars.unit ?? ""}${Number(x.value).toLocaleString("nl-NL", { maximumFractionDigits: 2 })}`))
      .child(div().w(110).flex_shrink(0).text_size(12).text_color(C.faint).child(String(x.note ?? ""))));
    return v_flex().size_full().bg(C.bg)
      .child(v_flex().id("fd-body").flex_1().min_h(0).overflow_y_scrollbar().px(24).py(20).gap(24)
        .child(meta)
        .when(tiles.length > 0, (e) => e.child(h_flex().rounded(6).border(1).border_color(C.line).bg(C.panel).children(tiles)))
        .when(bars.length > 0, (e) => e.child(v_flex()
          .child(div().pb(8).text_size(12).font_semibold().text_color(C.muted).child(String(b.bars.title ?? "")))
          .child(v_flex().rounded(6).border(1).border_color(C.line).bg(C.panel).children(bars))))
        .when((b.notes ?? []).length > 0, (e) => e.child(v_flex()
          .child(div().pb(8).text_size(12).font_semibold().text_color(C.muted).child("Notes"))
          .child(v_flex().rounded(6).border(1).border_color(C.line).bg(C.panel)
            .children(b.notes.slice(0, 10).map((n, i) => h_flex().id(`fd-n-${i}`).px(16).py(9).gap(10).items_start()
              .when(i > 0, (e) => e.border_t(1).border_color(C.line))
              .child(div().text_size(13).text_color(C.text).child(String(n)))))))));
  }

  // ---------------- team and rules ----------------

  loadBrain(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("bash", ["-lc", "fraim-brain show"], { on: machine(), timeout: 20000 });
        this.brain = r.stdout.replace(/^# .*\n/, "").replace(/\s*\[r\d+: e\d+\]/g, "").replace(/\n+Work sent back.*$/s, "").trim();
      } catch (e) { this.brain = ""; }
      cx.notify();
    });
  }

  loadMember(cx, m) {
    const key = `${m.kind}:${m.name}`;
    this.memberKey = key;
    this.member = null;
    if (!/^[a-z0-9-]+$/.test(m.name)) { this.member = { error: "Unknown." }; return; }
    cx.spawn(async (cx) => {
      try {
        const r = await exec("bash", ["-lc", memberScript(m.kind, m.name)], { on: machine(), timeout: 20000 });
        let out;
        if (m.kind === "auto") {
          out = { auto: frontMatter(r.stdout) };
        } else {
          const part = (k) => { const a = r.stdout.indexOf(`@@${k}\n`); if (a < 0) return ""; const rest = r.stdout.slice(a + k.length + 3); const b = rest.search(/^@@[A-Z]+$/m); return b < 0 ? rest : rest.slice(0, b); };
          const act = { reports: [], goals: [], queue: [] };
          for (const line of part("ACT").split("\n")) {
            const f = line.split("\t");
            if (f[0] === "R" && f[2] && !/^\s*SILENT\b/.test(f[2]) && !isNoise(f[2])) act.reports.push({ stamp: f[1], text: f[2].trim() });
            if (f[0] === "G") act.goals.push({ id: f[1], state: (f[2] ?? "").split(" ")[0], text: cleanTask(f[3]) });
            if (f[0] === "Q") act.queue.push({ id: f[1], state: f[2], text: f[3] });
          }
          act.reports.reverse();
          act.goals.reverse();
          out = {
            brief: briefSections(part("BRIEF")),
            tools: part("TOOLS").split("\n").map((t) => t.trim()).filter(Boolean),
            budget: part("BUDGET").trim(),
            act,
          };
        }
        if (this.memberKey === key) this.member = out;
      } catch (e) {
        if (this.memberKey === key) this.member = { error: "The server is not reachable." };
      }
      cx.notify();
    });
  }

  tabs(id, items, current, onPick) {
    return h_flex().gap(4).children(items.map((t) => h_flex().id(`${id}-${t}`).h(26).px(10).items_center().rounded(5).cursor_pointer()
      .when(t === current, (e) => e.bg(C.sel)).hover((s) => s.bg(C.hover))
      .on_click((_e, cx) => { onPick(t); cx.notify(); })
      .child(div().text_size(12).text_color(t === current ? C.strong : C.muted).child(t))));
  }

  block(title, content) {
    return v_flex().mb(18)
      .child(div().pb(6).text_size(12).font_semibold().text_color(C.muted).child(title))
      .child(v_flex().px(14).py(10).rounded(6).border(1).border_color(C.line).bg(C.panel).text_size(13).text_color(C.text).child(content));
  }

  team(cx) {
    const d = data();
    const m = shared("fraim.member");
    if (!m) return v_flex().size_full().bg(C.bg).p(24).child(div().text_size(13).text_color(C.faint).child("Pick someone under Team on the left."));
    if (this.memberKey !== `${m.kind}:${m.name}`) this.loadMember(cx, m);
    if (this.brain === undefined) { this.brain = null; this.loadBrain(cx); }
    const leads = d.leads ?? [];
    const autos = d.autos ?? [];
    const pick = (kind, name) => setShared("fraim.member", { kind, name });
    const lead = m.kind === "lead" ? leads.find((l) => l.name === m.name) : null;
    const auto = m.kind === "auto" ? autos.find((a) => a.name === m.name) : null;
    const title = m.name === "chief" ? chiefName() : lead?.disp ?? (auto ? titleCase(auto.name) : m.name);
    const sub = lead?.area ?? (auto ? `Automation · ${auto.trigger}` : "");
    this.view = this.view ?? "Rules";
    const det = this.member;
    const body = [];
    if (!det) body.push(div().text_size(13).text_color(C.faint).child("Loading..."));
    else if (det.error) body.push(div().text_size(13).text_color(C.red).child(det.error));
    else if (det.auto) {
      const f = det.auto.fields;
      body.push(this.block("Setup", v_flex()
        .child(this.prop("When", f.schedule ? `${f.schedule}  (next ${nextRun(f.schedule) || "-"})` : f.every ? `Every ${f.every}` : f.trigger || auto?.trigger || "-"))
        .child(this.prop("Sends to", f.output))
        .child(this.prop("Time limit", f.timeout))
        .child(this.prop("Status", auto?.state === "on" ? "On" : titleCase(auto?.state ?? "-")))));
      if (f.tools) body.push(this.block("Allowed tools", h_flex().flex_wrap().gap(6).children(f.tools.split(",").map((t, i) =>
        div().id(`tt-${i}`).px(8).py(3).rounded(4).border(1).border_color(C.line2).text_size(12).text_color(C.text).child(toolLabel(t))))));
      body.push(this.block("Instructions", TextView.markdown(`tm-ins-${m.name}`, det.auto.body || "-").selectable(true)));
    } else if (this.view === "Rules") {
      body.push(this.block("When it works", v_flex()
        .child(this.prop("Checks in", plainSchedule(lead?.sched)))
        .child(this.prop("Last time", plainLast(lead?.last)))
        .child(this.prop("Workload", plainBudget(det.budget)))));
      for (const s of det.brief) body.push(this.block(plainTitle(s.title), TextView.markdown(`tm-b-${m.name}-${s.title}`, plainText(s.body)).selectable(true)));
      body.push(this.block("What it can use", det.tools.length
        ? h_flex().flex_wrap().gap(6).children(det.tools.map((t, i) =>
          div().id(`tl-${i}`).px(8).py(3).rounded(4).border(1).border_color(C.line2).text_size(12).text_color(C.text).child(toolLabel(t))))
        : div().text_color(C.faint).child("The standard set (read, search, the queue).")));
    } else {
      const a = det.act;
      if (!a.reports.length && !a.goals.length && !a.queue.length) body.push(div().text_size(13).text_color(C.faint).child("Nothing yet."));
      const waiting = a.queue.filter((q) => WAITING.test(q.state));
      if (waiting.length) body.push(this.block(`Waiting for you · ${waiting.length}`, v_flex().children(waiting.map((q) => this.item(`ta-q-${q.id}`, status("blocked"), q.text, q.state)))));
      if (a.reports.length) body.push(this.block("Reports", v_flex().children(a.reports.map((r) => {
        const isOpen = this.open.has(r.stamp);
        return h_flex().id(`ta-r-${r.stamp}`).py(7).gap(12).items_start().border_b(1).border_color(C.line).cursor_pointer()
          .on_click((_e, cx) => { if (isOpen) this.open.delete(r.stamp); else this.open.add(r.stamp); cx.notify(); })
          .child(div().w(92).flex_shrink(0).text_size(12).text_color(C.faint).child(when(stampDate(r.stamp))))
          .child(div().flex_1().min_w(0).text_size(13).text_color(C.text).when(!isOpen, (e) => e.truncate()).child(isOpen ? r.text : firstSentence(r.text)));
      }))));
      const work = [
        ...a.goals.map((g) => ({ id: g.id, k: /done|ok/.test(g.state) ? "done" : /fail|error|stopped/.test(g.state) ? "failed" : "idle", text: g.text, state: g.state })),
        ...a.queue.filter((q) => !WAITING.test(q.state)).map((q) => ({ id: q.id, k: /approved|solved|done/.test(q.state) ? "done" : /reject/.test(q.state) ? "failed" : "idle", text: q.text, state: q.state })),
      ].slice(0, 12);
      if (work.length) body.push(this.block("Work", v_flex().children(work.map((w) => this.item(`ta-w-${w.id}`, status(w.k), w.text, titleCase(w.state))))));
    }
    if (this.view === "Rules" && this.brain) body.push(this.block("Shared rules · apply to every agent", TextView.markdown("tm-brain", this.brain).selectable(true)));

    const detail = v_flex().size_full().min_w(0)
      .child(v_flex().px(24).pt(14).pb(12).gap(6).border_b(1).border_color(C.line)
        .child(h_flex().gap(10).items_center()
          .child(div().flex_1().text_size(16).font_semibold().text_color(C.strong).child(title))
          .when(!!lead || !!auto, (e) => e.child(btn("tm-run", "Run now", () => this.runNow(auto ? "auto" : "lead", auto ?? lead, machine(), null), true))))
        .when(!!sub, (e) => e.child(div().text_size(13).text_color(C.muted).child(sub)))
        .when(!auto, (e) => e.child(h_flex().pt(6).child(this.tabs("tm-tab", ["Rules", "Activity"], this.view, (v) => { this.view = v; })))))
      .child(v_flex().id("tm-body").flex_1().min_h(0).overflow_y_scrollbar().px(24).py(18).children(body));

    return v_flex().size_full().bg(C.bg).child(detail);
  }

  render(cx) {
    if (this.role === "team") return this.team(cx);
    if (this.role === "dashboard") return this.dashboard();
    if (this.role === "top") return this.top();
    if (this.role === "sidebar") return this.sidebar();
    if (this.role === "thread") return this.thread();
    if (this.role === "chiefhead") return this.chiefHead();
    return this.today();
  }
}
