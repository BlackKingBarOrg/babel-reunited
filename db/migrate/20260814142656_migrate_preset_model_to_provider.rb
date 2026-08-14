# frozen_string_literal: true

class MigratePresetModelToProvider < ActiveRecord::Migration[8.0]
  # babel_reunited_preset_model named a model and implied its provider. The
  # two are now separate settings, so every preset has to be split back into
  # the pair it stood for. claude-haiku-4-5 is the one entry whose key was
  # not the model id it actually sent.
  PRESETS = {
    "gpt-5" => %w[openai gpt-5],
    "gpt-5-mini" => %w[openai gpt-5-mini],
    "gpt-5-nano" => %w[openai gpt-5-nano],
    "gpt-4.1" => %w[openai gpt-4.1],
    "gpt-4.1-mini" => %w[openai gpt-4.1-mini],
    "gpt-4.1-nano" => %w[openai gpt-4.1-nano],
    "gpt-4o" => %w[openai gpt-4o],
    "gpt-4o-mini" => %w[openai gpt-4o-mini],
    "gpt-3.5-turbo" => %w[openai gpt-3.5-turbo],
    "grok-4" => %w[xai grok-4],
    "grok-4-fast-non-reasoning" => %w[xai grok-4-fast-non-reasoning],
    "grok-3" => %w[xai grok-3],
    "grok-2" => %w[xai grok-2],
    "deepseek-r1" => %w[deepseek deepseek-r1],
    "deepseek-v3" => %w[deepseek deepseek-v3],
    "claude-opus-4-7" => %w[anthropic claude-opus-4-7],
    "claude-sonnet-4-6" => %w[anthropic claude-sonnet-4-6],
    "claude-haiku-4-5" => %w[anthropic claude-haiku-4-5-20251001]
  }.freeze

  ENUM = 7
  STRING = 1
  INTEGER = 3

  def up
    preset = read_setting("babel_reunited_preset_model")

    # No row means the site was on the old default (gpt-4o), which the new
    # defaults already reproduce.
    return if preset.blank?

    if preset == "custom"
      provider = "openai_compatible"
      model = read_setting("babel_reunited_custom_model_name")

      # The custom provider's output cap drove both the request and the chunk
      # size. Carry it into both so a site that tuned it down for a small
      # model keeps the same behaviour.
      output_tokens = read_setting("babel_reunited_custom_max_output_tokens")
      if output_tokens.present?
        upsert_setting(
          "babel_reunited_max_output_tokens",
          output_tokens,
          INTEGER
        )
        upsert_setting("babel_reunited_chunk_size", output_tokens, INTEGER)
      end
    else
      provider, model = PRESETS[preset]
      return if provider.nil?
    end

    upsert_setting("babel_reunited_provider", provider, ENUM)
    upsert_setting("babel_reunited_model", model, STRING) if model.present?
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def read_setting(name)
    DB.query_single(
      "SELECT value FROM site_settings WHERE name = :name LIMIT 1",
      name: name
    ).first
  end

  # Not named `write`: ActiveRecord::Migration defines one for logging.
  def upsert_setting(name, value, data_type)
    DB.exec(
      "INSERT INTO site_settings(name, value, data_type, created_at, updated_at)
       VALUES(:name, :value, :data_type, NOW(), NOW())
       ON CONFLICT (name) DO UPDATE SET value = :value, updated_at = NOW()",
      name: name,
      value: value.to_s,
      data_type: data_type
    )
  end
end
