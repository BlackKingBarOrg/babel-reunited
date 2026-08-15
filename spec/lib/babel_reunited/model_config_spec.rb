# frozen_string_literal: true

RSpec.describe BabelReunited::ModelConfig do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_xai_api_key = "xai-test-key"
    SiteSetting.babel_reunited_deepseek_api_key = "ds-test-key"
    SiteSetting.babel_reunited_openrouter_api_key = "or-test-key"
    SiteSetting.babel_reunited_google_api_key = "goog-test-key"
  end

  describe ".get_config" do
    it "resolves the provider's endpoint and key" do
      SiteSetting.babel_reunited_provider = "openai"
      SiteSetting.babel_reunited_model = "gpt-4o"

      config = described_class.get_config
      expect(config[:provider]).to eq("openai")
      expect(config[:model_name]).to eq("gpt-4o")
      expect(config[:base_url]).to eq("https://api.openai.com")
      expect(config[:path]).to eq("/v1/chat/completions")
      expect(config[:wire]).to eq(:openai)
      expect(config[:api_key]).to eq("sk-test-key")
    end

    it "returns config for xAI" do
      SiteSetting.babel_reunited_provider = "xai"
      SiteSetting.babel_reunited_model = "grok-4.6"

      config = described_class.get_config
      expect(config[:api_key]).to eq("xai-test-key")
      expect(config[:base_url]).to eq("https://api.x.ai")
    end

    it "returns config for DeepSeek" do
      SiteSetting.babel_reunited_provider = "deepseek"
      SiteSetting.babel_reunited_model = "deepseek-v4-flash"

      config = described_class.get_config
      expect(config[:api_key]).to eq("ds-test-key")
      expect(config[:base_url]).to eq("https://api.deepseek.com")
    end

    # The OpenAI-compatible endpoint is not at the same place on every host,
    # which is the whole reason the path travels with the provider.
    it "uses OpenRouter's own API prefix" do
      SiteSetting.babel_reunited_provider = "openrouter"
      SiteSetting.babel_reunited_model = "anthropic/claude-sonnet-4-6"

      config = described_class.get_config
      expect(config[:base_url]).to eq("https://openrouter.ai")
      expect(config[:path]).to eq("/api/v1/chat/completions")
      expect(config[:wire]).to eq(:openai)
      expect(config[:api_key]).to eq("or-test-key")
    end

    it "uses Google's compatibility shim path" do
      SiteSetting.babel_reunited_provider = "google"
      SiteSetting.babel_reunited_model = "gemini-2.5-flash"

      config = described_class.get_config
      expect(config[:base_url]).to eq(
        "https://generativelanguage.googleapis.com"
      )
      expect(config[:path]).to eq("/v1beta/openai/chat/completions")
    end

    it "uses Anthropic's own wire format" do
      SiteSetting.babel_reunited_provider = "anthropic"
      SiteSetting.babel_reunited_model = "claude-sonnet-4-6"

      config = described_class.get_config
      expect(config[:wire]).to eq(:anthropic)
      expect(config[:path]).to eq("/v1/messages")
    end

    it "takes base URL and key from the settings for openai_compatible" do
      SiteSetting.babel_reunited_provider = "openai_compatible"
      SiteSetting.babel_reunited_model = "my-model"
      SiteSetting.babel_reunited_custom_base_url = "https://my-api.example.com"
      SiteSetting.babel_reunited_custom_api_key = "custom-key"

      config = described_class.get_config
      expect(config[:provider]).to eq("openai_compatible")
      expect(config[:model_name]).to eq("my-model")
      expect(config[:base_url]).to eq("https://my-api.example.com")
      expect(config[:path]).to eq("/v1/chat/completions")
      expect(config[:api_key]).to eq("custom-key")
    end

    it "carries the token settings" do
      SiteSetting.babel_reunited_provider = "openai"
      SiteSetting.babel_reunited_max_output_tokens = 4_096
      SiteSetting.babel_reunited_chunk_size = 12_000

      config = described_class.get_config
      expect(config[:max_output_tokens]).to eq(4_096)
      expect(config[:chunk_size]).to eq(12_000)
    end

    it "returns nil for a provider that is not in the registry" do
      SiteSetting.stubs(:babel_reunited_provider).returns("nonexistent")
      expect(described_class.get_config).to be_nil
    end
  end

  # Providers print their endpoint in whichever form they like, and admins
  # paste it verbatim. All of these name the same endpoint.
  describe ".split_custom_url" do
    it "appends the default path to a bare origin" do
      expect(described_class.split_custom_url("https://api.example.com")).to eq(
        %w[https://api.example.com /v1/chat/completions]
      )
    end

    it "ignores a trailing slash" do
      expect(
        described_class.split_custom_url("https://api.example.com/")
      ).to eq(%w[https://api.example.com /v1/chat/completions])
    end

    it "does not double the version prefix the admin already pasted" do
      expect(
        described_class.split_custom_url("https://api.example.com/v1")
      ).to eq(%w[https://api.example.com /v1/chat/completions])
    end

    it "keeps a non-standard prefix" do
      expect(
        described_class.split_custom_url("https://api.example.com/openai/v1")
      ).to eq(%w[https://api.example.com /openai/v1/chat/completions])
    end

    it "accepts a fully spelled out endpoint" do
      expect(
        described_class.split_custom_url(
          "https://api.example.com/v1/chat/completions"
        )
      ).to eq(%w[https://api.example.com /v1/chat/completions])
    end

    it "keeps a non-default port" do
      expect(described_class.split_custom_url("http://localhost:11434")).to eq(
        %w[http://localhost:11434 /v1/chat/completions]
      )
    end
  end
end
