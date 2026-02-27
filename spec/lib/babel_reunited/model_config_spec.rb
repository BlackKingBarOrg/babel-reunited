# frozen_string_literal: true

RSpec.describe BabelReunited::ModelConfig do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_xai_api_key = "xai-test-key"
    SiteSetting.babel_reunited_deepseek_api_key = "ds-test-key"
  end

  describe ".get_config" do
    it "returns config for a preset model" do
      SiteSetting.babel_reunited_preset_model = "gpt-4o"

      config = described_class.get_config
      expect(config[:provider]).to eq("openai")
      expect(config[:model_name]).to eq("gpt-4o")
      expect(config[:base_url]).to eq("https://api.openai.com")
      expect(config[:api_key]).to eq("sk-test-key")
      expect(config[:max_tokens]).to eq(128_000)
      expect(config[:max_output_tokens]).to eq(16_000)
    end

    it "returns config for xAI model" do
      SiteSetting.babel_reunited_preset_model = "grok-4"

      config = described_class.get_config
      expect(config[:provider]).to eq("xai")
      expect(config[:api_key]).to eq("xai-test-key")
      expect(config[:base_url]).to eq("https://api.x.ai")
    end

    it "returns config for DeepSeek model" do
      SiteSetting.babel_reunited_preset_model = "deepseek-r1"

      config = described_class.get_config
      expect(config[:provider]).to eq("deepseek")
      expect(config[:api_key]).to eq("ds-test-key")
      expect(config[:base_url]).to eq("https://api.deepseek.com")
    end

    it "returns custom config when preset is 'custom'" do
      SiteSetting.babel_reunited_preset_model = "custom"
      SiteSetting.babel_reunited_custom_model_name = "my-model"
      SiteSetting.babel_reunited_custom_base_url = "https://my-api.example.com"
      SiteSetting.babel_reunited_custom_api_key = "custom-key"
      SiteSetting.babel_reunited_custom_max_tokens = 32_000
      SiteSetting.babel_reunited_custom_max_output_tokens = 8_000

      config = described_class.get_config
      expect(config[:provider]).to eq("custom")
      expect(config[:model_name]).to eq("my-model")
      expect(config[:base_url]).to eq("https://my-api.example.com")
      expect(config[:api_key]).to eq("custom-key")
      expect(config[:max_tokens]).to eq(32_000)
      expect(config[:max_output_tokens]).to eq(8_000)
    end

    it "returns nil for invalid model key passed directly to PRESET_MODELS" do
      expect(described_class::PRESET_MODELS["nonexistent-model"]).to be_nil
    end
  end

  describe ".get_api_key" do
    it "returns the API key for the current preset" do
      SiteSetting.babel_reunited_preset_model = "gpt-4o"
      expect(described_class.get_api_key).to eq("sk-test-key")
    end
  end

  describe ".get_model_name" do
    it "returns the model name for the current preset" do
      SiteSetting.babel_reunited_preset_model = "gpt-4o"
      expect(described_class.get_model_name).to eq("gpt-4o")
    end
  end

  describe ".get_base_url" do
    it "returns the base URL for the current preset" do
      SiteSetting.babel_reunited_preset_model = "gpt-4o"
      expect(described_class.get_base_url).to eq("https://api.openai.com")
    end
  end

  describe ".list_available_models" do
    it "returns all 12 preset models" do
      models = described_class.list_available_models
      expect(models.length).to eq(12)
    end

    it "includes required fields for each model" do
      models = described_class.list_available_models
      models.each do |model|
        expect(model).to have_key(:key)
        expect(model).to have_key(:name)
        expect(model).to have_key(:provider)
        expect(model).to have_key(:tier)
      end
    end
  end

  describe ".list_models_by_provider" do
    it "filters OpenAI models" do
      openai_models = described_class.list_models_by_provider("openai")
      expect(openai_models.keys).to include("gpt-4o", "gpt-4o-mini", "gpt-3.5-turbo")
      openai_models.each_value { |config| expect(config[:provider]).to eq("openai") }
    end

    it "filters xAI models" do
      xai_models = described_class.list_models_by_provider("xai")
      expect(xai_models.keys).to include("grok-4", "grok-3", "grok-2")
      xai_models.each_value { |config| expect(config[:provider]).to eq("xai") }
    end

    it "filters DeepSeek models" do
      deepseek_models = described_class.list_models_by_provider("deepseek")
      expect(deepseek_models.keys).to include("deepseek-r1", "deepseek-v3")
      deepseek_models.each_value { |config| expect(config[:provider]).to eq("deepseek") }
    end

    it "returns empty hash for unknown provider" do
      expect(described_class.list_models_by_provider("unknown")).to be_empty
    end
  end

  describe ".list_models_by_tier" do
    it "filters High tier models" do
      high_tier = described_class.list_models_by_tier("High")
      high_tier.each_value { |config| expect(config[:tier]).to eq("High") }
      expect(high_tier).not_to be_empty
    end

    it "filters Medium tier models" do
      medium_tier = described_class.list_models_by_tier("Medium")
      medium_tier.each_value { |config| expect(config[:tier]).to eq("Medium") }
      expect(medium_tier).not_to be_empty
    end

    it "filters Low tier models" do
      low_tier = described_class.list_models_by_tier("Low")
      low_tier.each_value { |config| expect(config[:tier]).to eq("Low") }
      expect(low_tier).not_to be_empty
    end
  end
end
