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
- Plugin version: `0.1.0`
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
- Per-user language preference with opt-out toggle (prompted on first login)
- On-demand translation fallback when a translation is not yet available
- Multiple AI provider support: OpenAI, xAI (Grok), DeepSeek, Anthropic (Claude), or any OpenAI-compatible API
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

### 2. Choose a model

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_preset_model` | `gpt-4o` | Select a preset model or `custom` |

Available presets:

| Provider | Models |
|----------|--------|
| OpenAI | `gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `gpt-4o`, `gpt-4o-mini`, `gpt-3.5-turbo` |
| xAI | `grok-4`, `grok-4-fast-non-reasoning`, `grok-3`, `grok-2` |
| DeepSeek | `deepseek-r1`, `deepseek-v3` |
| Anthropic | `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5` |

### 3. API keys

Provide the key for your chosen provider. Leave the others blank.

| Setting | Provider |
|---------|----------|
| `babel_reunited_openai_api_key` | OpenAI |
| `babel_reunited_xai_api_key` | xAI |
| `babel_reunited_deepseek_api_key` | DeepSeek |
| `babel_reunited_anthropic_api_key` | Anthropic |

### 4. Custom model (when preset is `custom`)

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_custom_model_name` | | Model identifier |
| `babel_reunited_custom_base_url` | | OpenAI-compatible API base URL |
| `babel_reunited_custom_api_key` | | API key for the custom endpoint |
| `babel_reunited_custom_max_tokens` | `16000` | Max input tokens |
| `babel_reunited_custom_max_output_tokens` | `4096` | Max output tokens |

### 5. Translation behavior

| Setting | Default | Description |
|---------|---------|-------------|
| `babel_reunited_auto_translate_languages` | `en,zh-cn,es` | Comma-separated target language codes |
| `babel_reunited_enabled_categories` | (all) | Restrict translation to specific categories; blank means all |
| `babel_reunited_translate_title` | `true` | Translate topic titles (first post only) |
| `babel_reunited_preserve_formatting` | `true` | Preserve Markdown formatting in translations |
| `babel_reunited_rate_limit_per_minute` | `60` | Max translation requests per minute |
| `babel_reunited_max_content_length` | `4000` | Max post length to translate |
| `babel_reunited_request_timeout_seconds` | `300` | Timeout for each provider API request |
| `babel_reunited_modal_description` | | Replaces the default copy in the first-login language modal |

### 6. Daily fuses on reader-initiated translation

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

### 7. View-triggered translation

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

---

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

```bash
# Preview
bin/rake babel_reunited:backfill_detected_locales

# Execute
DRY_RUN=false bin/rake babel_reunited:backfill_detected_locales
```

### `babel_reunited:cleanup_same_language_copies`

Deletes translation records whose target language is the post's own detected
language — the original already covers that language. Only records that are
provably redundant are touched.

```bash
# Preview
bin/rake babel_reunited:cleanup_same_language_copies

# Execute
DRY_RUN=false bin/rake babel_reunited:cleanup_same_language_copies
```

### `babel_reunited:scan_translation_anomalies`

Read-only. Flags stored translations that look wrong, so they can be
re-translated or deleted.

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
