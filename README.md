# Babel Reunited

> “Now the whole world had one language and a common speech… But the Lord said, ‘Come, let us go down and confuse their language so they will not understand each other.’”
> — Genesis 11:1–7

<p align="center">
  <img src="docs/babel-reunited-readme.png"
       alt="We are rebuilding the tower — not toward heaven, but toward understanding."
       width="249">
</p>

Long ago, humanity dared to build a tower that reached toward the heavens. Unified in language and ambition, they worked as one—until their speech was scattered, and their understanding fractured. The Tower of Babel stood unfinished, not because they lacked tools, but because they no longer shared meaning.

Today, in the age of AI, we’re given a chance to reverse that fate.

**Babel Reunited is a plugin for [Discourse](https://www.discourse.org/), originally built for [Nervos Talk](https://talk.nervos.org/). It allows every participant to write in their native language—and still be fully understood by others, in theirs. It’s an automatic translation layer powered by AI, designed not just to translate, but to restore something once lost: seamless, universal human dialogue.**

No matter what language you write in, your message will be instantly translated for everyone in the forum, without needing to switch languages or rely on copy-paste tools. This is not just a convenience feature—it’s a philosophical one.

We are rebuilding the tower. Not toward heaven, but toward understanding.

---

- Plugin name: `babel-reunited`
- Plugin version: `0.2.0`
- Requires Discourse: `2026.7.0` or newer
- Repository: <https://github.com/BlackKingBarOrg/babel-reunited>

Older sites are not left behind, but they must pin a commit rather than track
`master` — see [Installing on Discourse older than 2026.7](#installing-on-discourse-older-than-20267).

## Features

- Automatic translation of posts on creation and edit, with configurable target languages (default: `en`, `zh-cn`, `es`)
- Source-language detection, so a post is not translated into the language it is already written in
- Optional view-triggered mode: translate a post when someone actually reads it, instead of translating everything up front
- Optional category-level whitelist to limit which categories are translated
- Translated topic titles displayed in topic lists and topic detail pages
- Inline language tabs on each post for switching between translations
- Per-user language preference with opt-out toggle (prompted on first login, reachable afterwards from the globe button beside the header avatar)
- Any supported language on demand: readers pick from a searchable menu on the post, not just the pre-translated set, and the first request is cached and shared with everyone after it
- Multiple AI providers: OpenAI, Anthropic (Claude), OpenRouter, Google (Gemini), xAI (Grok), DeepSeek, or any OpenAI-compatible endpoint, with the model named as free text
- Markdown formatting preservation during translation
- Redis-based per-minute rate limiting, content length limits, and daily fuses on reader-initiated translation
- Real-time translation status via MessageBus (translating / completed / failed)
- Preloaded translations to avoid N+1 queries on topic lists and topic views
- Admin panel for monitoring translation status
- Rake tasks for backfilling, re-cooking, auditing and cleaning up translation records

---

## Installation

### Docker (recommended)

Most production Discourse instances run inside Docker. To install:

1) Open your container config (usually `/var/discourse/containers/app.yml`).
2) Add the plugin's git clone command to the `after_code` hook:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/BlackKingBarOrg/babel-reunited.git  # <-- add this line
```

3) Rebuild the container:

```bash
cd /var/discourse
./launcher rebuild app
```

The rebuild process will clone the plugin, run migrations, and precompile assets automatically.

> **Updating**: To pull the latest version, simply run `./launcher rebuild app` again. The rebuild always fetches the newest code from the repository.

### Non-Docker (development / bare-metal)

1) Clone the plugin into your Discourse plugins directory:

```bash
cd /path/to/discourse/plugins
git clone https://github.com/BlackKingBarOrg/babel-reunited.git
```

2) Run database migrations and precompile assets:

```bash
cd /path/to/discourse
RAILS_ENV=production bin/rails db:migrate
RAILS_ENV=production bin/rake assets:precompile
# then restart your application server
```

> For local development, just restart the Rails server — no precompilation necessary.

### Installing on Discourse older than 2026.7

`master` depends on core's `PostCookedHtml` component and the ui-kit module paths
introduced by the 2026.7 lint migration, so it will not run on older cores.
Those sites pin the last compatible commit, which is what
[`.discourse-compatibility`](.discourse-compatibility) records — use these in
place of the plain clone line in the `after_code` hook above:

```yaml
- git clone --single-branch https://github.com/BlackKingBarOrg/babel-reunited.git
- cd babel-reunited && git checkout 11c9c7d464abc3912de7b09a2bd82a6926e70609
```

---

## Configuration

All settings are under Admin > Settings, prefixed with `babel_reunited_`.

### 1. Enable the plugin

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_enabled` | `false` | Master switch for the plugin |

### 2. Choose a provider and a model

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_provider` | `openai` | Which provider to send translation requests to |
| `babel_reunited_model` | `gpt-4o` | Model identifier, exactly as the provider names it |

| Provider | Endpoint | Model names look like |
|----------|----------|-----------------------|
| `openai` | `https://api.openai.com` | `gpt-4o`, `gpt-5-mini` |
| `anthropic` | `https://api.anthropic.com` | `claude-sonnet-4-6` |
| `openrouter` | `https://openrouter.ai` | `anthropic/claude-sonnet-4-6` |
| `google` | `https://generativelanguage.googleapis.com` | `gemini-2.5-flash` |
| `xai` | `https://api.x.ai` | `grok-4.6` |
| `deepseek` | `https://api.deepseek.com` | `deepseek-v4-flash` |
| `openai_compatible` | yours, see below | whatever your endpoint serves |

The model is free text rather than a list, because any list of models here
goes stale — and a gateway like OpenRouter fronts hundreds of them. Check
your provider's own model catalogue for the current names.

Two request parameters are guessed from the model's name: whether it takes
`max_tokens` or `max_completion_tokens`, and whether it accepts a
`temperature`. If a model rejects the guess, the request is sent once more
with the other form and the swap is written to the logs, so an unfamiliar
model name is not a dead end.

### 3. API keys

Provide the key for your chosen provider. Leave the others blank; they are
kept so switching providers does not mean re-entering them.

| Setting | Provider |
|---------|----------|
| `babel_reunited_openai_api_key` | OpenAI |
| `babel_reunited_anthropic_api_key` | Anthropic |
| `babel_reunited_openrouter_api_key` | OpenRouter |
| `babel_reunited_google_api_key` | Google |
| `babel_reunited_xai_api_key` | xAI |
| `babel_reunited_deepseek_api_key` | DeepSeek |
| `babel_reunited_custom_api_key` | `openai_compatible` |

### 4. Your own endpoint (when the provider is `openai_compatible`)

Anything that speaks the OpenAI chat-completions format, including a model
running on your own hardware.

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_custom_base_url` | | Base URL, with or without a trailing `/v1` |
| `babel_reunited_custom_api_key` | | API key, if the endpoint wants one. Leave blank for a local model with no authentication |

`https://example.com`, `https://example.com/`, `https://example.com/v1` and
`https://example.com/v1/chat/completions` all name the same endpoint.

This is the one provider that runs without an API key, because a model on
your own hardware usually has no authentication to configure. Every hosted
provider still requires one.

### 5. Token limits

These apply to every provider. Both start from whatever the old preset used,
so an upgrade does not change how much is asked for or how finely posts are
split; check them if you later change model.

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_max_output_tokens` | `16000` | Requested per provider call. Lower it if your model rejects the request |
| `babel_reunited_chunk_size` | `16000` | Characters per chunk when splitting a long post |

### 6. Translation behavior

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_auto_translate_languages` | `en,zh-cn,es` | Comma-separated target language codes |
| `babel_reunited_enabled_categories` | (all) | Restrict translation to specific categories; blank means all |
| `babel_reunited_translate_title` | `true` | Translate topic titles (first post only) |
| `babel_reunited_preserve_formatting` | `true` | Preserve Markdown formatting in translations |
| `babel_reunited_rate_limit_per_minute` | `60` | Max provider API calls per minute, shared by detection, title translation and each content chunk — one post can spend several |
| `babel_reunited_max_content_length` | `200000` | Cost cap on how long a post may be to translate, in characters. The hard ceiling is 5 chunks of `babel_reunited_chunk_size` |
| `babel_reunited_request_timeout_seconds` | `300` | Timeout for each provider API request |
| `babel_reunited_modal_description` | | Replaces the default copy in the first-login language modal |

### 7. Daily fuses on reader-initiated translation

Readers can ask for a translation that does not exist yet — from the language
tabs on a post, and again automatically if view-triggered translation is on.
Two daily counters bound that lane, independently of the per-minute rate limit.
They are circuit breakers rather than budgets: the defaults sit far above
organic traffic and only bite during an attack or a client bug, and staff are
exempt.

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_daily_translation_limit` | `10000` | Site-wide reader-initiated translations per day; `0` disables the fuse |
| `babel_reunited_user_daily_translation_limit` | `500` | Per-user reader-initiated translations per day; `0` disables the fuse |

Automatic translation of new and edited posts does not charge either fuse — the
setting that bounds its cost is the number of target languages in
`babel_reunited_auto_translate_languages`.

Both are Redis counters keyed by date, so the count starts fresh each day. The
per-user fuse is charged first, so a user already over their own limit cannot
spend site quota to find that out. A tripped fuse writes a warning to the Rails
log.

### 8. View-triggered translation

Off by default, in which case every post is translated up front. Turned on, a
translation is requested when a reader actually dwells on the post — which
trades a little latency on first read for not paying to translate posts nobody
opens.

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_view_triggered_translation` | `false` | Translate on read instead of eagerly |
| `babel_reunited_view_trigger_min_trust_level` | `0` | Minimum trust level allowed to trigger a translation by reading |

---

## How It Works

1. When a post is created or edited, the plugin enqueues a language-detection job.
2. Detection records the post's source language — including an explicit "undetermined" result, so the same post is not re-detected forever — and then fans out one translation job per target language. If detection cannot run, it fans out to every configured language rather than stalling.
3. Each translation job acquires a Redis lock, charges the per-minute rate limit, calls the configured AI provider, and stores the result.
4. Translated content is cooked through Discourse’s `PrettyText` pipeline and sanitized before storage.
5. Translation status updates are pushed to the frontend via MessageBus in real time.
6. Users with a preferred language see translated titles in topic lists and can switch between language tabs on posts.
7. A translation into the post's own language never reaches a reader, even when such a record exists: the language tabs and every path that serves a body filter against the detected source language.
8. A translation only reaches a reader while it is still a translation of what the post currently says. Every path that serves a body compares the translation's stored fingerprint against the post's current content, so an edit hides the translation until it is redone — the edit that matters is a redaction, and no length or structure test can see one. Existing rows that predate this check are found by `backfill_stale_translations`.

---

## What Leaves Your Site, and What It Costs

Read this before enabling the plugin on a forum you do not own outright.

**Post content is sent to a third party.** Translating a post means sending its
body, and its title when `babel_reunited_translate_title` is on, to whichever
provider you configured. Detection sends a sample of up to 400 characters.
Code blocks, inline code, BBCode `[code]` / `[quote]` / `[details]`, URLs and
`upload://` attachment references are stripped before that sample is built, so
pasted keys and logs inside those blocks do not travel — but ordinary prose
does, verbatim.

The provider is yours to choose and yours to vet. Check its data-retention and
training policy, and whether an enterprise or zero-retention tier is available,
before pointing this at private categories. `babel_reunited_enabled_categories`
is the tool for keeping a category out of it entirely.

**Cost scales with posts × target languages.** Every new post in an enabled
category is fanned out to each language in
`babel_reunited_auto_translate_languages`, so adding a fourth language adds
roughly a third to the automatic bill. A long post is split into as many as 5
chunks, each its own call, plus one for the title and one for detection.

Reader-initiated translations are the other lane, bounded by the daily fuses
described above rather than by the language list. Turning on
`babel_reunited_view_triggered_translation` trades the up-front fan-out for
paying only for posts somebody actually reads, which is cheaper on a forum
where most posts go unread in most languages.

There is no spend cap. The per-minute limit bounds the rate, the daily fuses
bound abuse; neither is a budget. Watch the provider's own usage dashboard.

## Supported Languages

126 language codes are accepted, of which 110 are offered in the reader's
language menu — regional variants that translate identically to their base
language stay valid for existing data but are not offered again. The list is
defined in
[`lib/babel_reunited/locales.rb`](lib/babel_reunited/locales.rb) and mirrored
for the frontend in
[`assets/javascripts/discourse/lib/babel-locales.js`](assets/javascripts/discourse/lib/babel-locales.js);
a spec keeps the two in sync.

## Rake Tasks

All tasks run from the Discourse root. The plugin must be enabled and languages must be configured.

Most tasks that write anything default to a preview and print what they *would*
do; pass `DRY_RUN=false` to let them act. Two exceptions take no such flag: the
audit tasks are read-only, and `migrate_user_preferences` has no preview mode
and writes as soon as it is invoked.

### `babel_reunited:process_missing_posts`

Finds posts without any translation records and enqueues translation jobs.

```bash
# Preview (default, no jobs queued)
bin/rake babel_reunited:process_missing_posts

# Execute
DRY_RUN=false bin/rake babel_reunited:process_missing_posts
```

### `babel_reunited:retranslate_legacy`

Re-translates completed records that are missing the `translated_raw` field (from before that column was added).

```bash
# Preview
bin/rake babel_reunited:retranslate_legacy

# Execute
DRY_RUN=false bin/rake babel_reunited:retranslate_legacy
```

### `babel_reunited:recook_translations`

Re-runs stored translations through the current cooking pipeline, for when core's
`PrettyText` output changes. Prints the last handled id so a long run can be
resumed with `START_ID`.

```bash
# Preview
bin/rake babel_reunited:recook_translations

# Execute, resuming from where a previous run stopped
DRY_RUN=false START_ID=12345 bin/rake babel_reunited:recook_translations
```

### `babel_reunited:backfill_detected_locales`

Detects the source language of posts that predate language detection. Run this to
completion — until it reports zero posts still needing detection — before running
`cleanup_same_language_copies`, which depends on its results.

Unlike the other tasks, this one calls the provider itself rather than queueing
jobs, so it holds the terminal for the length of the run: roughly an hour per
1800 posts at the default pace. Use `tmux` or `screen`.

```bash
# Survey: read-only, sends nothing, prints the five buckets and the total
bin/rake babel_reunited:backfill_detected_locales

# A cautious first pass
DRY_RUN=false LIMIT=20 bin/rake babel_reunited:backfill_detected_locales

# The full run, paced at half the site rate limit unless PER_MINUTE says otherwise
DRY_RUN=false bin/rake babel_reunited:backfill_detected_locales
```

Notes for a long run:

- **Run one at a time.** A second process cannot exceed the site rate limit, but
  it will detect the same posts twice and pay twice.
- **Interrupting is safe.** Ctrl-C stops it cleanly, every result already
  recorded stays recorded, and re-running resumes from the database.
- **The switch is the brake.** Turning off `babel_reunited_enabled` stops the run
  before the next post is sent. Lowering `babel_reunited_rate_limit_per_minute`
  takes effect on the next post too.
- **An idle Sidekiq queue is not the finish line** — there is no queue. Re-run
  the survey until `still needing detection` reads 0. Posts under
  `Failed, left for a re-run` recorded nothing and are picked up by re-running;
  `answered as no supported language` is a recorded answer, not a failure.

### `babel_reunited:cleanup_same_language_copies`

Deletes translation records whose target language is the post's own detected
language — the original already covers that language. Only records that are
provably redundant are touched.

This is housekeeping rather than a fix: step 7 of [How It Works](#how-it-works)
means such records stop being offered to readers the moment detection lands on
the post. Run `backfill_detected_locales` to completion first, then run this
whenever it suits.

```bash
# Preview
bin/rake babel_reunited:cleanup_same_language_copies

# Execute
DRY_RUN=false bin/rake babel_reunited:cleanup_same_language_copies
```

### `babel_reunited:backfill_stale_translations`

Finds completed translations whose stored fingerprint no longer matches their
post, and marks them stale.

Readers stop seeing those bodies the moment this release is deployed — the
display guard compares the fingerprint itself rather than trusting the status.
What this task adds is that the record then says so, which is what makes the
rows eligible to be redone: nothing re-translates a row that still claims to
be completed.

Run it once after deploying. It is the historical rows that need it: edits
made since edit-time invalidation shipped have been handled all along, but
nothing ever revisited what came before. On one production copy that was 1453
of 4548 completed rows.

```bash
# Preview
bin/rake babel_reunited:backfill_stale_translations

# Mark them stale
DRY_RUN=false bin/rake babel_reunited:backfill_stale_translations

# Mark them stale and queue the re-translations, a batch at a time
DRY_RUN=false ENQUEUE=true LIMIT=200 bin/rake babel_reunited:backfill_stale_translations
```

Without `ENQUEUE=true` the rows are withheld but nothing redoes them, unless
`babel_reunited_view_triggered_translation` is on, in which case a reader
opening the post triggers it. Each queued job is a provider call, so `LIMIT`
is how you keep the bill and the rate limiter in view.

### `babel_reunited:scan_translation_anomalies`

Read-only. Compares each stored translation's structure against its source and
flags the ones that drifted.

**The output is a heuristic and needs human judgement — do not delete from it
directly.** It used to be mostly noise: bilingual originals, normal length
differences between scripts and harmless formatting changes all registered as
drift. Those three causes are handled now
([#33](https://github.com/BlackKingBarOrg/babel-reunited/issues/33)), which on
a production copy took the flagged count from 72 of 4546 records down to 16.
It is still a heuristic. Read the flagged records before deciding to
re-translate or delete any of them.

```bash
bin/rake babel_reunited:scan_translation_anomalies
```

### `babel_reunited:audit_language_codes`

Read-only. Reports translation records whose language code is outside the
supported list — those codes can no longer be requested.

```bash
bin/rake babel_reunited:audit_language_codes
```

### `babel_reunited:migrate_user_preferences`

Migrates user language preferences from the legacy `user_preferred_languages` table to Discourse custom fields.

There is no preview mode here — this one writes on the first run.

```bash
bin/rake babel_reunited:migrate_user_preferences
```

---

## Troubleshooting

**Translation not triggering**
- Verify `babel_reunited_enabled` is on.
- Check that the post’s category is in `babel_reunited_enabled_categories` (or that the setting is blank for all categories).
- Confirm the post is non-empty and within `babel_reunited_max_content_length`.
- Ensure the provider API key is set and the API is reachable.
- If `babel_reunited_view_triggered_translation` is on, nothing is translated until someone reads the post — and readers below `babel_reunited_view_trigger_min_trust_level` cannot trigger one.

**Rate limiting**
- The plugin enforces a local per-minute rate limit (`babel_reunited_rate_limit_per_minute`). Reduce the number of target languages or increase the limit if translations are being throttled.

**Readers are told the daily translation limit is reached**
- A daily fuse has tripped, so requests from the language tabs (and view-triggered ones) are rejected until the next day. Posts created or edited from now on still translate automatically — the fuses do not cover that lane. Look for `daily translation fuse tripped` in the Rails log: it names which fuse and shows the count against the limit. Raise `babel_reunited_daily_translation_limit` or `babel_reunited_user_daily_translation_limit`, or set the offending one to `0` to disable it.

**Translated title not showing**
- Title translation only applies to the first post of a topic.
- Confirm `babel_reunited_translate_title` is enabled.
- The user must have a preferred language set.

**Translation logs**
- Structured logs are written to `log/babel_reunited_translation.log` in the Discourse root.

---

## Uninstall

### Docker

1) Remove the `git clone` line for `babel-reunited` from `app.yml`.
2) Rebuild the container:

```bash
cd /var/discourse
./launcher rebuild app
```

### Non-Docker

1) Remove the `plugins/babel-reunited` directory.
2) Re-precompile assets and restart:

```bash
RAILS_ENV=production bin/rake assets:precompile
# restart your service
```

> Plugin tables (`babel_reunited_*`) will remain in the database after uninstall. To remove them, back up first, then drop manually.

---

## License

Copyright (C) 2026 BKBLAB. Licensed under [GPL-2.0](LICENSE), the same license
as Discourse core.
