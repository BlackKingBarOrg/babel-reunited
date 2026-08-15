# frozen_string_literal: true

require Rails
          .root
          .join(
            "plugins/babel-reunited/db/migrate/20260814142656_migrate_preset_model_to_provider"
          )
          .to_s

# The migration is the only thing standing between an existing site's
# configuration and the new defaults, and none of it is exercised by the rest
# of the suite: every other spec starts from the new settings.
RSpec.describe MigratePresetModelToProvider do
  before { enable_current_plugin }

  def put(name, value, data_type)
    DB.exec("DELETE FROM site_settings WHERE name = :n", n: name)
    DB.exec(
      "INSERT INTO site_settings(name, value, data_type, created_at, updated_at)
       VALUES(:n, :v, :t, NOW(), NOW())",
      n: name,
      v: value.to_s,
      t: data_type
    )
  end

  def setting(name)
    DB.query_single(
      "SELECT value FROM site_settings WHERE name = :n",
      n: name
    ).first
  end

  def migrate
    %w[
      babel_reunited_provider
      babel_reunited_model
      babel_reunited_max_output_tokens
      babel_reunited_chunk_size
    ].each { |n| DB.exec("DELETE FROM site_settings WHERE name = :n", n: n) }
    described_class.new.up
  end

  it "splits a preset into its provider and model" do
    put("babel_reunited_preset_model", "claude-sonnet-4-6", 7)

    migrate

    expect(setting("babel_reunited_provider")).to eq("anthropic")
    expect(setting("babel_reunited_model")).to eq("claude-sonnet-4-6")
  end

  # The one preset whose key was not the id it sent.
  it "restores the dated model id behind claude-haiku-4-5" do
    put("babel_reunited_preset_model", "claude-haiku-4-5", 7)

    migrate

    expect(setting("babel_reunited_model")).to eq("claude-haiku-4-5-20251001")
  end

  # The old code handed one number to the provider as a token cap and to the
  # splitter as a character count, so both new settings start from it.
  it "carries the preset's output cap into both new settings" do
    put("babel_reunited_preset_model", "grok-4", 7)

    migrate

    expect(setting("babel_reunited_max_output_tokens")).to eq("36000")
    expect(setting("babel_reunited_chunk_size")).to eq("36000")
  end

  it "maps custom to the openai_compatible provider" do
    put("babel_reunited_preset_model", "custom", 7)
    put("babel_reunited_custom_model_name", "qwen2.5:14b", 1)

    migrate

    expect(setting("babel_reunited_provider")).to eq("openai_compatible")
    expect(setting("babel_reunited_model")).to eq("qwen2.5:14b")
  end

  it "keeps a custom site's tuned output cap" do
    put("babel_reunited_preset_model", "custom", 7)
    put("babel_reunited_custom_model_name", "local", 1)
    put("babel_reunited_custom_max_output_tokens", "2048", 3)

    migrate

    expect(setting("babel_reunited_max_output_tokens")).to eq("2048")
    expect(setting("babel_reunited_chunk_size")).to eq("2048")
  end

  # A setting left at its default has no row at all, so reading the row alone
  # loses the old default and the site silently inherits the new one.
  it "uses the old default when a custom site never changed the output cap" do
    put("babel_reunited_preset_model", "custom", 7)
    put("babel_reunited_custom_model_name", "local", 1)
    DB.exec(
      "DELETE FROM site_settings WHERE name = 'babel_reunited_custom_max_output_tokens'"
    )

    migrate

    expect(setting("babel_reunited_max_output_tokens")).to eq("4096")
    expect(setting("babel_reunited_chunk_size")).to eq("4096")
  end

  # Only the custom provider was ever bounded by max_content_length; presets
  # derived their limit from the model. So only a custom site can silently
  # gain reach, and 4000 to 200000 is a fiftyfold change in what is sent.
  describe "max_content_length for a custom site" do
    before do
      put("babel_reunited_preset_model", "custom", 7)
      put("babel_reunited_custom_model_name", "local", 1)
      DB.exec(
        "DELETE FROM site_settings WHERE name = 'babel_reunited_max_content_length'"
      )
    end

    it "writes the old default when the site never set one" do
      migrate

      expect(setting("babel_reunited_max_content_length")).to eq("4000")
    end

    it "leaves a value the admin chose alone" do
      put("babel_reunited_max_content_length", "12000", 3)

      migrate

      expect(setting("babel_reunited_max_content_length")).to eq("12000")
    end

    it "does not touch it for a preset site, which it never bounded" do
      put("babel_reunited_preset_model", "gpt-4o", 7)

      migrate

      expect(setting("babel_reunited_max_content_length")).to be_nil
    end
  end

  # A site that never touched the preset was on gpt-4o, which the new
  # defaults already reproduce, and a fresh install must not gain rows.
  it "writes nothing when the old setting was never set" do
    DB.exec(
      "DELETE FROM site_settings WHERE name = 'babel_reunited_preset_model'"
    )

    migrate

    expect(setting("babel_reunited_provider")).to be_nil
    expect(setting("babel_reunited_model")).to be_nil
    expect(setting("babel_reunited_max_output_tokens")).to be_nil
  end

  it "leaves an unrecognised preset value alone" do
    put("babel_reunited_preset_model", "some-model-we-never-shipped", 7)

    migrate

    expect(setting("babel_reunited_provider")).to be_nil
  end
end
