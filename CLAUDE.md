# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Babel Reunited is a Discourse plugin that automatically translates forum posts to multiple languages using AI APIs (OpenAI, xAI/Grok, DeepSeek, or custom OpenAI-compatible endpoints). It hooks into post create/edit events, enqueues Sidekiq background jobs, and publishes results via MessageBus for real-time UI updates.

## Commands

This is a Discourse plugin — all commands run from the **Discourse root** (`/path/to/discourse`), not from the plugin directory.

```bash
# Run plugin Ruby tests
LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec

# Run a single spec file or line
LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec/path/to/file_spec.rb[:LINE]

# Run plugin JavaScript tests
bin/qunit plugins/babel-reunited

# Lint changed files
bin/lint plugins/babel-reunited/path/to/file

# Database migrations
bin/rails db:migrate

# Rake task: batch translate posts missing translations
bin/rake babel_reunited:process_missing_posts          # dry run (default)
DRY_RUN=false bin/rake babel_reunited:process_missing_posts  # actual execution
```

## Architecture

### Request Flow

1. `post_created`/`post_edited` events in `plugin.rb` → pre-create `PostTranslation` records with `translating` status → enqueue `TranslatePostJob` per language
2. `TranslatePostJob` calls `TranslationService` which handles API calls via Faraday, parses JSON responses with multi-tier fallback
3. On completion, job updates `PostTranslation` record status and publishes to MessageBus (`/post-translations/{post_id}`)
4. Frontend `language-tabs.gjs` connector subscribes to MessageBus and updates UI in real-time

### Key Backend Components

- **`plugin.rb`** — Event handlers (`post_created`, `post_edited`, `user_logged_in`), serializer extensions for Post/Topic/CurrentUser, model associations
- **`app/services/babel_reunited/translation_service.rb`** — Core translation logic: prompt building, API calls to providers, response parsing, rate limit checks, content length validation
- **`app/lib/babel_reunited/model_config.rb`** — Provider configuration registry mapping preset model names to API endpoints, token limits, and API keys
- **`lib/babel_reunited/post_extension.rb`** — Methods prepended onto `Post` model: `translate_to_language`, `get_translation`, `enqueue_translation_jobs`, `create_or_update_translation_record`
- **`lib/babel_reunited/rate_limiter.rb`** — Redis-based per-minute sliding window rate limiter
- **`app/jobs/regular/babel_reunited/translate_post_job.rb`** — Sidekiq job orchestrating the translation workflow

### Key Frontend Components

- **`connectors/before-post-article/language-tabs.gjs`** — Language switcher buttons on each post; handles MessageBus subscription, translation status display, and content switching
- **`components/modal/language-preference.gjs`** — First-login modal prompting users to pick their preferred language
- **`connectors/user-preferences-account/ai-translation-language.gjs`** — User preference panel for language/toggle settings
- **`services/translation-status.js`** — MessageBus-based real-time translation state management

### Data Model

- **`PostTranslation`** — `post_id`, `language`, `translated_content`, `translated_title`, `source_language`, `translation_provider`, `status` (translating/completed/failed), `metadata` (JSON). Indexed on `(post_id, language)`.
- **`UserPreferredLanguage`** — `user_id`, `language`, `enabled`. One per user.

### API Routes (mounted at `/babel-reunited`)

- `GET/POST /posts/:post_id/translations` — List/create translations
- `GET/DELETE /posts/:post_id/translations/:language` — Show/delete specific translation
- `GET /posts/:post_id/translations/translation_status` — Check translation status
- `GET/POST /user-preferred-language` — User preference endpoints
- `GET /admin` — Admin dashboard; `GET /admin/stats` — Statistics JSON

### Settings

All prefixed with `babel_reunited_` in `config/settings.yml`. Key settings: `enabled`, `preset_model`, provider API keys, `auto_translate_languages` (default: `zh-cn,en,es`), `translate_title`, `rate_limit_per_minute`, `max_content_length`, `request_timeout_seconds`.

### Namespacing

All Ruby code is under the `BabelReunited` module. The engine is mounted at `/babel-reunited`. Database tables: `post_translations`, `user_preferred_languages`.
