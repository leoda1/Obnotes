Please create an Obsidian note with interactive flashcards using native Obsidian HTML features. The note must include:

1. Frontmatter (at the top) with the following properties:

---

total: {{number of flashcards created}}

topics: ["{{topic 1}}", "{{topic 2}}", "{{topic 3}}"]

created: "{{current date in YYYY-MM-DD format}}"

---

2. Interactive flashcards using HTML details/summary tags (below the frontmatter).

**Instructions:**

- Extract key concepts, facts, definitions, relationships, and important information from the content
- Identify all testable knowledge points: definitions, concepts, facts, formulas, relationships, processes, dates, names, theories, principles, etc.
- Extract 3-7 main topics or themes from the content for the topics array in frontmatter
- **CRITICAL: Randomize the order of flashcards - mix different topics, difficulty levels, and question types together. Do NOT follow the original content order or group by topic. Create a varied, shuffled study experience.**
- Create 10-30 flashcards depending on content length and density
- Prioritize information that is:
  - Fundamental to understanding the topic
  - Frequently referenced or important
  - Easy to forget (dates, numbers, specific details)
  - Part of a sequence or process
  - A definition or key concept

- Maintain the exact markdown syntax for the frontmatter block (`---` at the top and bottom).
- Each property in frontmatter must be on its own line with proper YAML indentation
- Topics should be an array: topics: ["Topic 1", "Topic 2", "Topic 3"]
- Total should be a number without quotes
- Created should be a string in quotes with format "YYYY-MM-DD"

- Format each flashcard using HTML details/summary tags:
  - Each flashcard must be a separate <details> block with class="flashcard"
  - The <summary> tag must have class="flashcard-question" and contain the question
  - The answer must be wrapped in <div class="flashcard-answer">
  - Leave a blank line after </summary> and before </details> for proper spacing
  - Answers can include markdown formatting (bold, italic, lists, links, etc.)
  - Answers can span multiple paragraphs

- Questions should test understanding, not just recall
- Answers should be complete but concise (typically 1-4 sentences, but can be longer if needed)
- Include context and examples when helpful
- Use clear, specific language
- Make questions specific and focused (avoid overly broad questions)
- Include [[internal links]] to related notes or concepts when relevant
- Use **bold** for key terms in answers
- Group related information in answers using lists or structured formatting

- Do not use ``` code blocks or markdown code formatting in the output
- Focus on accuracy and completeness based on the actual content provided

**Example Output Format:**

---

total: 3

topics: ["Cell Biology", "Energy Production", "Molecular Biology"]

created: "2025-01-09"

---

<details class="flashcard">
<summary class="flashcard-question">What is the primary function of mitochondria?</summary>

<div class="flashcard-answer">

Mitochondria are organelles that produce ATP (adenosine triphosphate) through cellular respiration. They are often called the "powerhouse of the cell" because they generate most of the cell's energy supply.

Related: See also [[Chloroplasts]] for plant cell energy production.

</div>

</details>

<details class="flashcard">
<summary class="flashcard-question">What is the difference between DNA and RNA?</summary>

<div class="flashcard-answer">

- **DNA**: Double-stranded, contains thymine, stores genetic information
- **RNA**: Single-stranded, contains uracil, involved in protein synthesis

</div>

</details>

<details class="flashcard">
<summary class="flashcard-question">How does photosynthesis work?</summary>

<div class="flashcard-answer">

Photosynthesis occurs in two stages:

1. **Light-dependent reactions**: Chlorophyll absorbs light energy, splits water molecules, and produces ATP and NADPH
2. **Calvin cycle**: Uses ATP and NADPH to convert carbon dioxide into glucose

</div>

</details>

Important Notes:
- ALWAYS include frontmatter with total, topics, and created date
- Each property in frontmatter must be on its own line (no nesting, flat structure like the YouTube template)
- Topics should be an array: topics: ["Topic 1", "Topic 2", "Topic 3"]
- Created should be a string in quotes: created: "2025-01-09"
- Total should be a number without quotes: total: 15
- Use proper HTML syntax - ensure all tags are properly closed
- Output the actual HTML tags directly (NOT inside markdown code blocks)
- Each flashcard should be separated by a blank line for readability
- **RANDOMIZE THE ORDER: Mix topics, difficulty levels, and question types - do not follow source material order**
- Include [[internal links]] to related concepts when relevant
- Answers can include markdown formatting like **bold**, *italic*, lists, and [[internal links]]
- If content is very long, focus on the most important concepts
- If content is technical, ensure definitions are clear
- Maintain the original meaning and accuracy of the source material
- All flashcards will be in one note - users can click to reveal answers
- This format works natively in Obsidian without requiring any plugins