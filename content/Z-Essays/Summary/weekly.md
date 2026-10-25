## **2026 Q1-2**

1️⃣ ai stack 填写：[ai stack click here](https://infrawaves.feishu.cn/wiki/Qfm9wkrjQi6uqdku2vycI2xVnQb?table=tblcwhE2bNQdVpgW&view=vewLCEf7Ab&source_type=message&from=message&disposable_login_token=eyJ1c2VyX2lkIjoiNzQ4MDg4MjUyMzUwNjI5NDc4NiIsImRldmljZV9sb2dpbl9pZCI6Ijc1MDMwNjA1MTM3NDA0NzIzMzkiLCJ0aW1lc3RhbXAiOjE3NzUxMzIxNTYsInVuaXQiOiJldV9uYyIsInB3ZF9sZXNzX2xvZ2luX2F1dGgiOiIxIiwidmVyc2lvbiI6InYzIiwidGVuYW50X2JyYW5kIjoiZmVpc2h1IiwicGtnX2JyYW5kIjoi6aOe5LmmIn0=.0706908b10fb89b0b5c4f8b522195db44f50d187f0f49ddb2189990f6d006ae7)

2️⃣ 填写公司工作台周报：[https://applink.feishu.cn/T95cCs5I0LJu](https://applink.feishu.cn/T95cCs5I0LJu)

3️⃣ 周一 moon 周报：[研发项目跟踪](https://infrawaves.feishu.cn/wiki/SBVXwqp6riYj9wkM0uFcxjkBn0e?disposable_login_token=eyJ1c2VyX2lkIjoiNzQ4MDg4MjUyMzUwNjI5NDc4NiIsImRldmljZV9sb2dpbl9pZCI6Ijc1MDMwNjA1MTM3NDA0NzIzMzkiLCJ0aW1lc3RhbXAiOjE3NzUxMzIyMjQsInVuaXQiOiJldV9uYyIsInB3ZF9sZXNzX2xvZ2luX2F1dGgiOiIxIiwidmVyc2lvbiI6InYzIiwidGVuYW50X2JyYW5kIjoiZmVpc2h1IiwicGtnX2JyYW5kIjoi6aOe5LmmIn0=.83254c410b87bbe7b22de111fad32dcd94ae728bffda740623e6d4018d76d1c4)
https://infrawaves.feishu.cn/wiki/GLERwKTXqiiA9ckISYGc2xsEnBg

4️⃣ 周二填写智源陈默周报：[https://jwolpxeehx.feishu.cn/docx/V1dPdSWEPo1dQNxLxqzcCqfdnYc](https://jwolpxeehx.feishu.cn/docx/V1dPdSWEPo1dQNxLxqzcCqfdnYc)
     填写陈默PD 分离文档: https://jwolpxeehx.feishu.cn/docx/NFM0daDQFod2qRxrCedctcf6n0b
     https://jwolpxeehx.feishu.cn/docx/JxEqdu0ZMord85xVmJEcRg0ZnOb

5️⃣ 周三填写贾博进展周报：

6️⃣ 周四填写kt2周报：[https://jwolpxeehx.feishu.cn/wiki/LktqwyXIaiAXiFk6C5icRP4fnah](https://jwolpxeehx.feishu.cn/wiki/LktqwyXIaiAXiFk6C5icRP4fnah)
写 moon： https://infrawaves.feishu.cn/wiki/GLERwKTXqiiA9ckISYGc2xsEnBg

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