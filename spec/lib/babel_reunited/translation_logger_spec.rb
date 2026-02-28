# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationLogger do
  before do
    enable_current_plugin
    @log_output = StringIO.new
    test_logger = Logger.new(@log_output)
    test_logger.formatter = proc { |_sev, _time, _prog, msg| "#{msg}\n" }
    described_class.instance_variable_set(:@logger, test_logger)
  end

  after { described_class.instance_variable_set(:@logger, nil) }

  def last_log_entry
    @log_output.rewind
    lines = @log_output.string.strip.split("\n")
    JSON.parse(lines.last)
  end

  describe ".log_translation_start" do
    it "writes a JSON log entry" do
      described_class.log_translation_start(post_id: 1, target_language: "es", content_length: 500)

      entry = last_log_entry
      expect(entry["event"]).to eq("translation_started")
    end

    it "includes correct fields" do
      described_class.log_translation_start(
        post_id: 42,
        target_language: "zh-cn",
        content_length: 1234,
        force_update: true,
      )

      entry = last_log_entry
      expect(entry["post_id"]).to eq(42)
      expect(entry["target_language"]).to eq("zh-cn")
      expect(entry["content_length"]).to eq(1234)
      expect(entry["force_update"]).to be true
      expect(entry["status"]).to eq("started")
      expect(entry).to have_key("timestamp")
    end
  end

  describe ".log_translation_success" do
    let(:base_args) do
      {
        post_id: 1,
        target_language: "es",
        translation_id: 10,
        processing_time: 1500.5,
        force_update: false,
      }
    end

    it "writes correct event" do
      described_class.log_translation_success(
        **base_args,
        ai_response: {
          translated_text: "Hola",
          provider_info: {
            model: "gpt-4o",
            tokens_used: 100,
          },
        },
      )

      entry = last_log_entry
      expect(entry["event"]).to eq("translation_completed")
      expect(entry["status"]).to eq("success")
      expect(entry["processing_time_ms"]).to eq(1500.5)
    end

    it "extracts model from provider_info" do
      described_class.log_translation_success(
        **base_args,
        ai_response: {
          translated_text: "Hola",
          provider_info: {
            model: "gpt-4o",
          },
        },
      )

      expect(last_log_entry["ai_model"]).to eq("gpt-4o")
    end

    it "falls back to top-level :model key" do
      described_class.log_translation_success(
        **base_args,
        ai_response: {
          translated_text: "Hola",
          model: "claude-3",
          provider_info: {},
        },
      )

      expect(last_log_entry["ai_model"]).to eq("claude-3")
    end

    it "defaults to unknown when no model" do
      described_class.log_translation_success(
        **base_args,
        ai_response: {
          translated_text: "Hola",
        },
      )

      expect(last_log_entry["ai_model"]).to eq("unknown")
    end

    it "includes ai_usage when tokens_used present" do
      described_class.log_translation_success(
        **base_args,
        ai_response: {
          translated_text: "Hola",
          provider_info: {
            model: "gpt-4o",
            tokens_used: 250,
          },
        },
      )

      expect(last_log_entry["ai_usage"]).to eq({ "tokens_used" => 250 })
    end
  end

  describe ".log_translation_error" do
    it "writes correct event" do
      error = StandardError.new("something broke")
      error.set_backtrace(%w[line1 line2])

      described_class.log_translation_error(
        post_id: 1,
        target_language: "es",
        error: error,
        processing_time: 300,
      )

      entry = last_log_entry
      expect(entry["event"]).to eq("translation_failed")
      expect(entry["status"]).to eq("error")
    end

    it "includes error details" do
      error = RuntimeError.new("API timeout")
      error.set_backtrace(Array.new(15) { |i| "frame_#{i}" })

      described_class.log_translation_error(
        post_id: 5,
        target_language: "fr",
        error: error,
        processing_time: 500,
        context: {
          phase: "provider_error",
        },
      )

      entry = last_log_entry
      expect(entry["error_message"]).to eq("API timeout")
      expect(entry["error_class"]).to eq("RuntimeError")
      expect(entry["backtrace"].length).to eq(10)
      expect(entry["context"]).to eq({ "phase" => "provider_error" })
    end

    it "handles errors without backtrace" do
      error = StandardError.new("no trace")

      described_class.log_translation_error(
        post_id: 1,
        target_language: "es",
        error: error,
        processing_time: 0,
      )

      expect(last_log_entry["backtrace"]).to be_nil
    end
  end

  describe ".log_translation_skipped" do
    it "writes event with reason" do
      described_class.log_translation_skipped(
        post_id: 1,
        target_language: "es",
        reason: "post_not_found",
      )

      entry = last_log_entry
      expect(entry["event"]).to eq("translation_skipped")
      expect(entry["status"]).to eq("skipped")
      expect(entry["reason"]).to eq("post_not_found")
    end
  end

  describe ".log_provider_response" do
    it "writes event with provider and phase" do
      described_class.log_provider_response(
        post_id: 1,
        target_language: "es",
        status: 200,
        body: '{"choices":[]}',
        phase: "post_chat_completions",
        provider: "openai",
      )

      entry = last_log_entry
      expect(entry["event"]).to eq("provider_response")
      expect(entry["status_code"]).to eq(200)
      expect(entry["body"]).to eq('{"choices":[]}')
      expect(entry["phase"]).to eq("post_chat_completions")
      expect(entry["provider"]).to eq("openai")
    end
  end

  describe "write failure resilience" do
    it "does not raise when logger write fails" do
      failing_logger = Logger.new(StringIO.new)
      failing_logger.stubs(:info).raises(Errno::EACCES)
      described_class.instance_variable_set(:@logger, failing_logger)

      expect {
        described_class.log_translation_start(
          post_id: 1,
          target_language: "es",
          content_length: 100,
        )
      }.not_to raise_error
    end
  end
end
