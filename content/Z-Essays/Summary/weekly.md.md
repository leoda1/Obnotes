
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

## 本周待做

```dataview
TASK
FROM "Z-Essays/Daily"
WHERE !completed
AND file.day >= date(today) - dur(7 days)
AND regexreplace(text, "\\s", "") != ""
SORT file.day DESC
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