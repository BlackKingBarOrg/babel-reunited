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

- Automatic translation of posts on creation and edit, with configurable target languages (default: `zh-cn`, `en`, `es`)
- Optional category-level whitelist to limit which categories are translated
- Translated topic titles displayed in topic lists and topic detail pages
- Inline language tabs on each post for switching between translations
- Per-user language preference with opt-out toggle (prompted on first login)
- On-demand translation fallback when a translation is not yet available
- Multiple AI provider support: OpenAI, xAI (Grok), DeepSeek, or any OpenAI-compatible API
- Markdown formatting preservation during translation
- Redis-based per-minute rate limiting and content length limits
- Real-time translation status via MessageBus (translating / completed / failed)
- Preloaded translations to avoid N+1 queries on topic lists and topic views
- Admin panel for monitoring translation status
- Rake tasks for backfilling missing translations and re-translating legacy records

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

### 3. API keys

Provide the key for your chosen provider. Leave the others blank.

| Setting | Provider |
|---------|----------|
| `babel_reunited_openai_api_key` | OpenAI |
| `babel_reunited_xai_api_key` | xAI |
| `babel_reunited_deepseek_api_key` | DeepSeek |

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
| `babel_reunited_auto_translate_languages` | `zh-cn,en,es` | Comma-separated target language codes |
| `babel_reunited_enabled_categories` | (all) | Restrict translation to specific categories; blank means all |
| `babel_reunited_translate_title` | `true` | Translate topic titles (first post only) |
| `babel_reunited_preserve_formatting` | `true` | Preserve Markdown formatting in translations |
| `babel_reunited_rate_limit_per_minute` | `60` | Max translation requests per minute |
| `babel_reunited_max_content_length` | `4000` | Max post character length to translate |
| `babel_reunited_request_timeout_seconds` | `300` | Timeout for each provider API request |

---

## How It Works

1. When a post is created or edited, the plugin enqueues a Sidekiq job for each target language.
2. Each job acquires a Redis lock, calls the configured AI provider, and stores the result.
3. Translated content is cooked through Discourse’s `PrettyText` pipeline and sanitized before storage.
4. Translation status updates are pushed to the frontend via MessageBus in real time.
5. Users with a preferred language see translated titles in topic lists and can switch between language tabs on posts.

---

## Rake Tasks

All tasks run from the Discourse root. The plugin must be enabled and languages must be configured.

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

### `babel_reunited:migrate_user_preferences`

Migrates user language preferences from the legacy `user_preferred_languages` table to Discourse custom fields.

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

**Rate limiting**
- The plugin enforces a local per-minute rate limit (`babel_reunited_rate_limit_per_minute`). Reduce the number of target languages or increase the limit if translations are being throttled.

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

## Version

- Plugin version: `0.1.0`
- Requires Discourse >= 2.7.0
