# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe BabelReunited::TranslationService do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user, title: "Original Topic Title") }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user, post_number: 1) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    SiteSetting.babel_reunited_translate_title = true
    SiteSetting.babel_reunited_rate_limit_per_minute = 60
    SiteSetting.babel_reunited_request_timeout_seconds = 30

    Discourse.redis.flushdb
  end

  def build_service(post: post_record, target_language: "es", force_update: false)
    described_class.new(post: post, target_language: target_language, force_update: force_update)
  end

  def stub_openai_success(translated_content: "<p>Hola mundo</p>", translated_title: "Titulo")
    response_body = {
      choices: [
        {
          message: {
            content: {
              translated_content: translated_content,
              translated_title: translated_title,
            }.to_json,
          },
        },
      ],
      model: "gpt-4o",
      usage: {
        total_tokens: 100,
      },
    }

    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200,
      body: response_body.to_json,
      headers: {
        "Content-Type" => "application/json",
      },
    )
  end

  describe "input validation" do
    it "returns error for blank post" do
      result = described_class.new(post: nil, target_language: "es").call
      expect(result.failure?).to be true
      expect(result[:error]).to eq("Post not found")
    end

    it "returns error for blank target_language" do
      result = build_service(target_language: "").call
      expect(result.failure?).to be true
      expect(result[:error]).to eq("Target language not specified")
    end
  end

  describe "API configuration errors" do
    it "returns error when API key is not configured" do
      SiteSetting.babel_reunited_openai_api_key = ""

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("API key not configured")
    end

    it "returns error when model config is nil" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(nil)

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Invalid preset model")
    end
  end

  describe "rate limiting" do
    it "returns error when rate limit exceeded" do
      BabelReunited::RateLimiter.stubs(:can_make_request?).returns(false)
      stub_openai_success

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Rate limit exceeded")
    end
  end

  describe "content length check" do
    it "returns error when content is too long" do
      long_post =
        Fabricate(
          :post,
          topic: topic,
          user: user,
          cooked: "<p>#{"a" * 500_000}</p>",
          post_number: 2,
        )

      stub_openai_success
      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Content too long")
    end
  end

  describe "successful translation" do
    it "returns translation result" do
      stub_openai_success

      result = build_service.call
      expect(result.failure?).to be false
      expect(result[:translation].translated_content).to eq("<p>Hola mundo</p>")
      expect(result[:translation].source_language).to eq("auto")
    end

    it "includes ai_response in context" do
      stub_openai_success

      result = build_service.call
      expect(result[:ai_response]).to be_present
      expect(result[:ai_response][:confidence]).to eq(0.95)
      expect(result[:ai_response][:provider_info][:model]).to eq("gpt-4o")
    end

    it "records the request for rate limiting" do
      stub_openai_success

      expect { build_service.call }.to change {
        60 - BabelReunited::RateLimiter.remaining_requests
      }.by(1)
    end
  end

  describe "title translation" do
    it "includes title for first post of topic" do
      stub_openai_success(translated_title: "Titulo traducido")

      result = build_service.call
      expect(result[:translation].translated_title).to eq("Titulo traducido")
    end

    it "does not include title for non-first posts" do
      non_first_post = Fabricate(:post, topic: topic, user: user, post_number: 2)
      stub_openai_success(translated_title: nil)

      result = build_service(post: non_first_post).call
      expect(result.failure?).to be false
    end

    it "does not include title when translate_title is disabled" do
      SiteSetting.babel_reunited_translate_title = false
      stub_openai_success(translated_title: nil)

      result = build_service.call
      expect(result.failure?).to be false
    end
  end

  describe "JSON response parsing" do
    it "parses direct JSON response" do
      stub_openai_success

      result = build_service.call
      expect(result[:translation].translated_content).to be_present
    end

    it "extracts JSON from content with surrounding text" do
      response_body = {
        choices: [
          {
            message: {
              content:
                "Here is the translation:\n{\"translated_content\": \"<p>Hola</p>\", \"translated_title\": \"Titulo\"}\nDone.",
            },
          },
        ],
        model: "gpt-4o",
        usage: {
          total_tokens: 50,
        },
      }

      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: response_body.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result[:translation].translated_content).to eq("<p>Hola</p>")
    end

    it "extracts from incomplete JSON" do
      response_body = {
        choices: [
          { message: { content: "{\"translated_content\": \"<p>Hola</p>\", \"translated_ti" } },
        ],
        model: "gpt-4o",
        usage: {
          total_tokens: 50,
        },
      }

      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: response_body.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result[:translation].translated_content).to eq("<p>Hola</p>")
    end
  end

  describe "API error handling" do
    it "handles 401 unauthorized" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 401,
        body: { error: { message: "Invalid API key" } }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Invalid API key")
    end

    it "handles 429 rate limit" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 429,
        body: { error: { message: "Rate limit exceeded" } }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Rate limit exceeded")
    end

    it "handles 500 server error" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 500,
        body: { error: { message: "Internal server error" } }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("temporarily unavailable")
    end

    it "handles network errors" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_raise(
        Faraday::ConnectionFailed.new("connection refused"),
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Network error")
    end
  end
end
