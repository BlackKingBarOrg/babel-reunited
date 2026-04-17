# frozen_string_literal: true

RSpec.describe BabelReunited::Providers::Anthropic do
  subject(:provider) { described_class.new }

  before { enable_current_plugin }

  describe "#endpoint_path" do
    it "returns the Anthropic messages path" do
      expect(provider.endpoint_path).to eq("/v1/messages")
    end
  end

  describe "#headers" do
    it "returns x-api-key and anthropic-version headers" do
      headers = provider.headers("sk-ant-test-key")
      expect(headers["x-api-key"]).to eq("sk-ant-test-key")
      expect(headers["anthropic-version"]).to eq("2023-06-01")
      expect(headers["content-type"]).to eq("application/json")
    end

    it "does not include Authorization Bearer header" do
      headers = provider.headers("sk-ant-test-key")
      expect(headers).not_to have_key("Authorization")
    end
  end

  describe "#build_request_body" do
    it "builds Anthropic-format request body with max_tokens" do
      body =
        provider.build_request_body(
          model: "claude-sonnet-4-20250514",
          messages: [{ role: "user", content: "Hello" }],
          max_tokens: 4096,
          token_param: :max_completion_tokens,
          supports_temperature: true,
        )

      expect(body[:model]).to eq("claude-sonnet-4-20250514")
      expect(body[:messages]).to eq([{ role: "user", content: "Hello" }])
      expect(body[:max_tokens]).to eq(4096)
      expect(body[:temperature]).to eq(0.3)
      expect(body).not_to have_key(:max_completion_tokens)
    end

    it "always uses max_tokens regardless of token_param" do
      body =
        provider.build_request_body(
          model: "claude-sonnet-4-20250514",
          messages: [],
          max_tokens: 2000,
          token_param: :max_completion_tokens,
          supports_temperature: true,
        )

      expect(body[:max_tokens]).to eq(2000)
      expect(body).not_to have_key(:max_completion_tokens)
    end
  end

  describe "#parse_response" do
    it "extracts text from Anthropic response format" do
      body = {
        "content" => [{ "type" => "text", "text" => "Translated text" }],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => {
          "input_tokens" => 50,
          "output_tokens" => 80,
        },
      }

      result = provider.parse_response(body)
      expect(result[:text]).to eq("Translated text")
      expect(result[:model]).to eq("claude-sonnet-4-20250514")
      expect(result[:tokens_used]).to eq(130)
    end

    it "returns error when stop_reason is max_tokens" do
      body = {
        "content" => [{ "type" => "text", "text" => "Partial..." }],
        "stop_reason" => "max_tokens",
        "usage" => {
          "input_tokens" => 50,
          "output_tokens" => 16_000,
        },
      }

      result = provider.parse_response(body)
      expect(result[:error]).to include("truncated")
    end

    it "returns error when content array is missing" do
      result = provider.parse_response({})
      expect(result[:error]).to include("Invalid response format")
    end

    it "returns error when content array is empty" do
      result = provider.parse_response({ "content" => [] })
      expect(result[:error]).to include("Invalid response format")
    end

    it "returns error when no text block is found" do
      body = {
        "content" => [{ "type" => "tool_use", "name" => "something" }],
        "stop_reason" => "end_turn",
      }

      result = provider.parse_response(body)
      expect(result[:error]).to include("No translation")
    end

    it "handles missing usage gracefully" do
      body = { "content" => [{ "type" => "text", "text" => "Hello" }], "stop_reason" => "end_turn" }

      result = provider.parse_response(body)
      expect(result[:text]).to eq("Hello")
      expect(result[:tokens_used]).to eq(0)
    end
  end
end
