
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

  const section = await extractSection(page.file.path, "## 🚀 今日进展");
  row.push(`**${page.file.link}**<br>${toCompactHtml(section)}`);
}

// 第六列：当前周报页内容
const weeklyPath = dv.current().file.path;
const weeklyContent = await dv.io.load(weeklyPath);
const weeklyPreview = weeklyContent
  ? weeklyContent.split("\n").filter(x => x.trim()).slice(0, 12).join("<br>")
  : "—";

row.push(weeklyPreview || "—");

dv.table(
  ["周一", "周二", "周三", "周四", "周五", "周报"],
  [row]
);
```
