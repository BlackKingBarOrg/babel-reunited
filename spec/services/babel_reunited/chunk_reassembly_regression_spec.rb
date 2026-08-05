# frozen_string_literal: true

require "webmock/rspec"

# Regression coverage for the chunk-boundary whitespace bug that corrupted
# translations of long posts on talk.nervos.org (topics 10225 / 10360 / 10419).
#
# The fixtures are the verbatim `raw` of those three posts, kept at full size
# on purpose: the bug only appeared once a post was long enough to split at a
# fenced code block, which no hand-written sample had reproduced. Each one is
# driven through the real pipeline (ContentSplitter -> MarkdownProtector ->
# strip_llm_wrapper -> join) with an LLM stub that echoes its input back, so
# translation acts as the identity function and any difference between
# `post.raw` and `translated_raw` is pipeline loss.
RSpec.describe BabelReunited::TranslationService do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) do
    Fabricate(:post, topic: topic, user: user, post_number: 1)
  end

  # Both chunk sizes seen in production: Claude Sonnet 4.6 (16K max output)
  # and the GPT-4.1 family (32K max output).
  chunk_sizes = [16_000, 32_768]

  fixtures = %w[
    talk_10225_ickb_audit.md
    talk_10360_chiral_light_paper.md
    talk_10419_vellum_proposal.md
  ]

  def read_fixture(name)
    File.read(File.expand_path("../../fixtures/chunked_posts/#{name}", __dir__))
  end

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    SiteSetting.babel_reunited_translate_title = false
    SiteSetting.babel_reunited_rate_limit_per_minute = 600
    SiteSetting.babel_reunited_request_timeout_seconds = 30

    Discourse.redis.flushdb
  end

  def stub_config(chunk_size)
    BabelReunited::ModelConfig.stubs(:get_config).returns(
      {
        provider: "openai",
        model_name: "gpt-4o",
        base_url: "https://api.openai.com",
        api_key: "sk-test-key",
        max_tokens: 1_000_000,
        max_output_tokens: chunk_size
      }
    )
  end

  # Returns the payload the prompt wrapped, so the "translation" is an exact
  # echo of what the service asked the model to translate.
  def stub_llm_echo
    calls = 0
    stub_request(
      :post,
      "https://api.openai.com/v1/chat/completions"
    ).to_return do |request|
      calls += 1
      msg =
        JSON.parse(request.body)["messages"].find { |m| m["role"] == "user" }
      echo =
        msg["content"][
          %r{\A<translation_source>\n?(.*?)\n?</translation_source>\z}m,
          1
        ] || msg["content"]

      {
        status: 200,
        body: {
          choices: [{ message: { content: echo }, finish_reason: "stop" }],
          model: "gpt-4o",
          usage: {
            total_tokens: 10
          }
        }.to_json,
        headers: {
          "Content-Type" => "application/json"
        }
      }
    end
    -> { calls }
  end

  fixtures.each do |name|
    chunk_sizes.each do |chunk_size|
      it "reassembles #{name} losslessly at a #{chunk_size} char chunk size" do
        raw = read_fixture(name)
        post_record.stubs(:raw).returns(raw)
        stub_config(chunk_size)
        call_counter = stub_llm_echo

        result =
          described_class.new(post: post_record, target_language: "zh-cn").call

        expect(result.success?).to be true
        expect(result.translated_raw).to eq(raw)
        expect(call_counter.call).to eq(
          BabelReunited::ContentSplitter.split(
            content: raw,
            chunk_size: chunk_size
          ).size
        )
      end
    end
  end

  it "keeps fixtures large enough to exercise multi-chunk translation" do
    fixtures.each do |name|
      chunks =
        BabelReunited::ContentSplitter.split(
          content: read_fixture(name),
          chunk_size: 16_000
        )
      expect(chunks.size).to be > 1
    end
  end

  it "splits the fixtures at a fenced code block" do
    raw = read_fixture("talk_10225_ickb_audit.md")
    chunks =
      BabelReunited::ContentSplitter.split(content: raw, chunk_size: 16_000)

    expect(chunks[0..-2]).to include(a_string_matching(/```\s*\z/))
  end
end
