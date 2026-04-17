# frozen_string_literal: true

RSpec.describe BabelReunited::Providers::OpenAiCompatible do
  subject(:provider) { described_class.new }

  before { enable_current_plugin }

  describe "#endpoint_path" do
    it "returns the OpenAI chat completions path" do
      expect(provider.endpoint_path).to eq("/v1/chat/completions")
    end
  end

  describe "#headers" do
    it "returns Bearer auth and Content-Type" do
      headers = provider.headers("sk-test-key")
      expect(headers["Authorization"]).to eq("Bearer sk-test-key")
      expect(headers["Content-Type"]).to eq("application/json")
    end
  end

  describe "#build_request_body" do
    it "builds OpenAI-format request body" do
      body =
        provider.build_request_body(
          model: "gpt-4o",
          messages: [{ role: "user", content: "Hello" }],
          max_tokens: 4096,
          token_param: :max_completion_tokens,
          supports_temperature: true,
        )

      expect(body[:model]).to eq("gpt-4o")
      expect(body[:messages]).to eq([{ role: "user", content: "Hello" }])
      expect(body[:max_completion_tokens]).to eq(4096)
      expect(body[:temperature]).to eq(0.3)
    end

    it "uses the provided token_param key" do
      body =
        provider.build_request_body(
          model: "gpt-3.5-turbo",
          messages: [],
          max_tokens: 1000,
          token_param: :max_tokens,
          supports_temperature: true,
        )

      expect(body[:max_tokens]).to eq(1000)
      expect(body).not_to have_key(:max_completion_tokens)
    end

    it "omits temperature when supports_temperature is false" do
      body =
        provider.build_request_body(
          model: "gpt-5",
          messages: [],
          max_tokens: 1000,
          token_param: :max_tokens,
          supports_temperature: false,
        )

      expect(body).not_to have_key(:temperature)
    end
  end

  describe "#parse_response" do
    it "extracts text from OpenAI response format" do
      body = {
        "choices" => [
          { "message" => { "content" => "Translated text" }, "finish_reason" => "stop" },
        ],
        "model" => "gpt-4o",
        "usage" => {
          "total_tokens" => 150,
        },
      }

      result = provider.parse_response(body)
      expect(result[:text]).to eq("Translated text")
      expect(result[:model]).to eq("gpt-4o")
      expect(result[:tokens_used]).to eq(150)
    end

    it "returns error when finish_reason is length" do
      body = {
        "choices" => [{ "message" => { "content" => "Partial..." }, "finish_reason" => "length" }],
      }

      result = provider.parse_response(body)
      expect(result[:error]).to include("truncated")
    end

    it "returns error when choices are missing" do
      result = provider.parse_response({})
      expect(result[:error]).to include("Invalid response format")
    end

    it "returns error when content is blank" do
      body = { "choices" => [{ "message" => { "content" => "" }, "finish_reason" => "stop" }] }

      result = provider.parse_response(body)
      expect(result[:error]).to include("No translation")
    end
  end
end
