# AGENTS.md
Guidance for coding agents working in `plugins/babel-reunited`.

## Purpose
This plugin auto-translates Discourse posts using AI providers.
It includes Ruby backend code, Ember/Glimmer frontend code, migrations, and locale files.
Use this document as the operational and style baseline for all changes.

## Repository Facts
- Plugin path: `plugins/babel-reunited`
- Runtime host app: Discourse
- Engine mount path: `/babel-reunited`
- Main Ruby namespace: `BabelReunited`
- Main entrypoint: `plugin.rb`

## Rule Sources (Checked)
- `CLAUDE.md` exists and is authoritative for architecture + commands.
- `.cursorrules` not found in this repository.
- `.cursor/rules/` not found in this repository.
- `.github/copilot-instructions.md` not found in this repository.
If Cursor/Copilot rule files are added later, merge them here and follow the stricter rule on conflicts.

## Working Directory Rules
Most commands must run from **Discourse root**, not this plugin directory.
Expected root example: `/path/to/discourse`
Use plugin-relative paths in commands: `plugins/babel-reunited/...`

## Build / Test / Lint Commands
Run these from Discourse root.

### Ruby Specs
- Run all plugin specs:
  `LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec`
- Run a single spec file:
  `LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec/path/to/file_spec.rb`
- Run a single spec at line (preferred focused run):
  `LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec/path/to/file_spec.rb:123`

### JavaScript Tests
- Run plugin JS tests:
  `bin/qunit plugins/babel-reunited`

### Lint
- Lint one changed file:
  `bin/lint plugins/babel-reunited/path/to/file`

### Database and Tasks
- Run migrations:
  `bin/rails db:migrate`
- Process missing translations (dry run by default):
  `bin/rake babel_reunited:process_missing_posts`
- Process missing translations (actual enqueue):
  `DRY_RUN=false bin/rake babel_reunited:process_missing_posts`

## Agent Execution Checklist
1. Read `CLAUDE.md` before non-trivial edits.
2. Classify change: backend, frontend, or both.
3. Prefer minimal diffs and avoid unrelated cleanup.
4. Run focused tests/lint for touched areas.
5. If no tests exist, validate behavior path and call out the gap.
6. Never commit secrets or provider keys.

## Architecture Landmarks
- Event wiring and serializer extension: `plugin.rb`
- Translation job orchestration: `app/jobs/regular/babel_reunited/translate_post_job.rb`
- Provider API integration: `app/services/babel_reunited/translation_service.rb`
- Provider registry/config: `app/lib/babel_reunited/model_config.rb`
- Post model extension: `lib/babel_reunited/post_extension.rb`
- Translation state UI: `assets/javascripts/discourse/connectors/before-post-article/language-tabs.gjs`

## Ruby Style Guide
- Keep `# frozen_string_literal: true` at top of Ruby files.
- Keep plugin code in `BabelReunited` unless Discourse requires global names (for example jobs).
- Use 2-space indentation; no tabs.
- Prefer guard clauses and early returns.
- Prefer small private helpers over deep nested conditionals.
- Naming: `snake_case` methods/vars, `CamelCase` classes/modules, `UPPER_SNAKE_CASE` constants.
- Prefer symbol keys for internal hashes unless external payload contracts require strings.
- Use Rails idioms consistently: `present?`, `blank?`, `find_by`, scoped relations.
- Keep controller actions thin; push business logic into service/model/job layers.
- Use bang methods (`create!`, `update!`) when failures should be explicit and handled.
- Keep DB queries explicit and avoid N+1 access patterns.

## Ruby Requires and File Loading
- In `plugin.rb`, use `require_relative` for plugin files.
- Use `require` for gems/stdlib (`faraday`, `json`, etc.).
- Group requires near file top and remove unused requires.

## Error Handling (Ruby)
- Validate inputs at boundaries (controller params, service entry points, job args).
- Fail fast with clear messages for invalid arguments.
- Rescue narrowly when possible.
- If broad rescue is needed, log context-rich details (`post_id`, `target_language`, phase).
- Keep rescue blocks side-effect safe.
- Return structured error objects where service pattern expects it.
- Only use silent rescue for explicitly best-effort code, and document intent inline.

## Frontend Style Guide (Ember / GJS)
- Use class-based Glimmer components with decorators (`@service`, `@tracked`, `@action`).
- Use 2-space indentation and semicolons.
- Keep tracked state minimal and derive display state via getters.
- Extract repeated conditional logic to helpers/methods.
- Naming: `camelCase` for vars/functions, `PascalCase` for class names.
- Keep initializers lean; avoid putting business logic in plugin API registration blocks.
- Use existing Discourse helpers/services (`ajax`, `popupAjaxError`, MessageBus integrations).
- Prefer i18n keys for new user-facing text instead of hardcoded strings.
- Prefer English comments/messages for new code, even if touched files contain mixed language comments.

## JS/GJS Imports
- Group imports in this order:
  1) Ember/Glimmer core
  2) Discourse framework modules
  3) Local plugin modules
- Keep one import per line.
- Remove unused imports when editing a file.

## Naming and Data Contracts
- Language code format is `xx` or `xx-xx` (examples: `en`, `zh-cn`, `es`).
- Keep API response keys stable unless a migration/compatibility plan is included.
- Treat MessageBus channel names as public contracts with frontend subscribers.
- New site settings must be prefixed with `babel_reunited_` in `config/settings.yml`.

## Migrations and Models
- Keep migrations minimal and reversible.
- Add indexes for new high-cardinality lookup paths.
- Preserve uniqueness semantics (for example `(post_id, language)`).
- Mirror model validations with caller-side validation where appropriate.

## Logging and Observability
- Include key identifiers in logs: `post_id`, `topic_id` (if available), `target_language`, provider, phase.
- Truncate large provider payloads before logging.
- Never log API keys or sensitive secrets.

## Security and Permissions
- API keys in settings are secrets; never hardcode or expose them.
- Treat custom base URLs/model config as untrusted input and validate before using.
- Keep auth/visibility checks in controllers (`ensure_logged_in`, `guardian.can_see?`).

## Practical Change Policy
- Match conventions in touched files.
- Do not reformat entire files unless explicitly requested.
- Add comments only for non-obvious behavior.
- Keep behavior backward compatible unless the task explicitly requires a breaking change.

## Verification Expectations
- For Ruby changes, run at least the most relevant `rspec` target (single file/line when possible).
- For frontend changes, run plugin `qunit` when feasible.
- Run `bin/lint` on touched files when possible.
- In handoff notes, state exactly what you ran and what you could not run.
