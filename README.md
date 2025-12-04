# Babel Reunited

> “Now the whole world had one language and a common speech… But the Lord said, ‘Come, let us go down and confuse their language so they will not understand each other.’”
> — Genesis 11:1–7

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/poshboytl/tuchuang/babel-reunited-readme.png" 
       alt="We are rebuilding the tower — not toward heaven, but toward understanding." 
       width="249">
</p>


Long ago, humanity dared to build a tower that reached toward the heavens. Unified in language and ambition, they worked as one—until their speech was scattered, and their understanding fractured. The Tower of Babel stood unfinished, not because they lacked tools, but because they no longer shared meaning.

Today, in the age of AI, we’re given a chance to reverse that fate.

**Babel Reunited is a plugin for [Discourse](https://www.discourse.org/), which is original built for [Nervos Talk](https://talk.nervos.org/). It allows every participant to write in their native language—and still be fully understood by others, in theirs. It’s an automatic translation layer powered by AI, designed not just to translate, but to restore something once lost: seamless, universal human dialogue.**

Whether you’re writing in Chinese, Spanish, or English, your message will be instantly translated for everyone in the forum, without needing to switch languages or rely on copy-paste tools. This is not just a convenience feature—it’s a philosophical one.

We are rebuilding the tower. Not toward heaven, but toward understanding.

---

- Plugin name: `babel-reunited`
- Minimum Discourse version: 2.7.0
- Repository: `https://github.com/Zealot-Rush/babel-reunited`

## Features
- Automatically translates posts after creation/edition to selected target languages (default: zh-cn, en, es; only these three are currently supported).
- Supports OpenAI, xAI (Grok), DeepSeek, or your own OpenAI-compatible API.
- Translated topic titles can appear in lists/details; translated post content can be shown and switched inline.
- Users can set a preferred language and toggle the feature; built‑in rate limiting and content length limits.

---

## Installation

```bash
cd /path/to/discourse/plugins
git clone https://github.com/Zealot-Rush/babel-reunited.git
```

### Production steps (non‑Docker)
1) Enter your Discourse root directory:
```bash
cd /path/to/discourse
```
2) Run database migrations (if the plugin includes any):
```bash
RAILS_ENV=production bin/rails db:migrate
```
3) Precompile frontend assets:
```bash
RAILS_ENV=production bin/rake assets:precompile
```

> For development/testing, usually restarting the Rails server and frontend dev process is enough—no precompilation necessary.

---

## Enable and Configure
1) In Discourse admin → Settings, search and enable:
- `babel_reunited_enabled`

2) Configure model and keys (fill in per your provider; leave unused ones blank):
- Preset model: `babel_reunited_preset_model` (default `gpt-4o`).
  - Options: `gpt-4o`, `gpt-4o-mini`, `gpt-3.5-turbo`, `grok-4`, `grok-3`, `grok-2`, `deepseek-r1`, `deepseek-v3`, `deepseek-v2`, `custom`
- Provider keys:
  - `babel_reunited_openai_api_key`
  - `babel_reunited_xai_api_key`
  - `babel_reunited_deepseek_api_key`
- Custom model (effective when preset is `custom`):
  - `babel_reunited_custom_model_name`
  - `babel_reunited_custom_base_url`
  - `babel_reunited_custom_api_key`
  - `babel_reunited_custom_max_tokens`
  - `babel_reunited_custom_max_output_tokens`

3) Translation policy:
- Auto translate languages: `babel_reunited_auto_translate_languages` (currently supports and defaults to `zh-cn,en,es`).
- Translate title: `babel_reunited_translate_title`
- Preserve formatting: `babel_reunited_preserve_formatting`
- Rate limit: `babel_reunited_rate_limit_per_minute`
- Max content length: `babel_reunited_max_content_length`

---

## Verifying the Installation
1) Create or edit a post:
- A “translating” record appears immediately for the target languages; the background job queues the AI translation.
- When done, translated content becomes available in‑post; if title translation is enabled and the first post’s translation is complete, topic lists/details can show the translated title.

2) If the user hasn’t set a preferred language on first login, a modal prompt is shown (triggered via MessageBus).

3) Logs (optional):

> Default log path used by the helper script is: `/discourse/log/babel_reunited_translation.log`. In production, adjust the script or create a symlink as needed.

---

## Rake Tasks

### `babel_reunited:process_missing_posts`

This rake task processes all posts that don't have any translations and adds translation jobs to Sidekiq for them.

**Usage:**

```bash
# DRY RUN mode (default, preview only - no jobs will be queued)
bin/rake babel_reunited:process_missing_posts
# or explicitly
DRY_RUN=true bin/rake babel_reunited:process_missing_posts

# Actual execution mode (queues translation jobs)
DRY_RUN=false bin/rake babel_reunited:process_missing_posts
```

**What it does:**

1. Finds all posts that have no translation records at all
2. Gets the auto-translate languages from `babel_reunited_auto_translate_languages` setting
3. For each post without translations:
   - Creates translation records with "translating" status
   - Enqueues translation jobs to Sidekiq for each target language

**Output:**

- **DRY RUN mode**: Shows the number of posts found, sample posts (first 10), and how many translation jobs would be queued
- **Actual execution**: Shows progress (every 100 posts), final statistics (processed count, failed count, queued jobs count)

**Requirements:**

- Plugin must be enabled (`babel_reunited_enabled` must be true)
- Auto-translate languages must be configured (`babel_reunited_auto_translate_languages` must not be blank)

**Example output (DRY RUN):**

```
Auto-translate languages: zh-cn, en, es

Found 1523 posts without any translations

DRY RUN mode - no jobs will be queued
Use DRY_RUN=false to actually queue translation jobs

Sample posts that would be processed:
  Post ID: 123, Topic ID: 45, User: alice
  Post ID: 124, Topic ID: 45, User: bob
  ... and 1521 more posts

Would queue 4569 translation jobs (1523 posts × 3 languages)
```

**Example output (Actual execution):**

```
Auto-translate languages: zh-cn, en, es

Found 1523 posts without any translations
Processing posts and queueing translation jobs...
Processed 100/1523 posts...
Processed 200/1523 posts...
...

==================================================
Processing complete
==================================================
Processed: 1523 posts
Failed: 0 posts
Queued: 4569 translation jobs
==================================================
```

---

## FAQ
- Translation didn’t trigger:
  - Is `babel_reunited_enabled` turned on?
  - Is the post non‑empty and within `babel_reunited_max_content_length`?
  - Is `babel_reunited_auto_translate_languages` at its default value?
  - Are the provider/API accessible, keys valid, and quota sufficient?
- Rate limiting: lower `rate_limit_per_minute`, reduce auto languages, or upgrade your API quota.
- Missing translated title: only shown when the first post’s translation exists and is complete; ensure `translate_title` is enabled.

---

## Uninstall (non‑Docker)
1) Remove the `plugins/babel-reunited` directory.
2) If needed, perform DB rollbacks/cleanup (backup first).
3) In production, re‑precompile assets and restart the app:
```bash
RAILS_ENV=production bin/rake assets:precompile
# restart your service
```

---

## Version Info
- Plugin version: `0.1.0`
- Compatibility: Discourse ≥ 2.7.0 (latest stable recommended)
