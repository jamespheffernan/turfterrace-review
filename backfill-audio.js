#!/usr/bin/env node
// One-off backfill: regenerate voice memos for pending review items
require('dotenv').config();

const Database = require('better-sqlite3');
const OpenAI = require('openai');
const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const { getCanonicalActions } = require('./lib/review-routing');

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const db = new Database(path.join(__dirname, 'data', 'reviews.db'));
const audioDir = path.join(__dirname, 'data', 'audio');
if (!fs.existsSync(audioDir)) fs.mkdirSync(audioDir, { recursive: true });

const items = db.prepare(`
  SELECT slug, title, markdown, category, actions, mindwtr_task_id, mindwtr_project_id FROM items 
  WHERE status = 'pending'
  ORDER BY created_at DESC
`).all();

console.log(`Found ${items.length} pending items to generate.\n`);

const updateStmt = db.prepare(`
  UPDATE items SET audio_path = @audio_path, audio_status = @audio_status, audio_summary = @audio_summary 
  WHERE slug = @slug
`);

function qmdSearch(query) {
  try {
    const out = execFileSync('/Users/username/.bun/bin/qmd', ['query', query, '-n', '3'], {
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Users/username/.bun/bin' },
      timeout: 15000,
      encoding: 'utf8',
    });
    const lines = out.split('\n');
    const resultStart = lines.findIndex(l => l.startsWith('qmd://') || l.startsWith('Title:') || l.startsWith('@@'));
    if (resultStart === -1) return '';
    return lines.slice(resultStart).join('\n').slice(0, 3000);
  } catch (e) {
    return '';
  }
}

async function generateOne(item, idx) {
  const label = `[${idx + 1}/${items.length}] ${item.title}`;
  
  if (!item.markdown || item.markdown.trim().length < 50) {
    console.log(`${label} — skipping (too short)`);
    updateStmt.run({ slug: item.slug, audio_path: null, audio_status: 'skipped', audio_summary: null });
    return;
  }

  try {
    // Project context from Turf Review
    let projectContext = '';
    if (item.mindwtr_task_id || item.mindwtr_project_id) {
      try {
        const related = db.prepare(`
          SELECT title, decision, feedback FROM items
          WHERE slug != ? AND (mindwtr_task_id = ? OR mindwtr_project_id = ?)
          ORDER BY created_at DESC LIMIT 5
        `).all(item.slug, item.mindwtr_task_id || '', item.mindwtr_project_id || '');
        if (related.length > 0) {
          projectContext = '\n\nPrevious related reviews:\n' + related.map(r =>
            `- "${r.title}" — ${r.decision ? `decided: ${r.decision}` : 'pending'}${r.feedback ? ` (feedback: ${r.feedback})` : ''}`
          ).join('\n');
        }
      } catch (e) { /* ignore */ }
    }

    // QMD memory search
    const qmdResults = qmdSearch(item.title);
    const memoryContext = qmdResults ? '\n\nRelevant context from memory/sessions/notes:\n' + qmdResults : '';

    const categoryContext = {
      kitchenlux: 'This is for KitchenLux, a premium kitchenware rental service for vacation rentals.',
      outreach: 'This is outreach material for KitchenLux — emails or DMs to property managers or influencers.',
      admin: 'This is an administrative or operational document.',
      general: '',
    }[item.category] || '';

    // Summarise with full context
    const summaryRes = await openai.chat.completions.create({
      model: 'gpt-4o-mini',
      messages: [
        {
          role: 'system',
          content: `You're briefing Jimmy (solo founder of KitchenLux) before he reviews a document. Structure your brief like this:

1. CONTEXT (1-2 sentences): What project/workstream this belongs to, where it fits, and any relevant history or prior decisions. Use the memory context provided to ground this. ${categoryContext}
2. ANALYSIS (3-5 sentences): Don't restate the document. Call out what's new vs previous versions, what decisions are needed, anything that looks off or worth flagging, and what the action buttons mean.

Keep it under 200 words total. Speak as if giving a quick verbal brief to a busy founder — conversational, direct, no bullet points, no markdown, no filler. Be opinionated where appropriate.`
        },
        { role: 'user', content: `Document title: ${item.title}\nCategory: ${item.category}\nActions available: ${item.actions || JSON.stringify(getCanonicalActions(item.category) || [])}${projectContext}${memoryContext}\n\n${item.markdown.slice(0, 8000)}` }
      ],
      max_tokens: 400,
      temperature: 0.7,
    });
    const summary = summaryRes.choices[0].message.content;

    // TTS — nova voice at 1.15x
    const speech = await openai.audio.speech.create({
      model: 'tts-1',
      voice: 'nova',
      speed: 1.15,
      input: summary,
      response_format: 'mp3',
    });
    const buffer = Buffer.from(await speech.arrayBuffer());
    const audioPath = `audio/${item.slug}.mp3`;
    fs.writeFileSync(path.join(__dirname, 'data', audioPath), buffer);

    updateStmt.run({ slug: item.slug, audio_path: audioPath, audio_status: 'ready', audio_summary: summary });
    console.log(`${label} ✅`);
  } catch (err) {
    console.error(`${label} ❌ ${err.message}`);
    updateStmt.run({ slug: item.slug, audio_path: null, audio_status: 'failed', audio_summary: null });
  }
}

(async () => {
  for (let i = 0; i < items.length; i++) {
    await generateOne(items[i], i);
  }
  console.log('\nDone.');
  db.close();
})();
