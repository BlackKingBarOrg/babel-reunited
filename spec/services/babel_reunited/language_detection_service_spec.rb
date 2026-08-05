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

    it "does not retry content that is too short to detect" do
      post_record.update_columns(raw: "hi")

      result = described_class.new(post: post_record).call
      expect(result.failure?).to be true
      expect(result.retryable?).to be false
    end
  end
end
