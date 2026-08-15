# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe BabelReunited::ProviderClient do
  before do
    enable_current_plugin
    Discourse.redis.flushdb
  end

  let(:config) do
    {
      provider: "openai",
      wire: :openai,
      model_name: "gpt-9",
      base_url: "https://api.openai.com",
      path: "/v1/chat/completions",
      api_key: "sk-test-key",
      output_token_param: :max_tokens,
      supports_temperature: true
    }
  end

  def client(overrides = {}, on_response: nil)
    described_class.new(
      config: config.merge(overrides),
      timeout: 5,
      on_response: on_response
    )
  end

  def post(client)
    client.post(messages: [{ role: "user", content: "hi" }], max_tokens: 100)
  end

  def ok_body
    {
      choices: [{ message: { content: "hola" }, finish_reason: "stop" }],
      model: "gpt-9"
    }.to_json
  end

  def bad_request(message)
    {
      status: 400,
      body: { error: { message: message } }.to_json,
      headers: {
        "Content-Type" => "application/json"
      }
    }
  end

  it "sends the configured parameters" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200,
      body: ok_body,
      headers: {
        "Content-Type" => "application/json"
      }
    )

    post(client)

    expect(
      a_request(:post, "https://api.openai.com/v1/chat/completions").with do |r|
        body = JSON.parse(r.body)
        body["max_tokens"] == 100 && body["temperature"] == 0.3
      end
    ).to have_been_made
  end

  # ModelTraits reads the model's name, so a name it has no rule for can
  # guess wrong. The provider names the parameter it rejected.
  describe "parameter fallback" do
    it "switches to max_completion_tokens when max_tokens is rejected" do
      bodies = []
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return do |request|
        bodies << JSON.parse(request.body)
        if bodies.size == 1
          bad_request(
            "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
          )
        else
          {
            status: 200,
            body: ok_body,
            headers: {
              "Content-Type" => "application/json"
            }
          }
        end
      end

      response = post(client)

      expect(response.status).to eq(200)
      expect(bodies.first).to have_key("max_tokens")
      expect(bodies.last).to have_key("max_completion_tokens")
      expect(bodies.last).not_to have_key("max_tokens")
    end

    it "switches back to max_tokens when max_completion_tokens is rejected" do
      bodies = []
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return do |request|
        bodies << JSON.parse(request.body)
        if bodies.size == 1
          bad_request("Unrecognized request argument: max_completion_tokens")
        else
          {
            status: 200,
            body: ok_body,
            headers: {
              "Content-Type" => "application/json"
            }
          }
        end
      end

      response = post(client({ output_token_param: :max_completion_tokens }))

      expect(response.status).to eq(200)
      expect(bodies.last).to have_key("max_tokens")
    end

    it "drops temperature when the provider rejects it" do
      bodies = []
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return do |request|
        bodies << JSON.parse(request.body)
        if bodies.size == 1
          bad_request(
            "Unsupported value: 'temperature' does not support 0.3 with this model."
          )
        else
          {
            status: 200,
            body: ok_body,
            headers: {
              "Content-Type" => "application/json"
            }
          }
        end
      end

      response = post(client)

      expect(response.status).to eq(200)
      expect(bodies.first).to have_key("temperature")
      expect(bodies.last).not_to have_key("temperature")
    end

    it "retries only once" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(bad_request("'max_tokens' is not supported"))

      response = post(client)

      expect(response.status).to eq(400)
      expect(
        a_request(:post, "https://api.openai.com/v1/chat/completions")
      ).to have_been_made.twice
    end

    it "does not retry a 400 about something else" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(bad_request("The model `gpt-9` does not exist"))

      response = post(client)

      expect(response.status).to eq(400)
      expect(
        a_request(:post, "https://api.openai.com/v1/chat/completions")
      ).to have_been_made.once
    end

    it "does not retry a non-400 failure" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(status: 500, body: "max_tokens exploded")

      response = post(client)

      expect(response.status).to eq(500)
      expect(
        a_request(:post, "https://api.openai.com/v1/chat/completions")
      ).to have_been_made.once
    end

    # The Anthropic format names its output cap unconditionally, so asking
    # again with the other name sends byte-identical JSON.
    it "does not retry a wire whose body ignores the token parameter" do
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
        bad_request("max_tokens: 40000 > 8192, which is the maximum")
      )

      response =
        post(
          client(
            {
              provider: "anthropic",
              wire: :anthropic,
              base_url: "https://api.anthropic.com",
              path: "/v1/messages"
            }
          )
        )

      expect(response.status).to eq(400)
      expect(
        a_request(:post, "https://api.anthropic.com/v1/messages")
      ).to have_been_made.once
    end

    # Charging once around the whole exchange let a retrying request spend
    # twice its allowance and stay invisible to the daily counter.
    it "charges the rate limit for each attempt it makes" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(bad_request("'max_tokens' is not supported"))

      BabelReunited::RateLimiter
        .expects(:perform_request_if_allowed)
        .twice
        .returns(true)

      post(client)
    end

    # Without remembering the correction, every later request repeats the
    # rejected guess. At a rate limit of one call a minute that is fatal: the
    # wrong guess spends the allowance, the corrected attempt is refused
    # before it is sent, and the retry starts from the wrong guess again.
    it "remembers a correction so the next request starts from it" do
      calls = 0
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return do |request|
        calls += 1
        if JSON.parse(request.body).key?("max_tokens")
          bad_request("'max_tokens' is not supported")
        else
          {
            status: 200,
            body: ok_body,
            headers: {
              "Content-Type" => "application/json"
            }
          }
        end
      end

      post(client)
      expect(calls).to eq(2)

      post(client)

      expect(calls).to eq(3)
      expect(
        a_request(
          :post,
          "https://api.openai.com/v1/chat/completions"
        ).with { |r| JSON.parse(r.body).key?("max_tokens") }
      ).to have_been_made.once
    end

    it "does not remember a correction that also failed" do
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(bad_request("'max_tokens' is not supported"))

      post(client)

      expect(
        Discourse.redis.get("babel_reunited:model_traits:openai:gpt-9")
      ).to be_nil
    end

    it "reports every attempt to the caller's logger" do
      seen = []
      stub_request(
        :post,
        "https://api.openai.com/v1/chat/completions"
      ).to_return(bad_request("'max_tokens' is not supported"))

      post(client({}, on_response: ->(resp) { seen << resp.status }))

      expect(seen).to eq([400, 400])
    end
  end
end
