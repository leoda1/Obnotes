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

// 取今天所在周的周一
const today = dv.date("today");
const monday = today.minus({ days: today.weekday - 1 });

// 周一到周五
const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));

function fileNameOfDay(d) {
  return d.toFormat("yyyy-MM-dd");
}

function fileLinkOfDay(d) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);
  return page ? page.file.link : name;
}

// 从 markdown 原文里提取某个标题下面的内容
async function extractSection(path, headingText) {
  const content = await dv.io.load(path);
  if (!content) return "";

  const lines = content.split("\n");

  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    // 只要是标题行，并且包含关键词就算匹配
    if (/^#{1,6}\s+/.test(line) && line.includes(headingText)) {
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

// 提取任务/列表并转成简短 HTML
function toCompactHtml(md) {
  if (!md || md === "—") return "—";
  return md
    .split("\n")
    .filter(x => x.trim())
    .map(x => x
      .replace(/^- \[x\] /i, "✅ ")
      .replace(/^- \[ \] /i, "⬜ ")
      .replace(/^- /, "• "))
    .join("<br>");
}

const row = [];

// 周一到周五内容：优先取“今日进展”
for (const d of days) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);

  if (!page) {
    row.push(`**${name}**<br>—`);
    continue;
  }

  const section = await extractSection(page.file.path, "今日TODO");
  row.push(`${page.file.link}\n${section || "—"}`);
}

// 第六列：当前周报页内容
const allDone = [];

for (const d of days) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);

  if (!page) continue;

  const section = await extractSection(page.file.path, "今日TODO");
  if (!section) continue;

  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim());

  allDone.push(...done);
}

// ✅ 关键：保证永远有字符串输出
let weeklySummary = "—";

if (allDone.length > 0) {
  const uniqueDone = [...new Set(allDone)];
  weeklySummary = uniqueDone.length  
        ? uniqueDone.map(x => `• ${x}`).join("<br>")  
        : "—";
}

// 👇 强制保证不是 undefined / 空
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

const pages = dv.pages(`"${dailyFolder}"`)
  .where(p => p.file.day &&
    p.file.day.toMillis() >= thisMonday.toMillis() &&
    p.file.day.toMillis() <= thisSunday.toMillis());

function normalizeTaskText(text) {
  return (text || "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
}

// key => Map<dayMs, record>
// 同一天同一任务出现多次时，completed 状态优先
const taskDayMap = new Map();

for (const page of pages) {
  const dayMs = page.file.day.toMillis();
  for (const task of page.file.tasks) {
    const raw = (task.text || "").trim();
    if (!raw) continue;

    const key = normalizeTaskText(raw);
    if (!taskDayMap.has(key)) taskDayMap.set(key, new Map());

    const dayBucket = taskDayMap.get(key);
    const existing = dayBucket.get(dayMs);

    if (!existing || (!existing.completed && task.completed)) {
      dayBucket.set(dayMs, {
        text: raw,
        completed: !!task.completed,
        day: page.file.day,
        file: page.file.link
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
    dv.paragraph(`- [ ] ${item.text}  \n  ↳ ${item.day.toFormat("yyyy-MM-dd")} ${item.file}`);
  }
}
```

## ==上周回顾==

```dataviewjs
const dailyFolder = "Z-Essays/Daily";

// 取上周的周一
const today = dv.date("today");
const thisMonday = today.minus({ days: today.weekday - 1 });
const monday = thisMonday.minus({ days: 7 });

// 上周周一到周五
const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));

function fileNameOfDay(d) {
  return d.toFormat("yyyy-MM-dd");
}

function fileLinkOfDay(d) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);
  return page ? page.file.link : name;
}

// 从 markdown 原文里提取某个标题下面的内容
async function extractSection(path, headingText) {
  const content = await dv.io.load(path);
  if (!content) return "";

  const lines = content.split("\n");

  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    // 只要是标题行，并且包含关键词就算匹配
    if (/^#{1,6}\s+/.test(line) && line.includes(headingText)) {
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

// 提取任务/列表并转成简短 HTML
function toCompactHtml(md) {
  if (!md || md === "—") return "—";
  return md
    .split("\n")
    .filter(x => x.trim())
    .map(x => x
      .replace(/^- \[x\] /i, "✅ ")
      .replace(/^- \[ \] /i, "⬜ ")
      .replace(/^- /, "• "))
    .join("<br>");
}

const row = [];

// 上周周一到周五内容
for (const d of days) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);

  if (!page) {
    row.push(`**${name}**<br>—`);
    continue;
  }

  const section = await extractSection(page.file.path, "今日TODO");
  row.push(`${page.file.link}\n${section || "—"}`);
}

// 第六列：上周完成汇总
const allDone = [];

for (const d of days) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);

  if (!page) continue;

  const section = await extractSection(page.file.path, "今日TODO");
  if (!section) continue;

  const done = section
    .split("\n")
    .map(x => x.trim())
    .filter(x => /^- \[[xX]\]\s+/.test(x))
    .map(x => x.replace(/^- \[[xX]\]\s+/, "").trim());

  allDone.push(...done);
}

// 保证永远有字符串输出
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