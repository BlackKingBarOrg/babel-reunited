# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationLogger do
  before do
    enable_current_plugin
    allow(File).to receive(:open).and_call_original
  end

  def captured_log_entry
    log_entry = nil
    allow(File).to receive(:open).with(described_class::LOG_FILE_PATH, "a") do |*, &block|
      fake_file = StringIO.new
      block.call(fake_file)
      log_entry = JSON.parse(fake_file.string)
    end
    yield
    log_entry
  end

  describe ".log_translation_start" do
    it "writes a JSON log entry" do
      entry =
        captured_log_entry do
          described_class.log_translation_start(
            post_id: 1,
            target_language: "es",
            content_length: 500,
          )
        end

      expect(entry).to be_present
      expect(entry["event"]).to eq("translation_started")
    end

    it "includes correct fields" do
      entry =
        captured_log_entry do
          described_class.log_translation_start(
            post_id: 42,
            target_language: "zh-cn",
            content_length: 1234,
            force_update: true,
          )
        end

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
      entry =
        captured_log_entry do
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
        end

      expect(entry["event"]).to eq("translation_completed")
      expect(entry["status"]).to eq("success")
      expect(entry["processing_time_ms"]).to eq(1500.5)
    end

    it "extracts model from provider_info" do
      entry =
        captured_log_entry do
          described_class.log_translation_success(
            **base_args,
            ai_response: {
              translated_text: "Hola",
              provider_info: {
                model: "gpt-4o",
              },
            },
          )
        end

      expect(entry["ai_model"]).to eq("gpt-4o")
    end

    it "falls back to top-level :model key" do
      entry =
        captured_log_entry do
          described_class.log_translation_success(
            **base_args,
            ai_response: {
              translated_text: "Hola",
              model: "claude-3",
              provider_info: {
              },
            },
          )
        end

      expect(entry["ai_model"]).to eq("claude-3")
    end

    it "defaults to unknown when no model" do
      entry =
        captured_log_entry do
          described_class.log_translation_success(
            **base_args,
            ai_response: {
              translated_text: "Hola",
            },
          )
        end

      expect(entry["ai_model"]).to eq("unknown")
    end

    it "includes ai_usage when tokens_used present" do
      entry =
        captured_log_entry do
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
        end

      expect(entry["ai_usage"]).to eq({ "tokens_used" => 250 })
    end
  end

  describe ".log_translation_error" do
    it "writes correct event" do
      error = StandardError.new("something broke")
      error.set_backtrace(%w[line1 line2])

      entry =
        captured_log_entry do
          described_class.log_translation_error(
            post_id: 1,
            target_language: "es",
            error: error,
            processing_time: 300,
          )
        end

      expect(entry["event"]).to eq("translation_failed")
      expect(entry["status"]).to eq("error")
    end

    it "includes error details" do
      error = RuntimeError.new("API timeout")
      error.set_backtrace(Array.new(15) { |i| "frame_#{i}" })

      entry =
        captured_log_entry do
          described_class.log_translation_error(
            post_id: 5,
            target_language: "fr",
            error: error,
            processing_time: 500,
            context: {
              phase: "provider_error",
            },
          )
        end

      expect(entry["error_message"]).to eq("API timeout")
      expect(entry["error_class"]).to eq("RuntimeError")
      expect(entry["backtrace"].length).to eq(10)
      expect(entry["context"]).to eq({ "phase" => "provider_error" })
    end

    it "handles errors without backtrace" do
      error = StandardError.new("no trace")

      entry =
        captured_log_entry do
          described_class.log_translation_error(
            post_id: 1,
            target_language: "es",
            error: error,
            processing_time: 0,
          )
        end

      expect(entry["backtrace"]).to be_nil
    end
  end

  describe ".log_translation_skipped" do
    it "writes event with reason" do
      entry =
        captured_log_entry do
          described_class.log_translation_skipped(
            post_id: 1,
            target_language: "es",
            reason: "post_not_found",
          )
        end

      expect(entry["event"]).to eq("translation_skipped")
      expect(entry["status"]).to eq("skipped")
      expect(entry["reason"]).to eq("post_not_found")
    end
  end

  describe ".log_provider_response" do
    it "writes event with provider and phase" do
      entry =
        captured_log_entry do
          described_class.log_provider_response(
            post_id: 1,
            target_language: "es",
            status: 200,
            body: '{"choices":[]}',
            phase: "post_chat_completions",
            provider: "openai",
          )
        end

      expect(entry["event"]).to eq("provider_response")
      expect(entry["status_code"]).to eq(200)
      expect(entry["body"]).to eq('{"choices":[]}')
      expect(entry["phase"]).to eq("post_chat_completions")
      expect(entry["provider"]).to eq("openai")
    end
  end

  describe "write failure resilience" do
    it "does not raise when file write fails" do
      allow(File).to receive(:open).with(described_class::LOG_FILE_PATH, "a").and_raise(
        Errno::EACCES,
      )

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
