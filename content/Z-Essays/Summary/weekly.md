## **2026 Q1-2**

1️⃣ ai stack 填写：[ai stack click here](https://infrawaves.feishu.cn/wiki/Qfm9wkrjQi6uqdku2vycI2xVnQb?table=tblcwhE2bNQdVpgW&view=vewLCEf7Ab&source_type=message&from=message&disposable_login_token=eyJ1c2VyX2lkIjoiNzQ4MDg4MjUyMzUwNjI5NDc4NiIsImRldmljZV9sb2dpbl9pZCI6Ijc1MDMwNjA1MTM3NDA0NzIzMzkiLCJ0aW1lc3RhbXAiOjE3NzUxMzIxNTYsInVuaXQiOiJldV9uYyIsInB3ZF9sZXNzX2xvZ2luX2F1dGgiOiIxIiwidmVyc2lvbiI6InYzIiwidGVuYW50X2JyYW5kIjoiZmVpc2h1IiwicGtnX2JyYW5kIjoi6aOe5LmmIn0=.0706908b10fb89b0b5c4f8b522195db44f50d187f0f49ddb2189990f6d006ae7)

2️⃣ 填写公司工作台周报：[https://applink.feishu.cn/T95cCs5I0LJu](https://applink.feishu.cn/T95cCs5I0LJu)

3️⃣ 周一 moon 周报：[研发项目跟踪](https://infrawaves.feishu.cn/wiki/SBVXwqp6riYj9wkM0uFcxjkBn0e?disposable_login_token=eyJ1c2VyX2lkIjoiNzQ4MDg4MjUyMzUwNjI5NDc4NiIsImRldmljZV9sb2dpbl9pZCI6Ijc1MDMwNjA1MTM3NDA0NzIzMzkiLCJ0aW1lc3RhbXAiOjE3NzUxMzIyMjQsInVuaXQiOiJldV9uYyIsInB3ZF9sZXNzX2xvZ2luX2F1dGgiOiIxIiwidmVyc2lvbiI6InYzIiwidGVuYW50X2JyYW5kIjoiZmVpc2h1IiwicGtnX2JyYW5kIjoi6aOe5LmmIn0=.83254c410b87bbe7b22de111fad32dcd94ae728bffda740623e6d4018d76d1c4)

4️⃣ 周二填写智源陈默周报：[https://jwolpxeehx.feishu.cn/docx/V1dPdSWEPo1dQNxLxqzcCqfdnYc](https://jwolpxeehx.feishu.cn/docx/V1dPdSWEPo1dQNxLxqzcCqfdnYc)
     填写陈默PD 分离文档: https://jwolpxeehx.feishu.cn/docx/NFM0daDQFod2qRxrCedctcf6n0b

5️⃣ 周三填写贾博进展周报：

6️⃣ 周四填写智源玉龙周报：[https://jwolpxeehx.feishu.cn/wiki/FjhmwHt7Lifzz1kvaN1cpz8PnSg](https://jwolpxeehx.feishu.cn/wiki/FjhmwHt7Lifzz1kvaN1cpz8PnSg)

7️⃣ 1.0发版周报：[https://jwolpxeehx.feishu.cn/docx/I1v7dx64coRKAlxieY9cX3wpn3F](https://jwolpxeehx.feishu.cn/docx/I1v7dx64coRKAlxieY9cX3wpn3F)
## ==本周总览==

```dataviewjs
const dailyFolder = "Z-Essays/Daily";

function quarterFileName(d) {
  const q = Math.ceil(d.month / 3);
  return `${d.year}-Q${q}`;
}

// 日记现在按季度合并在一个文件里，每天是一个 "# YYYY-MM-DD Daily" 区块。
// 定位某一天：先找到它所在的季度文件，再在文件内容里截出该天的区块（到下一个 "# " 之前）。
async function loadDayBlock(d) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(d);
  const content = await dv.io.load(`${dailyFolder}/${qName}.md`);
  if (!content) return null;

  const lines = content.split("\n");
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i]) && lines[i].includes(dateStr)) {
      start = i;
      break;
    }
  }
  if (start === -1) return null;

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return {
    qName,
    dateStr,
    heading: lines[start].replace(/^#\s+/, "").trim(),
    lines: lines.slice(start, end),
  };
}

// 在某一天的区块里，抓指定二级标题（如"今日TODO"）下面的内容
function extractSubsection(block, headingText) {
  const { lines } = block;
  let start = -1;
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^#{1,6}\s+/.test(s) && s.includes(headingText)) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return "";

  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s+/.test(lines[i].trim())) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n").trim();
}

function dayLink(block) {
  return `[[${block.qName}#${block.heading}|${block.dateStr}]]`;
}

// 取今天所在周的周一
const today = dv.date("today");
const monday = today.minus({ days: today.weekday - 1 });

// 周一到周五
const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));

const row = [];

// 周一到周五内容：取「今日TODO」
for (const d of days) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const block = await loadDayBlock(d);

  if (!block) {
    row.push(`**${dateStr}**<br>—`);
    continue;
  }

  const section = extractSubsection(block, "今日TODO");
  row.push(`${dayLink(block)}\n${section || "—"}`);
}

// 第六列：本周完成汇总
const allDone = [];

for (const d of days) {
  const block = await loadDayBlock(d);
  if (!block) continue;

  const section = extractSubsection(block, "今日TODO");
  if (!section) continue;

  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim());

  allDone.push(...done);
}

let weeklySummary = "—";

if (allDone.length > 0) {
  const uniqueDone = [...new Set(allDone)];
  weeklySummary = uniqueDone.length
    ? uniqueDone.map(x => `• ${x}`).join("<br>")
    : "—";
}

row.push(weeklySummary || "—");

const headers = ["周一", "周二", "周三", "周四", "周五", "周报"];

for (let i = 0; i < headers.length; i++) {
  dv.paragraph(`### ${headers[i]}\n${row[i]}`);
}
```

## ==本周待做==

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
    // 该 task 属于哪一天：往上找最近的 "# YYYY-MM-DD Daily"
    let dateStr = null;
    let dayHeading = null;
    for (let i = task.line; i >= 0; i--) {
      const m = lines[i] && lines[i].match(/^#\s+(\d{4}-\d{2}-\d{2})(?:（周.）)?\s*Daily/);
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

function quarterFileName(d) {
  const q = Math.ceil(d.month / 3);
  return `${d.year}-Q${q}`;
}

async function loadDayBlock(d) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const qName = quarterFileName(d);
  const content = await dv.io.load(`${dailyFolder}/${qName}.md`);
  if (!content) return null;

  const lines = content.split("\n");
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i]) && lines[i].includes(dateStr)) {
      start = i;
      break;
    }
  }
  if (start === -1) return null;

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^#\s+/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return {
    qName,
    dateStr,
    heading: lines[start].replace(/^#\s+/, "").trim(),
    lines: lines.slice(start, end),
  };
}

function extractSubsection(block, headingText) {
  const { lines } = block;
  let start = -1;
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i].trim();
    if (/^#{1,6}\s+/.test(s) && s.includes(headingText)) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return "";

  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s+/.test(lines[i].trim())) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n").trim();
}

function dayLink(block) {
  return `[[${block.qName}#${block.heading}|${block.dateStr}]]`;
}

// 取上周的周一
const today = dv.date("today");
const thisMonday = today.minus({ days: today.weekday - 1 });
const monday = thisMonday.minus({ days: 7 });

// 上周周一到周五
const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));

const row = [];

for (const d of days) {
  const dateStr = d.toFormat("yyyy-MM-dd");
  const block = await loadDayBlock(d);

  if (!block) {
    row.push(`**${dateStr}**<br>—`);
    continue;
  }

  const section = extractSubsection(block, "今日TODO");
  row.push(`${dayLink(block)}\n${section || "—"}`);
}

// 第六列：上周完成汇总
const allDone = [];

for (const d of days) {
  const block = await loadDayBlock(d);
  if (!block) continue;

  const section = extractSubsection(block, "今日TODO");
  if (!section) continue;

  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim());

  allDone.push(...done);
}

let weeklySummary = "—";

if (allDone.length > 0) {
  const uniqueDone = [...new Set(allDone)];
  weeklySummary = uniqueDone.length
    ? uniqueDone.map(x => `• ${x}`).join("<br>")
    : "—";
}

row.push(weeklySummary || "—");

const headers = ["周一", "周二", "周三", "周四", "周五", "周报"];

for (let i = 0; i < headers.length; i++) {
  dv.paragraph(`### ${headers[i]}\n${row[i]}`);
}
```