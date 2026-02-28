# frozen_string_literal: true

module BabelReunited
  class TranslationLogger
    LOG_FILE_PATH = Rails.root.join("log", "babel_reunited_translation.log")

    def self.logger
      @logger ||=
        begin
          FileUtils.mkdir_p(File.dirname(LOG_FILE_PATH))
          logger = Logger.new(LOG_FILE_PATH)
          logger.formatter = proc { |_sev, _time, _prog, msg| "#{msg}\n" }
          logger
        end
    end

    def self.log_translation_start(post_id:, target_language:, content_length:, force_update: false)
      write_log(
        event: "translation_started",
        post_id: post_id,
        target_language: target_language,
        content_length: content_length,
        force_update: force_update,
        status: "started",
      )
    end

    def self.log_translation_success(
      post_id:,
      target_language:,
      translation_id:,
      ai_response:,
      processing_time:,
      force_update: false
    )
      model_name = ai_response.dig(:provider_info, :model) || ai_response[:model] || "unknown"

      write_log(
        event: "translation_completed",
        post_id: post_id,
        target_language: target_language,
        translation_id: translation_id,
        status: "success",
        force_update: force_update,
        processing_time_ms: processing_time,
        ai_model: model_name,
        ai_usage:
          if ai_response.dig(:provider_info, :tokens_used)
            { tokens_used: ai_response.dig(:provider_info, :tokens_used) }
          else
            {}
          end,
        translated_length: ai_response[:translated_text]&.length || 0,
      )
    end

    def self.log_translation_error(
      post_id:,
      target_language:,
      error:,
      processing_time:,
      context: {}
    )
      write_log(
        event: "translation_failed",
        post_id: post_id,
        target_language: target_language,
        status: "error",
        error_message: error.message,
        error_class: error.class.name,
        backtrace:
          (error.respond_to?(:backtrace) && error.backtrace ? error.backtrace.first(10) : nil),
        processing_time_ms: processing_time,
        context: context.presence,
      )
    end

    def self.log_translation_skipped(post_id:, target_language:, reason:)
      write_log(
        event: "translation_skipped",
        post_id: post_id,
        target_language: target_language,
        status: "skipped",
        reason: reason,
      )
    end

    def self.log_provider_response(
      post_id:,
      target_language:,
      status:,
      body:,
      phase:,
      provider: nil
    )
      write_log(
        event: "provider_response",
        post_id: post_id,
        target_language: target_language,
        status_code: status,
        provider: provider,
        phase: phase,
        body: body,
      )
    end

    private

    def self.write_log(log_entry)
      log_entry[:timestamp] = Time.current.iso8601
      logger.info(JSON.generate(log_entry))
    rescue => e
      Rails.logger.error("Failed to write translation log: #{e.message}")
    end
  end
end
