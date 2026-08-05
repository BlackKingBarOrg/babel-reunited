# frozen_string_literal: true

require "faraday"

module BabelReunited
  # Detects the source language of a post with a micro LLM call (a few hundred
  # input tokens, ~2 output tokens). The result feeds three consumers: fan-out
  # skips translating into the post's own language, the view trigger refuses
  # detected == preferred requests, and the UI labels the original tab.
  class LanguageDetectionService
    SAMPLE_LENGTH = 400
    MIN_SAMPLE_LENGTH = 10
    REQUEST_TIMEOUT = 30
    MAX_OUTPUT_TOKENS = 500 # generous so reasoning models still emit the code

    LOCALE_ALIASES = {
      "zh" => "zh-cn",
      "iw" => "he",
      "in" => "id",
      "jw" => "jv",
      "nb" => "no",
      "nn" => "no",
      "pt-pt" => "pt",
      "en-us" => "en",
      "en-gb" => "en",
      "tl" => "fil"
    }.freeze

    # retryable separates failures another attempt could resolve (network,
    # provider status, a garbled answer) from ones that will fail identically
    # forever (content too short, missing configuration). The caller needs
    # the distinction: fanning out with no detection result pays to translate
    # a post into the language it is already written in, and that record then
    # looks completed to everything downstream.
    Result =
      Struct.new(:locale, :error, :retryable, keyword_init: true) do
        def success? = error.nil?
        def failure? = !success?
        def retryable? = !!retryable
      end

    def initialize(post:)
      @post = post
    end

    def call
      return Result.new(error: "Post not found") if @post.blank?

      sample = build_sample
      if sample.gsub(/\s+/, "").length < MIN_SAMPLE_LENGTH
        return Result.new(error: "Content too short for detection")
      end

      config = api_config
      return Result.new(error: config[:error]) if config[:error]

      unless BabelReunited::RateLimiter.perform_request_if_allowed
        raise BabelReunited::RateLimitError, "Local rate limit exceeded"
      end

      response = request_detection(sample, config)
      if response[:error]
        return(
          Result.new(error: response[:error], retryable: response[:retryable])
        )
      end

      locale = normalize_locale(response[:text])
      if locale
        Result.new(locale: locale)
      else
        Result.new(
          error:
            "Unrecognized detection response: #{response[:text].to_s.strip[0, 40]}",
          retryable: true
        )
      end
    rescue BabelReunited::RateLimitError
      raise
    rescue Faraday::Error => e
      Result.new(error: "Network error: #{e.message}", retryable: true)
    rescue => e
      Rails.logger.warn("BabelReunited language detection error: #{e.message}")
      Result.new(error: e.message, retryable: true)
    end

    private

    def build_sample
      # URLs carry no language signal and can dominate short posts.
      @post.raw.to_s.gsub(%r{https?://\S+}, " ")[0, SAMPLE_LENGTH].to_s
    end

    def build_prompt(sample)
      <<~PROMPT.strip
        Identify the primary language of the text below.
        Reply with ONLY one lowercase ISO 639-1 language code (examples: en, es, ja, th).
        For Chinese reply zh-cn for Simplified or zh-tw for Traditional.
        If the language cannot be determined, reply und.

        ---
        #{sample}
      PROMPT
    end

    def normalize_locale(text)
      code = text.to_s.strip.downcase.gsub(/\A["'`\s]+|["'`.\s]+\z/, "")
      code = LOCALE_ALIASES.fetch(code, code)
      BabelReunited::Locales.valid?(code) ? code : nil
    end

    # Only statuses another attempt could clear. A 400/401/403 means the
    # request or the configuration is wrong, and retrying it three times just
    # delays the fan-out that has to happen anyway.
    RETRYABLE_STATUSES = [408, 429].freeze

    def retryable_status?(status)
      RETRYABLE_STATUSES.include?(status) || status >= 500
    end

    def api_config
      config = BabelReunited::ModelConfig.get_config
      return { error: "Invalid preset model" } if config.nil?
      return { error: "API key not configured" } if config[:api_key].blank?
      return { error: "Base URL not configured" } if config[:base_url].blank?
      if config[:model_name].blank?
        return { error: "Model name not configured" }
      end

      config
    end

    def request_detection(sample, config)
      provider =
        case config[:provider]
        when "anthropic"
          Providers::Anthropic.new
        else
          Providers::OpenAiCompatible.new
        end

      conn =
        Faraday.new(
          url: config[:base_url],
          request: {
            timeout: REQUEST_TIMEOUT,
            open_timeout: REQUEST_TIMEOUT,
            read_timeout: REQUEST_TIMEOUT,
            write_timeout: REQUEST_TIMEOUT
          }
        ) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end

      request_body =
        provider.build_request_body(
          model: config[:model_name],
          messages: [{ role: "user", content: build_prompt(sample) }],
          max_tokens: MAX_OUTPUT_TOKENS,
          token_param: config[:output_token_param] || :max_tokens,
          supports_temperature: config.fetch(:supports_temperature, true)
        )

      response =
        conn.post(provider.endpoint_path) do |req|
          provider.headers(config[:api_key]).each { |k, v| req.headers[k] = v }
          req.body = request_body.to_json
        end

      if response.success?
        provider.parse_response(response.body)
      else
        {
          error: "Detection request failed with status #{response.status}",
          retryable: retryable_status?(response.status)
        }
      end
    end
  end
end
