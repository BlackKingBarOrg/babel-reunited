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
end
