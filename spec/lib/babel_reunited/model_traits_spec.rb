# frozen_string_literal: true

RSpec.describe BabelReunited::ModelTraits do
  before { enable_current_plugin }

  def traits(model, provider: "openai")
    described_class.for(provider: provider, model: model)
  end

  describe "temperature" do
    it "drops temperature for OpenAI's reasoning families" do
      expect(traits("gpt-5")[:supports_temperature]).to eq(false)
      expect(traits("gpt-5-mini")[:supports_temperature]).to eq(false)
      expect(traits("o3-mini")[:supports_temperature]).to eq(false)
    end

    it "drops temperature for Anthropic's Opus 4 line" do
      expect(
        traits("claude-opus-4-7", provider: "anthropic")[:supports_temperature]
      ).to eq(false)
    end

    it "keeps temperature everywhere else" do
      expect(traits("gpt-4o")[:supports_temperature]).to eq(true)
      expect(
        traits("claude-sonnet-4-6", provider: "anthropic")[
          :supports_temperature
        ]
      ).to eq(true)
      expect(traits("grok-4.6", provider: "xai")[:supports_temperature]).to eq(
        true
      )
    end

    # A gateway hands back the same model under a namespaced id, and the
    # quirk belongs to the model, not to the route it took.
    it "sees through a gateway prefix" do
      expect(
        traits("openai/gpt-5", provider: "openrouter")[:supports_temperature]
      ).to eq(false)
    end
  end

  describe "output token parameter" do
    it "uses max_completion_tokens on OpenAI's own API" do
      expect(traits("gpt-4o")[:output_token_param]).to eq(
        :max_completion_tokens
      )
      expect(traits("gpt-5")[:output_token_param]).to eq(:max_completion_tokens)
    end

    it "keeps max_tokens for gpt-3.5, which predates the rename" do
      expect(traits("gpt-3.5-turbo")[:output_token_param]).to eq(:max_tokens)
    end

    # Gateways and every other provider take the original name, including
    # for OpenAI models they proxy.
    it "uses max_tokens everywhere but OpenAI" do
      expect(
        traits("openai/gpt-5", provider: "openrouter")[:output_token_param]
      ).to eq(:max_tokens)
      expect(
        traits("claude-sonnet-4-6", provider: "anthropic")[:output_token_param]
      ).to eq(:max_tokens)
      expect(traits("grok-4.6", provider: "xai")[:output_token_param]).to eq(
        :max_tokens
      )
    end
  end
end
