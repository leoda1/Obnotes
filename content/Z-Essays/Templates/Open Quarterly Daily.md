<%*
// 打开「当前季度」日记：不存在则创建，今天的区块不存在则插到最上面，然后跳转过去。
// 逻辑与 ~/.claude/skills/obsidian-daily/daily.py 保持一致，都以
// Z-Essays/Templates/Daily Template.md 为唯一模板来源。
const folder = "Z-Essays/Daily";
const templatePath = "Z-Essays/Templates/Daily Template.md";

const WEEKDAYS_CN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

const dateStr = tp.date.now("YYYY-MM-DD");
const [year, month, day] = dateStr.split("-").map(Number);
// JS getDay(): 0=周日 … 6=周六，转成以周一为 0 的索引
const jsDay = new Date(year, month - 1, day).getDay();
const weekday = WEEKDAYS_CN[(jsDay + 6) % 7];
const dateLabel = `${dateStr}（${weekday}）`;

const quarter = Math.ceil(month / 3);
const qName = `${year}-Q${quarter}`;
const qPath = `${folder}/${qName}.md`;

const templateFile = app.vault.getAbstractFileByPath(templatePath);
if (!templateFile) {
  new Notice("找不到 Daily Template.md，无法生成新的一天区块");
  tR = "";
} else {
  const raw = (await app.vault.read(templateFile)).replace(/\{\{date:YYYY-MM-DD\}\}/g, dateLabel);
  const fmMatch = raw.match(/^---\n[\s\S]*?\n---\n/);
  const frontmatter = fmMatch ? fmMatch[0] : "";
  const bodyStart = raw.indexOf("# ");
  const dayBody = raw.slice(bodyStart).trimEnd();

  let file = app.vault.getAbstractFileByPath(qPath);

  if (!file) {
    file = await app.vault.create(qPath, frontmatter + "\n" + dayBody + "\n");
  } else {
    const content = await app.vault.read(file);
    // 容错：只要有 H1 含今天日期就算已存在（兼容带不带「（周X）」的写法）
    const hasToday = content
      .split("\n")
      .some((l) => l.startsWith("# ") && l.includes(dateStr));
    if (!hasToday) {
      const qFmMatch = content.match(/^---\n[\s\S]*?\n---\n/);
      if (qFmMatch) {
        const fmEnd = qFmMatch[0].length;
        const rest = content.slice(fmEnd).replace(/^\n+/, "");
        const newContent =
          content.slice(0, fmEnd) + "\n" + dayBody + (rest ? "\n\n" + rest : "\n");
        await app.vault.modify(file, newContent);
      } else {
        await app.vault.modify(file, dayBody + "\n\n" + content);
      }
    }
  }

  await app.workspace.getLeaf(false).openFile(file);

  const editor = app.workspace.activeEditor?.editor;
  if (editor) {
    const lines = editor.getValue().split("\n");
    const idx = lines.findIndex((l) => l.startsWith("# ") && l.includes(dateStr));
    if (idx !== -1) editor.setCursor({ line: idx + 2, ch: 0 });
  }

  tR = "";
}
-%>
