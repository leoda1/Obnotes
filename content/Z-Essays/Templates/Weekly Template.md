---
type: weekly
tags:
  - weekly
week_focus: 
week_summary: 
---

## ==本周总览==

```dataviewjs
const dailyFolder = "Z-Essays/Daily";
const WEEK_OFFSET = 0; // 0=本周，1=上周
const TITLE = "本周";

function quarterFileName(d) {
  const q = Math.ceil(d.month / 3);
  return `${d.year}-Q${q}`;
}

async function getLines(qName) {
  const content = await dv.io.load(`${dailyFolder}/${qName}.md`);
  return content ? content.split("\n") : [];
}

// 从 start 行起截到下一个 "# " 之前
function sliceBlock(lines, start, qName, dateStr) {
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i])) { end = i; break; }
  }
  return { qName, dateStr, heading: lines[start].replace(/^#\s+/, "").trim(), lines: lines.slice(start, end) };
}

// 新格式：一周一个区块 "# YYYY-MM-DD（周一） 至 YYYY-MM-DD（周日）"，放在周一所在季度文件
async function loadWeekBlock(monday) {
  const dateStr = monday.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(monday);
  const lines = await getLines(qName);
  const start = lines.findIndex(l => /^#\s+/.test(l) && l.includes(dateStr) && l.includes("至"));
  return start === -1 ? null : sliceBlock(lines, start, qName, dateStr);
}

// 旧格式：一天一个区块 "# YYYY-MM-DD（周X） Daily"
async function loadDayBlock(d) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(d);
  const lines = await getLines(qName);
  const start = lines.findIndex(l => /^#\s+/.test(l) && l.includes(dateStr) && !l.includes("至"));
  return start === -1 ? null : sliceBlock(lines, start, qName, dateStr);
}

// 抓区块里 TODO 段（兼容「本周TODO」和旧的「今日TODO」）
function extractTodo(block) {
  const { lines } = block;
  let start = -1;
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^#{1,6}\s+/.test(s) && /(本周|今日)TODO/.test(s)) { start = i + 1; break; }
  }
  if (start === -1) return "";
  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s+/.test(lines[i].trim())) { end = i; break; }
  }
  return lines.slice(start, end).join("\n").trim();
}

function blockLink(block) {
  return `[[${block.qName}#${block.heading}|${block.dateStr}]]`;
}

const today = dv.date("today");
const monday = today.minus({ days: today.weekday - 1 + 7 * WEEK_OFFSET });
const sunday = monday.plus({ days: 6 });
const range = `${monday.toFormat("yyyy-MM-dd")} 至 ${sunday.toFormat("yyyy-MM-dd")}`;

const weekBlock = await loadWeekBlock(monday);

if (weekBlock) {
  const section = extractTodo(weekBlock);
  // 完成项：带本周日期的 ✅（周区块会长期 follow up，之前周完成的不算进本周）
  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .filter(x => {
      const m = x.match(/✅\s*(\d{4}-\d{2}-\d{2})/);
      if (!m) return true;
      const d = dv.date(m[1]);
      return d >= monday && d <= sunday;
    })
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").replace(/\s*✅\s*\d{4}-\d{2}-\d{2}\s*$/, "").trim());
  const uniqueDone = [...new Set(done)];

  dv.paragraph(`### ${TITLE}（${range}）\n${blockLink(weekBlock)}\n${section || "—"}`);
  dv.paragraph(`### 周报\n${uniqueDone.length ? uniqueDone.map(x => `• ${x}`).join("<br>") : "—"}`);
} else {
  // 兼容旧的按天区块：周一到周五各一列
  const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));
  const headers = ["周一", "周二", "周三", "周四", "周五"];
  const allDone = [];

  for (let i = 0; i < days.length; i++) {
    const dateStr = days[i].toFormat("yyyy-MM-dd");
    const block = await loadDayBlock(days[i]);
    if (!block) {
      dv.paragraph(`### ${headers[i]}\n**${dateStr}**<br>—`);
      continue;
    }
    const section = extractTodo(block);
    dv.paragraph(`### ${headers[i]}\n${blockLink(block)}\n${section || "—"}`);
    allDone.push(...section
      .split("\n")
      .map(x => x.trim())
      .filter(x => /^- \[[xX]\]\s+/.test(x))
      .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim()));
  }

  const uniqueDone = [...new Set(allDone)];
  dv.paragraph(`### 周报\n${uniqueDone.length ? uniqueDone.map(x => `• ${x}`).join("<br>") : "—"}`);
}
```

## 本周待做

```dataviewjs
const dailyFolder = "Z-Essays/Daily";
const today = dv.date("today");

// 时间范围：本周一 ~ 本周日
const thisMonday = today.minus({ days: today.weekday - 1 });
const thisSunday = thisMonday.plus({ days: 6 });

function quarterFileName(d) {
  const q = Math.ceil(d.month / 3);
  return `${d.year}-Q${q}`;
}

// 这一周可能横跨两个季度文件（季度交界那几天）
const qNames = new Set();
for (let d = thisMonday; d <= thisSunday; d = d.plus({ days: 1 })) {
  qNames.add(quarterFileName(d));
}

const lineCache = {};
async function getLines(path) {
  if (!lineCache[path]) {
    const content = await dv.io.load(path);
    lineCache[path] = content ? content.split("\n") : [];
  }
  return lineCache[path];
}

function normalizeTaskText(text) {
  return (text || "")
    .trim()
    .replace(/\s*✅\s*\d{4}-\d{2}-\d{2}\s*$/, "") // 去掉完成日期标记（勾选后文本会变，否则匹配不上之前几天）
    .trim()
    .replace(/\s+/g, " ")
    .replace(/[?？!！。.,，、~～]+$/g, "") // 去掉结尾标点的重复/漂移（比如抄写多天后 "？" 变 "？？？？"）
    .toLowerCase();
}

// key => Map<dayMs, record>
// 同一天同一任务出现多次时，completed 状态优先
const taskDayMap = new Map();

for (const qName of qNames) {
  const page = dv.page(`${dailyFolder}/${qName}`);
  if (!page) continue;

  const lines = await getLines(page.file.path);

  for (const task of page.file.tasks) {
    // 该 task 属于哪个区块：往上找最近的 H1
    // 新格式 "# YYYY-MM-DD（周一） 至 YYYY-MM-DD（周日）" 记作周一；旧格式 "# YYYY-MM-DD（周X） Daily"
    let dateStr = null;
    let dayHeading = null;
    for (let i = task.line; i >= 0; i--) {
      const m = lines[i] && lines[i].match(/^#\s+(\d{4}-\d{2}-\d{2})(?:（周.）)?\s*(?:Daily|至)/);
      if (m) {
        dateStr = m[1];
        dayHeading = lines[i].replace(/^#\s+/, "").trim();
        break;
      }
    }
    if (!dateStr) continue;

    const day = dv.date(dateStr);
    if (!(day >= thisMonday && day <= thisSunday)) continue;

    const raw = (task.text || "").trim();
    if (!raw) continue;

    const key = normalizeTaskText(raw);
    if (!taskDayMap.has(key)) taskDayMap.set(key, new Map());

    const dayMs = day.toMillis();
    const dayBucket = taskDayMap.get(key);
    const existing = dayBucket.get(dayMs);

    if (!existing || (!existing.completed && task.completed)) {
      dayBucket.set(dayMs, {
        text: raw,
        completed: !!task.completed,
        day: day,
        link: `[[${qName}#${dayHeading}|${dateStr}]]`
      });
    }
  }
}

// 每个任务只看最新那天的状态
const latestPending = [];

for (const [key, dayBucket] of taskDayMap.entries()) {
  const records = [...dayBucket.values()]
    .sort((a, b) => b.day.toMillis() - a.day.toMillis());

  const latest = records[0];

  // 最新那天已完成 → 不显示
  if (latest.completed) continue;

  latestPending.push(latest);
}

latestPending.sort((a, b) => b.day.toMillis() - a.day.toMillis());

if (latestPending.length === 0) {
  dv.paragraph("—");
} else {
  for (const item of latestPending) {
    dv.paragraph(`- [ ] ${item.text}  \n  ↳ ${item.day.toFormat("yyyy-MM-dd")} ${item.link}`);
  }
}
```

## ==上周回顾==

```dataviewjs
const dailyFolder = "Z-Essays/Daily";
const WEEK_OFFSET = 1; // 0=本周，1=上周
const TITLE = "上周";

function quarterFileName(d) {
  const q = Math.ceil(d.month / 3);
  return `${d.year}-Q${q}`;
}

async function getLines(qName) {
  const content = await dv.io.load(`${dailyFolder}/${qName}.md`);
  return content ? content.split("\n") : [];
}

// 从 start 行起截到下一个 "# " 之前
function sliceBlock(lines, start, qName, dateStr) {
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i])) { end = i; break; }
  }
  return { qName, dateStr, heading: lines[start].replace(/^#\s+/, "").trim(), lines: lines.slice(start, end) };
}

// 新格式：一周一个区块 "# YYYY-MM-DD（周一） 至 YYYY-MM-DD（周日）"，放在周一所在季度文件
async function loadWeekBlock(monday) {
  const dateStr = monday.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(monday);
  const lines = await getLines(qName);
  const start = lines.findIndex(l => /^#\s+/.test(l) && l.includes(dateStr) && l.includes("至"));
  return start === -1 ? null : sliceBlock(lines, start, qName, dateStr);
}

// 旧格式：一天一个区块 "# YYYY-MM-DD（周X） Daily"
async function loadDayBlock(d) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(d);
  const lines = await getLines(qName);
  const start = lines.findIndex(l => /^#\s+/.test(l) && l.includes(dateStr) && !l.includes("至"));
  return start === -1 ? null : sliceBlock(lines, start, qName, dateStr);
}

// 抓区块里 TODO 段（兼容「本周TODO」和旧的「今日TODO」）
function extractTodo(block) {
  const { lines } = block;
  let start = -1;
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^#{1,6}\s+/.test(s) && /(本周|今日)TODO/.test(s)) { start = i + 1; break; }
  }
  if (start === -1) return "";
  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s+/.test(lines[i].trim())) { end = i; break; }
  }
  return lines.slice(start, end).join("\n").trim();
}

function blockLink(block) {
  return `[[${block.qName}#${block.heading}|${block.dateStr}]]`;
}

const today = dv.date("today");
const monday = today.minus({ days: today.weekday - 1 + 7 * WEEK_OFFSET });
const sunday = monday.plus({ days: 6 });
const range = `${monday.toFormat("yyyy-MM-dd")} 至 ${sunday.toFormat("yyyy-MM-dd")}`;

const weekBlock = await loadWeekBlock(monday);

if (weekBlock) {
  const section = extractTodo(weekBlock);
  // 完成项：带本周日期的 ✅（周区块会长期 follow up，之前周完成的不算进本周）
  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .filter(x => {
      const m = x.match(/✅\s*(\d{4}-\d{2}-\d{2})/);
      if (!m) return true;
      const d = dv.date(m[1]);
      return d >= monday && d <= sunday;
    })
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").replace(/\s*✅\s*\d{4}-\d{2}-\d{2}\s*$/, "").trim());
  const uniqueDone = [...new Set(done)];

  dv.paragraph(`### ${TITLE}（${range}）\n${blockLink(weekBlock)}\n${section || "—"}`);
  dv.paragraph(`### 周报\n${uniqueDone.length ? uniqueDone.map(x => `• ${x}`).join("<br>") : "—"}`);
} else {
  // 兼容旧的按天区块：周一到周五各一列
  const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));
  const headers = ["周一", "周二", "周三", "周四", "周五"];
  const allDone = [];

  for (let i = 0; i < days.length; i++) {
    const dateStr = days[i].toFormat("yyyy-MM-dd");
    const block = await loadDayBlock(days[i]);
    if (!block) {
      dv.paragraph(`### ${headers[i]}\n**${dateStr}**<br>—`);
      continue;
    }
    const section = extractTodo(block);
    dv.paragraph(`### ${headers[i]}\n${blockLink(block)}\n${section || "—"}`);
    allDone.push(...section
      .split("\n")
      .map(x => x.trim())
      .filter(x => /^- \[[xX]\]\s+/.test(x))
      .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim()));
  }

  const uniqueDone = [...new Set(allDone)];
  dv.paragraph(`### 周报\n${uniqueDone.length ? uniqueDone.map(x => `• ${x}`).join("<br>") : "—"}`);
}
```
