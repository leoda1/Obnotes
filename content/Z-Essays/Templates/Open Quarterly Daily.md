<%*
// 打开「当前季度」日记：不存在则创建，本周的区块不存在则插到最上面，然后跳转过去。
// 一周一个区块，标题 "# YYYY-MM-DD（周一） 至 YYYY-MM-DD（周日）"，归属周一所在的季度文件。
// 逻辑与 ~/.claude/skills/obsidian-daily/daily.py 保持一致，都以
// Z-Essays/Templates/Daily Template.md 为唯一模板来源。
const folder = "Z-Essays/Daily";
const templatePath = "Z-Essays/Templates/Daily Template.md";

const pad = (n) => String(n).padStart(2, "0");
const fmt = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

const [year, month, day] = tp.date.now("YYYY-MM-DD").split("-").map(Number);
const today = new Date(year, month - 1, day);
// JS getDay(): 0=周日 … 6=周六，转成以周一为 0 的偏移
const monday = new Date(year, month - 1, day - ((today.getDay() + 6) % 7));
const sunday = new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + 6);
const mondayStr = fmt(monday);
const weekLabel = `${mondayStr}（周一） 至 ${fmt(sunday)}（周日）`;

// 跨季度的那一周归属周一所在季度
const qName = `${monday.getFullYear()}-Q${Math.ceil((monday.getMonth() + 1) / 3)}`;
const qPath = `${folder}/${qName}.md`;

// 本周区块：H1 含周一日期且含「至」（旧的单日区块 "# YYYY-MM-DD（周X） Daily" 不算）
const isThisWeek = (l) => l.startsWith("# ") && l.includes(mondayStr) && l.includes("至");

const templateFile = app.vault.getAbstractFileByPath(templatePath);
if (!templateFile) {
  new Notice("找不到 Daily Template.md，无法生成本周区块");
  tR = "";
} else {
  const raw = (await app.vault.read(templateFile)).replace(/\{\{date:YYYY-MM-DD\}\}/g, weekLabel);
  const fmMatch = raw.match(/^---\n[\s\S]*?\n---\n/);
  const frontmatter = fmMatch ? fmMatch[0] : "";
  const bodyStart = raw.indexOf("# ");
  const weekBody = raw.slice(bodyStart).trimEnd();

  let file = app.vault.getAbstractFileByPath(qPath);

  if (!file) {
    file = await app.vault.create(qPath, frontmatter + "\n" + weekBody + "\n");
  } else {
    const content = await app.vault.read(file);
    if (!content.split("\n").some(isThisWeek)) {
      const qFmMatch = content.match(/^---\n[\s\S]*?\n---\n/);
      if (qFmMatch) {
        const fmEnd = qFmMatch[0].length;
        const rest = content.slice(fmEnd).replace(/^\n+/, "");
        const newContent =
          content.slice(0, fmEnd) + "\n" + weekBody + (rest ? "\n\n" + rest : "\n");
        await app.vault.modify(file, newContent);
      } else {
        await app.vault.modify(file, weekBody + "\n\n" + content);
      }
    }
  }

  await app.workspace.getLeaf(false).openFile(file);

  const editor = app.workspace.activeEditor?.editor;
  if (editor) {
    const lines = editor.getValue().split("\n");
    const idx = lines.findIndex(isThisWeek);
    if (idx !== -1) editor.setCursor({ line: idx + 2, ch: 0 });
  }

  tR = "";
}
-%>
