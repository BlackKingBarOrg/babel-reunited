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

  def stub_llm_success(content: "Hola mundo", title_content: "Titulo traducido")
    # Main translation request
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
      body = JSON.parse(request.body)
      prompt = body["messages"].first["content"]

      response_text =
        if prompt.include?("Return ONLY the translated text, no quotes, no extra words")
          title_content
        else
          content
        end

      {
        status: 200,
        body: {
          choices: [{ message: { content: response_text } }],
          model: "gpt-4o",
          usage: {
            total_tokens: 100,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      }
    end
  end

  describe "Result struct" do
    it "reports success when no error" do
      result = described_class::Result.new(translated_raw: "text")
      expect(result.success?).to be true
      expect(result.failure?).to be false
    end

    it "reports failure when error present" do
      result = described_class::Result.new(error: "something went wrong")
      expect(result.success?).to be false
      expect(result.failure?).to be true
    end
  end

  describe "input validation" do
    it "returns error for blank post" do
      result = described_class.new(post: nil, target_language: "es").call
      expect(result.failure?).to be true
      expect(result.error).to eq("Post not found")
    end

    it "returns error for blank target_language" do
      result = build_service(target_language: "").call
      expect(result.failure?).to be true
      expect(result.error).to eq("Target language not specified")
    end
  end

  describe "API configuration errors" do
    it "returns error when API key is not configured" do
      SiteSetting.babel_reunited_openai_api_key = ""

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("API key not configured")
    end

    it "returns error when model config is nil" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(nil)

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Invalid preset model")
    end

    it "returns error when base_url is missing" do
      BabelReunited::ModelConfig.stubs(:get_config).returns(
        { provider: "openai", model_name: "gpt-4o", base_url: nil, api_key: "sk-test-key" },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Base URL not configured")
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
      expect(result.error).to include("Model name not configured")
    end
  end

  describe "rate limiting" do
    it "raises RateLimitError when rate limit exceeded" do
      BabelReunited::RateLimiter.stubs(:perform_request_if_allowed).returns(false)
      stub_llm_success

      expect { build_service.call }.to raise_error(
        BabelReunited::RateLimitError,
        "Local rate limit exceeded",
      )
    end
  end

  describe "content length check" do
    it "returns error when content is too long" do
      long_post = Fabricate(:post, topic: topic, user: user, post_number: 2)
      long_post.stubs(:raw).returns("a" * 500_000)

      stub_llm_success
      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result.error).to include("Content too long")
    end
  end

  describe "successful translation" do
    it "returns translated_raw in result" do
      stub_llm_success(content: "Hola mundo")

      result = build_service.call
      expect(result.success?).to be true
      expect(result.translated_raw).to eq("Hola mundo")
      expect(result.source_language).to eq("auto")
    end

    it "includes ai_response metadata" do
      stub_llm_success

      result = build_service.call
      expect(result.ai_response).to be_present
      expect(result.ai_response[:confidence]).to eq(0.95)
      expect(result.ai_response[:provider_info][:model]).to eq("gpt-4o")
    end

    it "records the request for rate limiting" do
      stub_llm_success

      expect { build_service.call }.to change {
        60 - BabelReunited::RateLimiter.remaining_requests
      }.by_at_least(1)
    end
  end

  describe "title translation" do
    it "translates title for first post" do
      stub_llm_success(title_content: "Titulo traducido")

      result = build_service.call
      expect(result.translated_title).to eq("Titulo traducido")
    end

    it "does not translate title for non-first posts" do
      non_first_post = Fabricate(:post, topic: topic, user: user, post_number: 2)
      stub_llm_success

      result = build_service(post: non_first_post).call
      expect(result.success?).to be true
      expect(result.translated_title).to be_nil
    end

    it "does not translate title when translate_title is disabled" do
      SiteSetting.babel_reunited_translate_title = false
      stub_llm_success

      result = build_service.call
      expect(result.success?).to be true
      expect(result.translated_title).to be_nil
    end
  end

  describe "markdown protection" do
    it "sends post.raw (not cooked) to the LLM" do
      post_with_raw =
        Fabricate(:post, topic: topic, user: user, raw: "Hello **bold** world", post_number: 3)

      request_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |req|
          request_body = req.body
          true
        end
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: "Hola **negrita** mundo" } }],
            model: "gpt-4o",
            usage: {
              total_tokens: 50,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        )

      result = build_service(post: post_with_raw).call
      expect(result.success?).to be true

      parsed = JSON.parse(request_body)
      prompt = parsed["messages"].first["content"]
      expect(prompt).to include("Hello **bold** world")
      expect(prompt).not_to include("<p>")
    end

    it "protects code blocks in the prompt" do
      post_with_code =
        Fabricate(
          :post,
          topic: topic,
          user: user,
          raw: "Hello\n```ruby\ndef foo\nend\n```\nWorld",
          post_number: 4,
        )

      # Pre-compute the token so the stub can echo it back
      protector = BabelReunited::MarkdownProtector.new(post_with_code.raw)
      _protected, tokens = protector.protect
      token_key = tokens.keys.first

      request_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |req|
          request_body = req.body
          true
        end
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: "Hola\n#{token_key}\nMundo" } }],
            model: "gpt-4o",
            usage: {
              total_tokens: 50,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        )

      # Stub MarkdownProtector.new to return the same instance with same salt
      BabelReunited::MarkdownProtector.stubs(:new).returns(protector)
      # Re-initialize so protect can run again
      protector.instance_variable_set(:@counter, 0)
      protector.instance_variable_set(:@tokens, {})

      result = build_service(post: post_with_code).call
      expect(result.success?).to be true

      parsed = JSON.parse(request_body)
      prompt = parsed["messages"].first["content"]
      expect(prompt).to include("\u27E6")
      expect(prompt).not_to include("def foo")

      expect(result.translated_raw).to include("```ruby\ndef foo\nend\n```")
    end
  end

  describe "strip_llm_wrapper" do
    it "strips 'Here is the translation:' preamble" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          choices: [{ message: { content: "Here is the translation:\nHola mundo" } }],
          model: "gpt-4o",
          usage: {
            total_tokens: 50,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      SiteSetting.babel_reunited_translate_title = false
      result = build_service.call
      expect(result.translated_raw).to eq("Hola mundo")
    end

    it "strips markdown code block wrapping" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          choices: [{ message: { content: "```\nHola mundo\n```" } }],
          model: "gpt-4o",
          usage: {
            total_tokens: 50,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      SiteSetting.babel_reunited_translate_title = false
      result = build_service.call
      expect(result.translated_raw).to eq("Hola mundo")
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

      long_post = Fabricate(:post, topic: topic, user: user, post_number: 5)
      long_post.stubs(:raw).returns("a" * 5001)
      stub_llm_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result.error).to include("Content too long")
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
        },
      )

      long_post = Fabricate(:post, topic: topic, user: user, post_number: 6)
      long_post.stubs(:raw).returns("a" * 3001)
      stub_llm_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result.error).to include("Content too long")
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
        },
      )

      long_post = Fabricate(:post, topic: topic, user: user, post_number: 7)
      long_post.stubs(:raw).returns("a" * 2001)
      stub_llm_success

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result.error).to include("Content too long")
    end
  end

  describe "API error handling" do
    it "handles 400 bad request" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 400,
        body: { error: { message: "Invalid model specified" } }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Bad request")
      expect(result.error).to include("Invalid model specified")
    end

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
      expect(result.error).to include("Invalid API key")
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
      expect(result.error).to include("Rate limit exceeded")
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
      expect(result.error).to include("temporarily unavailable")
    end

    it "handles network errors" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_raise(
        Faraday::ConnectionFailed.new("connection refused"),
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Network error")
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
      expect(result.error).to include("API error")
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
      expect(result.error).to include("temporarily unavailable")
    end
  end

  describe "response parsing edge cases" do
    it "handles empty response content" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          choices: [{ message: { content: "" } }],
          model: "gpt-4o",
          usage: {
            total_tokens: 50,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("No translation in response")
    end

    it "handles missing choices in response" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: { model: "gpt-4o" }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Invalid response format")
    end
  end

  describe "chunked translation" do
    it "splits long content into multiple chunks and joins results" do
      long_raw = "Paragraph one.\n\n" + "Paragraph two.\n\n" + "Paragraph three."
      long_post = Fabricate(:post, topic: topic, user: user, raw: long_raw, post_number: 10)

      SiteSetting.babel_reunited_translate_title = false
      call_count = 0
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |_request|
        call_count += 1
        {
          status: 200,
          body: {
            choices: [
              { message: { content: "Translated chunk #{call_count}" }, finish_reason: "stop" },
            ],
            model: "gpt-4o",
            usage: {
              total_tokens: 50,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        }
      end

      BabelReunited::ContentSplitter.stubs(:split).returns(
        ["Paragraph one.\n\n", "Paragraph two.\n\n", "Paragraph three."],
      )

      result = build_service(post: long_post).call
      expect(result.success?).to be true
      expect(call_count).to eq(3)
    end

    it "preserves paragraph boundaries via whitespace extraction" do
      long_raw = "First para.\n\nSecond para."
      long_post = Fabricate(:post, topic: topic, user: user, raw: long_raw, post_number: 11)

      SiteSetting.babel_reunited_translate_title = false
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
        body = JSON.parse(request.body)
        prompt = body["messages"].first["content"]

        translated =
          if prompt.include?("First")
            "Primer parrafo."
          else
            "Segundo parrafo."
          end

        {
          status: 200,
          body: {
            choices: [{ message: { content: translated }, finish_reason: "stop" }],
            model: "gpt-4o",
            usage: {
              total_tokens: 50,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        }
      end

      BabelReunited::ContentSplitter.stubs(:split).returns(["First para.\n\n", "Second para."])

      result = build_service(post: long_post).call
      expect(result.success?).to be true
      expect(result.translated_raw).to eq("Primer parrafo.\n\nSegundo parrafo.")
    end

    it "rejects posts exceeding MAX_CHUNKS" do
      long_post = Fabricate(:post, topic: topic, user: user, post_number: 12)
      long_post.stubs(:raw).returns("text")

      SiteSetting.babel_reunited_translate_title = false
      chunks = (1..6).map { |i| "Chunk #{i}. " }
      BabelReunited::ContentSplitter.stubs(:split).returns(chunks)

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
      expect(result.error).to include("6 chunks, max 5")
    end

    it "sums tokens_used across chunks" do
      long_post = Fabricate(:post, topic: topic, user: user, post_number: 13)
      long_post.stubs(:raw).returns("text")

      SiteSetting.babel_reunited_translate_title = false
      call_count = 0
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |_request|
        call_count += 1
        {
          status: 200,
          body: {
            choices: [{ message: { content: "Translated #{call_count}" }, finish_reason: "stop" }],
            model: "gpt-4o",
            usage: {
              total_tokens: 100,
            },
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
          },
        }
      end

      BabelReunited::ContentSplitter.stubs(:split).returns(%w[chunk1 chunk2])

      result = build_service(post: long_post).call
      expect(result.success?).to be true
      expect(result.ai_response[:provider_info][:tokens_used]).to eq(200)
    end

    it "fails entire translation when one chunk fails" do
      long_post = Fabricate(:post, topic: topic, user: user, post_number: 14)
      long_post.stubs(:raw).returns("text")

      SiteSetting.babel_reunited_translate_title = false
      call_count = 0
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |_request|
        call_count += 1
        if call_count == 2
          {
            status: 500,
            body: { error: "Server error" }.to_json,
            headers: {
              "Content-Type" => "application/json",
            },
          }
        else
          {
            status: 200,
            body: {
              choices: [{ message: { content: "OK" }, finish_reason: "stop" }],
              model: "gpt-4o",
              usage: {
                total_tokens: 50,
              },
            }.to_json,
            headers: {
              "Content-Type" => "application/json",
            },
          }
        end
      end

      BabelReunited::ContentSplitter.stubs(:split).returns(%w[chunk1 chunk2 chunk3])

      result = build_service(post: long_post).call
      expect(result.failure?).to be true
    end

    it "treats single-chunk content same as before" do
      stub_llm_success(content: "Hola mundo")
      SiteSetting.babel_reunited_translate_title = false

      result = build_service.call
      expect(result.success?).to be true
      expect(result.translated_raw).to eq("Hola mundo")
    end
  end

  describe "finish_reason truncation detection" do
    it "returns error when finish_reason is length" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          choices: [{ message: { content: "Partial translation..." }, finish_reason: "length" }],
          model: "gpt-4o",
          usage: {
            total_tokens: 16_000,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      SiteSetting.babel_reunited_translate_title = false
      result = build_service.call
      expect(result.failure?).to be true
      expect(result.error).to include("Translation truncated")
    end

    it "succeeds when finish_reason is stop" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          choices: [{ message: { content: "Complete translation" }, finish_reason: "stop" }],
          model: "gpt-4o",
          usage: {
            total_tokens: 100,
          },
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
        },
      )

      SiteSetting.babel_reunited_translate_title = false
      result = build_service.call
      expect(result.success?).to be true
      expect(result.translated_raw).to eq("Complete translation")
    end
  end
end
