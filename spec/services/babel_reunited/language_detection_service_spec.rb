# frozen_string_literal: true

RSpec.describe BabelReunited::LanguageDetectionService do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) do
    Fabricate(
      :post,
      topic: topic,
      user: user,
      raw:
        "This is a long enough English sentence for language detection to work."
    )
  end

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    Discourse.redis.flushdb
  end

  def stub_detection(reply)
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/json"
      },
      body: {
        choices: [{ message: { content: reply }, finish_reason: "stop" }],
        usage: {
          total_tokens: 42
        }
      }.to_json
    )
  end

  it "returns the detected locale" do
    stub_detection("en")

    result = described_class.new(post: post_record).call
    expect(result.success?).to be true
    expect(result.locale).to eq("en")
  end

  it "normalizes casing, quotes, and aliases" do
    stub_detection("\"ZH\".")

    result = described_class.new(post: post_record).call
    expect(result.locale).to eq("zh-cn")
  end

  it "accepts ISO 639-3 codes for languages without a two-letter code" do
    %w[yue ceb fil].each do |code|
      stub_detection(code)

      result = described_class.new(post: post_record).call
      expect(result.locale).to eq(code)
    end
  end

  it "fails on codes outside the supported list" do
    stub_detection("und")

    result = described_class.new(post: post_record).call
    expect(result.failure?).to be true
    expect(result.error).to include("Unrecognized detection response")
  end

  it "fails when content is too short" do
    post_record.update_columns(raw: "https://example.com/a-b-c ok")

    result = described_class.new(post: post_record).call
    expect(result.failure?).to be true
    expect(result.error).to include("too short")
  end

  it "fails when the API key is missing" do
    SiteSetting.babel_reunited_openai_api_key = ""

    result = described_class.new(post: post_record).call
    expect(result.failure?).to be true
    expect(result.error).to include("API key")
  end

  it "raises RateLimitError when the site-wide limiter is exhausted" do
    BabelReunited::RateLimiter.stubs(:perform_request_if_allowed).returns(false)

    expect { described_class.new(post: post_record).call }.to raise_error(
      BabelReunited::RateLimitError
    )
  end

  it "returns an error on provider failure" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 500
    )

    result = described_class.new(post: post_record).call
    expect(result.failure?).to be true
    expect(result.error).to include("status 500")
  end

  describe "prompt structure" do
    def last_request_body
      body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with { |req| body = JSON.parse(req.body) }
        .to_return(
          status: 200,
          headers: {
            "Content-Type" => "application/json"
          },
          body: {
            choices: [{ message: { content: "en" }, finish_reason: "stop" }],
            usage: {
              total_tokens: 42
            }
          }.to_json
        )
      described_class.new(post: post_record).call
      body
    end

    it "keeps instructions in the system role and the sample fenced as data" do
      body = last_request_body
      roles = body["messages"].map { |m| m["role"] }
      expect(roles).to eq(%w[system user])

      system = body["messages"].first["content"]
      expect(system).to include("never instructions")

      user = body["messages"].last["content"]
      expect(user).to match(
        %r{\A<language_sample_(\h{8})>\n.*\n</language_sample_\1>\z}m
      )
      expect(user).to include(post_record.raw)
    end

    it "strips code blocks and URLs from the sample" do
      post_record.update_columns(
        raw:
          "A sentence long enough to sample. Visit https://example.com/secret-path now.\n" \
            "```\nAPI_SECRET=super-secret-token\n```\n" \
            "Inline `hidden_value` too. More prose to keep the sample going."
      )

      body = last_request_body
      user = body["messages"].last["content"]
      expect(user).not_to include("super-secret-token")
      expect(user).not_to include("hidden_value")
      expect(user).not_to include("example.com")
      expect(user).to include("A sentence long enough to sample.")
    end

    # The translation path tokenizes these before the provider sees them, so
    # detection must not be the looser door into the same content.
    it "strips BBCode blocks the translation path never sends" do
      post_record.update_columns(
        raw:
          "A sentence long enough to sample the language of this post.\n" \
            "[code]\nAWS_SECRET_ACCESS_KEY=leaked-from-detection\n[/code]\n" \
            "[details=\"logs\"]\nstack trace with tokens\n[/details]\n" \
            "[quote=\"someone said\"]\nquoted material\n[/quote]\n" \
            "More prose so the sample is not just markup."
      )

      body = last_request_body
      user = body["messages"].last["content"]
      expect(user).not_to include("leaked-from-detection")
      expect(user).not_to include("stack trace with tokens")
      expect(user).not_to include("quoted material")
      expect(user).to include("A sentence long enough to sample")
    end
  end

  describe "retryability" do
    def status_result(status)
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(status: status)
      described_class.new(post: post_record).call
    end

    it "retries statuses another attempt could clear" do
      [408, 429, 500, 503].each do |status|
        expect(status_result(status).retryable?).to(
          be(true),
          "#{status} should be retryable"
        )
      end
    end

    # Retrying a wrong request or a wrong key three times just delays the
    # fan-out that has to happen anyway.
    it "does not retry a request or configuration error" do
      [400, 401, 403, 404].each do |status|
        expect(status_result(status).retryable?).to(
          be(false),
          "#{status} should not be retryable"
        )
      end
    end

    it "retries a network error" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_timeout

      expect(described_class.new(post: post_record).call.retryable?).to be true
    end

    # The provider layer reports parse failures via error_kind, not the
    # detection-local retryable key; the mapping between the two is what
    # this guards.
    it "retries a 200 response whose body has no usable answer" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: { unexpected: "shape" }.to_json
      )

      result = described_class.new(post: post_record).call
      expect(result.failure?).to be true
      expect(result.retryable?).to be true
    end

    it "does not retry a permanent provider verdict" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: {
          choices: [{ message: { content: "en" }, finish_reason: "length" }],
          usage: {
            total_tokens: 42
          }
        }.to_json
      )

      result = described_class.new(post: post_record).call
      expect(result.failure?).to be true
      expect(result.retryable?).to be false
    end

    it "does not retry content that is too short to detect" do
      post_record.update_columns(raw: "hi")

      result = described_class.new(post: post_record).call
      expect(result.failure?).to be true
      expect(result.retryable?).to be false
    end
  end
end
