# frozen_string_literal: true

class MigratePresetModelToProvider < ActiveRecord::Migration[8.0]
  # babel_reunited_preset_model named a model and implied three other things:
  # its provider, its output cap, and -- because the old code passed the
  # output cap straight to the content splitter -- its chunk size. All four
  # have to come back out, or a site silently changes how much it asks for
  # and how finely it splits.
  #
  # claude-haiku-4-5 is the one entry whose key was not the model id it sent.
  PRESETS = {
    "gpt-5" => ["openai", "gpt-5", 16_000],
    "gpt-5-mini" => ["openai", "gpt-5-mini", 16_000],
    "gpt-5-nano" => ["openai", "gpt-5-nano", 4_096],
    "gpt-4.1" => ["openai", "gpt-4.1", 32_768],
    "gpt-4.1-mini" => ["openai", "gpt-4.1-mini", 32_768],
    "gpt-4.1-nano" => ["openai", "gpt-4.1-nano", 32_768],
    "gpt-4o" => ["openai", "gpt-4o", 16_000],
    "gpt-4o-mini" => ["openai", "gpt-4o-mini", 16_000],
    "gpt-3.5-turbo" => ["openai", "gpt-3.5-turbo", 4_096],
    "grok-4" => ["xai", "grok-4", 36_000],
    "grok-4-fast-non-reasoning" => ["xai", "grok-4-fast-non-reasoning", 36_000],
    "grok-3" => ["xai", "grok-3", 16_000],
    "grok-2" => ["xai", "grok-2", 16_000],
    "deepseek-r1" => ["deepseek", "deepseek-r1", 16_000],
    "deepseek-v3" => ["deepseek", "deepseek-v3", 16_000],
    "claude-opus-4-7" => ["anthropic", "claude-opus-4-7", 32_000],
    "claude-sonnet-4-6" => ["anthropic", "claude-sonnet-4-6", 16_000],
    "claude-haiku-4-5" => ["anthropic", "claude-haiku-4-5-20251001", 8_192]
  }.freeze

  # What these defaulted to before this release. A setting left at its
  # default has no row, so the old value has to be written down here.
  CUSTOM_DEFAULT_OUTPUT_TOKENS = 4_096
  OLD_DEFAULT_MAX_CONTENT_LENGTH = 4_000

  ENUM = 7
  STRING = 1
  INTEGER = 3

  def up
    preset = read_setting("babel_reunited_preset_model")

    # No row means the site was on the old default, gpt-4o, whose 16000 both
    # new defaults reproduce.
    return if preset.blank?

    if preset == "custom"
      provider = "openai_compatible"
      model = read_setting("babel_reunited_custom_model_name")
      # A setting left at its default has no row, so reading the row alone
      # loses the old default entirely and the site silently inherits the
      # new one -- 4096 becoming 16000, which is four times the chunk and an
      # output cap some small models refuse outright.
      output_tokens =
        read_setting("babel_reunited_custom_max_output_tokens").presence ||
          CUSTOM_DEFAULT_OUTPUT_TOKENS

      # Only the custom provider was ever bounded by this setting; presets
      # derived their limit from the model, and unifying that is the point of
      # the change. So only a custom site can silently gain reach here, and
      # 4000 to 200000 is a fiftyfold change in what gets sent to a provider.
      # An explicit row is the admin's own number and is left alone.
      if read_setting("babel_reunited_max_content_length").blank?
        upsert_setting(
          "babel_reunited_max_content_length",
          OLD_DEFAULT_MAX_CONTENT_LENGTH,
          INTEGER
        )
      end
    else
      provider, model, output_tokens = PRESETS[preset]
      return if provider.nil?
    end

    # The old code passed one number to the provider as the output cap and to
    # the content splitter as a character count, so both new settings come
    # from it. Splitting them apart is the point of the change; starting them
    # anywhere else would move two behaviours at once.
    if output_tokens.present?
      upsert_setting("babel_reunited_max_output_tokens", output_tokens, INTEGER)
      upsert_setting("babel_reunited_chunk_size", output_tokens, INTEGER)
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
