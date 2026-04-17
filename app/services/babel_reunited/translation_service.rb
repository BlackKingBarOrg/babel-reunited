# frozen_string_literal: true

require "faraday"
require "json"

module BabelReunited
  class TranslationService
    MAX_CHUNKS = 5

    Result =
      Struct.new(
        :translated_raw,
        :translated_title,
        :source_language,
        :ai_response,
        :error,
        keyword_init: true,
      ) do
        def success? = error.nil?
        def failure? = !success?
      end

    def initialize(post:, target_language:, force_update: false)
      @post = post
      @target_language = target_language
      @force_update = force_update
    end

    def call
      return Result.new(error: "Post not found") if @post.blank?
      return Result.new(error: "Target language not specified") if @target_language.blank?

      api_config = get_api_config
      return Result.new(error: api_config[:error]) if api_config[:error]

      raw = @post.raw
      title = prepare_title

      total_length = raw.length
      total_length += title.length if title.present?
      max_length = get_max_content_length(api_config)
      return Result.new(error: "Content too long for translation") if total_length > max_length

      chunks = ContentSplitter.split(content: raw, chunk_size: get_chunk_size(api_config))
      if chunks.size > MAX_CHUNKS
        return(
          Result.new(
            error: "Content too long for translation (#{chunks.size} chunks, max #{MAX_CHUNKS})",
          )
        )
      end

      translated_chunks = []
      total_tokens_used = 0

      chunks.each do |chunk|
        trailing_ws = chunk[/\s+\z/] || ""
        core_chunk = chunk.sub(/\s+\z/, "")

        protector = MarkdownProtector.new(core_chunk)
        protected_text, tokens = protector.protect

        prompt = build_prompt(protected_text, @target_language)
        response = make_llm_request(prompt, api_config)
        return Result.new(error: response[:error]) if response[:error]

        total_tokens_used += response[:tokens_used].to_i
        translated_text = strip_llm_wrapper(response[:text])
        restored = MarkdownProtector.restore(translated_text, tokens)

        translated_chunks << (restored + trailing_ws)
      end

      translated_raw = translated_chunks.join("")
      translated_title = translate_title(title, @target_language, api_config) if title.present?

      Result.new(
        translated_raw: translated_raw,
        translated_title: translated_title,
        source_language: "auto",
        ai_response: {
          confidence: 0.95,
          provider_info: {
            model: api_config[:model],
            tokens_used: total_tokens_used,
            provider: api_config[:provider],
          },
        },
      )
    rescue BabelReunited::RateLimitError
      raise
    rescue => e
      Rails.logger.error("Translation service error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      BabelReunited::TranslationLogger.log_translation_error(
        post_id: @post&.id,
        target_language: @target_language,
        error: e,
        processing_time: 0,
        context: {
          phase: "service_exception",
        },
      )
      Result.new(error: "Translation service temporarily unavailable")
    end

    private

    def prepare_title
      return nil unless @post.post_number == 1
      return nil if @post.topic&.title.blank?
      return nil unless SiteSetting.babel_reunited_translate_title

      @post.topic.title
    end

    def build_prompt(text, target_language)
      <<~PROMPT.strip
        Translate the following text to #{target_language}.
        Preserve all \u27E6...\u27E7 placeholders exactly as they appear.
        Translate ALL natural-language text to #{target_language}, including link titles, headings, markdown-style blockquotes (lines starting with >), and embedded foreign language fragments. Do not leave any foreign language text untranslated.
        Keep proper nouns, brand names, product names, and technical terms in their original form (e.g. Google Workspace, CKB Community Fund DAO, Nervos, GitHub, Telegram).
        If the text is already in #{target_language}, return it unchanged.
        Return ONLY the translated text, no explanations or wrapping.

        ---
        #{text}
      PROMPT
    end

    def strip_llm_wrapper(text)
      text = text.strip
      text = text.sub(/\A(?:here\s+is\s+.*?:\s*\n)/i, "")
      text = text.sub(/\A```\w*\n(.*)\n```\z/m, '\1')
      text.strip
    end

    def translate_title(title, target_language, api_config)
      prompt = <<~P.strip
        Translate the following text to #{target_language}.
        Return ONLY the translated text, no quotes, no extra words.

        Text:
        #{title}
      P

      response = make_llm_request(prompt, api_config, max_tokens_override: 1024)
      return nil if response[:error]
      response[:text]&.strip
    rescue => e
      Rails.logger.warn("Title translation failed: #{e.message}")
      nil
    end

    def make_llm_request(prompt, api_config, max_tokens_override: nil)
      unless BabelReunited::RateLimiter.perform_request_if_allowed
        raise BabelReunited::RateLimitError, "Local rate limit exceeded"
      end

      provider = provider_for(api_config)

      timeout = SiteSetting.babel_reunited_request_timeout_seconds
      conn =
        Faraday.new(
          url: api_config[:base_url],
          request: {
            timeout: timeout,
            open_timeout: timeout,
            read_timeout: timeout,
            write_timeout: timeout,
          },
        ) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end

      token_param = api_config[:output_token_param] || :max_tokens
      max_tokens = max_tokens_override || api_config[:max_tokens]
      if max_tokens_override && api_config[:max_tokens]
        max_tokens = [max_tokens_override, api_config[:max_tokens].to_i].min
      end

      request_body =
        provider.build_request_body(
          model: api_config[:model],
          messages: [{ role: "user", content: prompt }],
          max_tokens: max_tokens,
          token_param: token_param,
          supports_temperature: api_config[:supports_temperature],
        )

      response =
        conn.post(provider.endpoint_path) do |req|
          provider.headers(api_config[:api_key]).each { |k, v| req.headers[k] = v }
          req.body = request_body.to_json
        end

      log_provider_response(response, api_config)

      if response.success?
        provider.parse_response(response.body)
      else
        handle_api_error(response)
      end
    rescue Faraday::Error => e
      Rails.logger.error("Network error: #{e.message}")
      log_error(e, "network_error")
      { error: "Network error: #{e.message}" }
    end

    def get_api_config
      config = BabelReunited::ModelConfig.get_config
      if config.nil?
        return { error: "Invalid preset model: #{SiteSetting.babel_reunited_preset_model}" }
      end

      api_key = config[:api_key]
      return { error: "API key not configured for provider #{config[:provider]}" } if api_key.blank?

      base_url = config[:base_url]
      if base_url.blank?
        return { error: "Base URL not configured for provider #{config[:provider]}" }
      end

      model_name = config[:model_name]
      if model_name.blank?
        return { error: "Model name not configured for provider #{config[:provider]}" }
      end

      {
        api_key: api_key,
        base_url: base_url,
        model: model_name,
        max_tokens:
          config[:max_output_tokens] || config[:max_tokens] ||
            SiteSetting.babel_reunited_custom_max_output_tokens,
        provider: config[:provider],
        max_tokens_for_length: config[:max_tokens],
        output_token_param: config[:output_token_param] || :max_tokens,
        supports_temperature: config.fetch(:supports_temperature, true),
      }
    end

    def get_chunk_size(api_config)
      max_output = api_config[:max_tokens]
      max_output.present? ? max_output.to_i : 32_768
    end

    def provider_for(api_config)
      case api_config[:provider]
      when "anthropic"
        Providers::Anthropic.new
      else
        Providers::OpenAiCompatible.new
      end
    end

    def get_max_content_length(api_config)
      return SiteSetting.babel_reunited_max_content_length if api_config[:provider] == "custom"

      max_tokens = api_config[:max_tokens_for_length]
      return SiteSetting.babel_reunited_max_content_length unless max_tokens

      max_tokens * 3
    end

    def handle_api_error(response)
      raw_body = response.body
      parsed_body =
        begin
          raw_body.is_a?(String) ? JSON.parse(raw_body) : raw_body
        rescue JSON::ParserError
          nil
        end

      error_message =
        if parsed_body.is_a?(Hash)
          error_field = parsed_body["error"]
          nested = error_field.is_a?(Hash) ? error_field["message"] : nil
          nested || parsed_body["message"] || error_field || "Unknown API error"
        else
          raw_body.to_s.presence || "Unknown API error"
        end

      log_error(StandardError.new(error_message), "provider_error")

      case response.status
      when 401
        { error: "Invalid API key" }
      when 429
        { error: "Rate limit exceeded. Please try again later." }
      when 400
        { error: "Bad request: #{error_message}" }
      when 500..599
        { error: "Translation service temporarily unavailable" }
      else
        { error: "API error: #{error_message}" }
      end
    end

    def log_provider_response(response, api_config)
      body_for_log =
        case response.body
        when String
          response.body
        else
          begin
            JSON.generate(response.body)
          rescue StandardError
            response.body.to_s
          end
        end

      BabelReunited::TranslationLogger.log_provider_response(
        post_id: @post&.id,
        target_language: @target_language,
        status: response.status,
        body: body_for_log[0, 4000],
        phase: "post_chat_completions",
        provider: api_config[:provider],
      )
    rescue StandardError
      # best-effort logging
    end

    def log_error(error, phase)
      BabelReunited::TranslationLogger.log_translation_error(
        post_id: @post&.id,
        target_language: @target_language,
        error: error,
        processing_time: 0,
        context: {
          phase: phase,
        },
      )
    rescue StandardError
      # best-effort logging
    end
  end
end
