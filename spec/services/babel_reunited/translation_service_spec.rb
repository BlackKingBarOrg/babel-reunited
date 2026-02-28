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

    it "returns error when base_url is missing" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        { provider: "openai", model_name: "gpt-4o", base_url: nil, api_key: "sk-test-key" },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Base URL not configured")
    end

    it "returns error when model_name is missing" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        {
          provider: "openai",
          model_name: nil,
          base_url: "https://api.openai.com",
          api_key: "sk-test-key",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Model name not configured")
    end
  end

  describe "rate limiting" do
    it "returns error when rate limit exceeded" do
      BabelReunited::RateLimiter.stubs(:perform_request_if_allowed).returns(false)
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

  describe "title fallback" do
    it "fills missing title when fallback succeeds" do
      service = build_service
      service.stubs(:call_openai_api).returns(
        {
          translated_text: "<p>Hola mundo</p>",
          translated_title: nil,
          source_language: "auto",
          confidence: 0.95,
          provider_info: {
            model: "gpt-4o",
            provider: "openai",
          },
        },
      )
      service.stubs(:get_api_config).returns(
        {
          api_key: "sk-test-key",
          base_url: "https://api.openai.com",
          model: "gpt-4o",
          max_tokens: 100,
          provider: "openai",
        },
      )
      service.expects(:translate_title_fallback).returns("Fallback Title")

      result = service.call
      expect(result.failure?).to be false
      expect(result[:translation].translated_title).to eq("Fallback Title")
    end

    it "skips fallback when api config returns error" do
      service = build_service
      service.stubs(:call_openai_api).returns(
        {
          translated_text: "<p>Hola mundo</p>",
          translated_title: nil,
          source_language: "auto",
          confidence: 0.95,
          provider_info: {
            model: "gpt-4o",
            provider: "openai",
          },
        },
      )
      service.stubs(:get_api_config).returns({ error: "Invalid preset model" })
      service.expects(:translate_title_fallback).never

      result = service.call
      expect(result.failure?).to be false
      expect(result[:translation].translated_title).to be_nil
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

  describe "prepare_content_for_translation (tripwire)" do
    it "uses post.cooked as translation input" do
      post_with_cooked =
        Fabricate(:post, topic: topic, user: user, raw: "Hello world", post_number: 3)
      service = build_service(post: post_with_cooked)

      request_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |req|
          request_body = req.body
          true
        end
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: '{"translated_content": "<p>Hola mundo</p>"}' } }],
            model: "gpt-4o",
            usage: {
              total_tokens: 50,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        )

      result = service.call
      expect(result.failure?).to be false

      parsed = JSON.parse(request_body)
      prompt = parsed["messages"].first["content"]
      expect(prompt).to include(post_with_cooked.cooked)
    end
  end

  describe "prepare_title_for_translation" do
    it "returns nil when topic title is blank" do
      topic.update_column(:title, "")

      stub_openai_success(translated_title: nil)
      result = build_service.call
      expect(result.failure?).to be false
    end

    it "returns nil when translate_title setting is disabled" do
      SiteSetting.babel_reunited_translate_title = false
      stub_openai_success(translated_title: nil)

      result = build_service.call
      expect(result.failure?).to be false
    end

    it "returns title when conditions are met" do
      SiteSetting.babel_reunited_translate_title = true
      stub_openai_success(translated_title: "Titulo traducido")

      result = build_service.call
      expect(result[:translation].translated_title).to eq("Titulo traducido")
    end
  end

  describe "get_max_content_length" do
    it "uses SiteSetting for custom provider" do
      SiteSetting.babel_reunited_max_content_length = 5000
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        {
          provider: "custom",
          model_name: "my-model",
          base_url: "https://example.com",
          api_key: "sk-test-key",
          max_tokens: nil,
        },
      )

      long_post =
        Fabricate(:post, topic: topic, user: user, cooked: "<p>#{"a" * 5001}</p>", post_number: 4)
      stub_openai_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Content too long")
    end

    it "uses max_tokens * 3 for preset providers" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        {
          provider: "openai",
          model_name: "gpt-4o",
          base_url: "https://api.openai.com",
          api_key: "sk-test-key",
          max_tokens: 1000,
          max_output_tokens: 500,
          api_key_setting: :babel_reunited_openai_api_key,
        },
      )

      long_post =
        Fabricate(:post, topic: topic, user: user, cooked: "<p>#{"a" * 3001}</p>", post_number: 5)
      stub_openai_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Content too long")
    end

    it "falls back to SiteSetting when max_tokens is nil for preset" do
      SiteSetting.babel_reunited_max_content_length = 2000
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        {
          provider: "openai",
          model_name: "gpt-4o",
          base_url: "https://api.openai.com",
          api_key: "sk-test-key",
          max_tokens: nil,
          max_output_tokens: nil,
          api_key_setting: :babel_reunited_openai_api_key,
        },
      )

      long_post =
        Fabricate(:post, topic: topic, user: user, cooked: "<p>#{"a" * 2001}</p>", post_number: 6)
      stub_openai_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Content too long")
    end
  end

  describe "handle_openai_error" do
    it "handles 400 bad request with error message" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 400,
        body: { error: { message: "Invalid model specified" } }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Bad request")
      expect(result[:error]).to include("Invalid model specified")
    end

    it "handles unknown status codes" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 403,
        body: { error: "Forbidden" }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("API error")
    end

    it "extracts nested error message" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 400,
        body: {
          error: {
            message: "Content filtering triggered",
            type: "invalid_request",
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("Content filtering triggered")
    end

    it "handles non-JSON error body" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 502,
        body: "Bad Gateway",
        headers: {
          "Content-Type" => "text/plain",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result[:error]).to include("temporarily unavailable")
    end
  end

  describe "try_parse_json_response" do
    it "returns nil when response has no JSON content" do
      response_body = {
        choices: [{ message: { content: "Just plain text, no JSON here" } }],
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
      expect(result.failure?).to be true
      expect(result[:error]).to include("Failed to parse JSON response")
    end

    it "returns nil when JSON has no translated_content" do
      response_body = {
        choices: [{ message: { content: '{"other_key": "value"}' } }],
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
      expect(result.failure?).to be true
      expect(result[:error]).to include("Failed to parse JSON response")
    end
  end

  describe "extract_from_incomplete_json" do
    it "handles content with simple escaped content" do
      json_content = '{"translated_content": "<p>Hola mundo bonito</p>", "translated_ti'

      response_body = {
        choices: [{ message: { content: json_content } }],
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
      expect(result.failure?).to be false
      expect(result[:translation].translated_content).to include("Hola mundo bonito")
    end

    it "returns error when no match found" do
      response_body = {
        choices: [{ message: { content: '{"translated_content": "<p>incomplete' } }],
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
      expect(result.failure?).to be true
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
