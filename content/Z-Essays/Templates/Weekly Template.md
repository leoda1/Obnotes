---
type: weekly
tags:
  - weekly
week_focus: 
week_summary: 
---

# Weekly Review - {{date:YYYY-[W]WW}}

## 本周总览

```dataviewjs
const dailyFolder = "Z-Essays/Daily";

// 当前页日期基准：优先用今天
const today = dv.date("today");
const monday = today.minus({ days: today.weekday - 1 });
const days = Array.from({ length: 5 }, (_, i) => monday.plus({ days: i }));

function fileNameOfDay(d) {
  return d.toFormat("yyyy-MM-dd");
}

async function extractSection(path, heading) {
  const content = await dv.io.load(path);
  if (!content) return "—";
  const lines = content.split("\n");

  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() === heading.trim()) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return "—";

  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^#{1,6}\s+/.test(lines[i])) {
      end = i;
      break;
    }
  }

  const section = lines.slice(start, end).join("\n").trim();
  return section || "—";
}

function compact(md) {
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

for (const d of days) {
  const name = fileNameOfDay(d);
  const page = dv.page(`${dailyFolder}/${name}`);

  if (!page) {
    row.push(`**${name}**<br>—`);
    continue;
  }

  const progress = await extractSection(page.file.path, "## 🚀 今日进展");
  const next = await extractSection(page.file.path, "## 📌 明天该干啥");

  row.push(
    `**${page.file.link}**<br><br>` +
    `**进展**<br>${compact(progress)}<br><br>` +
    `**明日**<br>${compact(next)}`
  );
}

// 第六列：当前 Weekly 页自己的摘要区
const weeklyPath = dv.current().file.path;
const weeklyContent = await dv.io.load(weeklyPath);

let weeklyPreview = "—";
if (weeklyContent) {
  const lines = weeklyContent.split("\n").filter(x => x.trim());
  const useful = lines.filter(x =>
    !x.startsWith("---") &&
    !x.startsWith("type:") &&
    !x.startsWith("tags:") &&
    !x.startsWith("week_focus:") &&
    !x.startsWith("week_summary:") &&
    !x.startsWith("# Weekly Review") &&
    !x.startsWith("```dataviewjs") &&
    !x.startsWith("```")
  ).slice(0, 12);

  weeklyPreview = useful.length ? useful.join("<br>") : "—";
}

row.push(weeklyPreview);

dv.table(
  ["周一", "周二", "周三", "周四", "周五", "周报"],
  [row]
);
```
## 本周完成的进展
```dataview
TASK
FROM "Z-Essays/Daily"
WHERE contains(text, "#progress")
AND completed
AND file.day >= date(today) - dur(7 days)
SORT file.day DESC
```

## 本周卡点

```dataview
TASK
FROM "Z-Essays/Daily"
WHERE contains(text, "#blocker")
AND file.day >= date(today) - dur(7 days)
SORT file.day DESC
```

## 本周未完成计划
```dataview
TASK
FROM "Z-Essays/Daily"
WHERE contains(text, "#next")
AND !completed
AND file.day >= date(today) - dur(7 days)
SORT file.day DESC
```