Please create an Obsidian note using the video link and any available transcript or additional context. The note must include:

1. Frontmatter (at the top) with the following properties:

---

title: "{{video title - extract from YouTube Video Information section or transcript}}"

channel: "{{channel name if available, otherwise leave empty}}"

date_published: "{{video publication date if available in transcript or metadata, otherwise leave empty}}"

topics: ["{{relevant topic 1}}", "{{relevant topic 2}}"]

tags: ["youtube", "{{any other relevant tags based on content}}"]

summary: "{{short summary of the video's main theme and key takeaways}}"

---

2. A YouTube video embed in the following format (Obsidian will automatically embed the video):

![](https://www.youtube.com/watch?v=VIDEO_ID)

3. A **Channel** section: a `## Channel` heading followed by a single line containing the channel/uploader name (same value as the `channel` frontmatter field). If the channel is unknown, use `## Channel` with the text `Unknown` or omit the section.

4. A comprehensive, detailed summary of the key points from the video (below the Channel section).

**Instructions:**

- Extract the video title from the "YouTube Video Information" section if provided, or infer from the transcript content.

- Use the **Channel** line from the "YouTube Video Information" section when present. Set frontmatter `channel` and the body `## Channel` section to **exactly** that name (they must match). If no Channel line is present, leave `channel` empty and omit or minimalize the Channel section. Use **Date Published** for `date_published` when present.

- Extract topics by analyzing the main themes discussed in the transcript. Use 2-5 specific, relevant topics.

- Generate tags based on the video content. Always include "youtube" and add 2-4 additional relevant tags. Tags in frontmatter should NOT include the "#" symbol (only use "#" for inline tags in the content body). **CRITICAL: Tags must have NO spaces between words. Use hyphens or underscores to connect multi-word tags (e.g., "web-development" or "machine_learning", not "web development" or "machine learning").**

- Create a concise summary (1-2 sentences) that captures the video's main theme and key takeaways.

- If a full transcript is provided in the "Full Transcript" section, use it to create an accurate, detailed summary below the embed link.

- If "Date Published" is in the YouTube Video Information section, use it for `date_published`. Otherwise extract from transcript if mentioned, or leave empty.

- Maintain the exact markdown syntax for the frontmatter block (`---` at the top and bottom).

- Extract the video ID from the YouTube URL in the content, then create the embed using Obsidian's embed syntax:
  - Format: ![](https://www.youtube.com/watch?v=VIDEO_ID) (replace VIDEO_ID with the actual video ID)
  - This will automatically embed the YouTube video player in Obsidian

- In the main body, provide a comprehensive summary with bullet points covering all major points from the video transcript.

- **CRITICAL - NO SPONSOR CONTENT: Never include sponsor segments, promotional content, or ads in the summary or body. Exclude: "sponsored by", "use code X", "check out our sponsor", "this video is brought to you by", discount/promo codes, product plugs, and mid-roll ad segments. Summarize ONLY the main educational or informational content of the video. If the transcript contains sponsor blocks, skip them entirely—do not paraphrase or mention them.**

- Do not use ``` code blocks or markdown code formatting in the summary.

- Focus on accuracy and completeness based on the actual transcript content provided.

**Example Output Format:**

---

title: "How to Build a React App in 2024"

channel: "Tech Tutorials"

date_published: "2024-01-15"

topics: ["React", "Web Development", "JavaScript", "Tutorial"]

tags: ["youtube", "react", "webdev", "tutorial"]

summary: "A comprehensive guide to building modern React applications with hooks, context API, and best practices for 2024."

---

![](https://www.youtube.com/watch?v=VIDEO_ID)

## Channel

Tech Tutorials

## Detailed Summary

- Introduction to React fundamentals and modern development practices
- Setting up a new React project with Vite
- Using React Hooks for state management
- Implementing Context API for global state
- Best practices for component structure and organization
- Performance optimization techniques
- Deployment strategies and recommendations