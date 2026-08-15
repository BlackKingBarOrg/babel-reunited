# frozen_string_literal: true

require "faraday"

module BabelReunited
  # One HTTP call to a provider. Translation and detection both go through
  # here so the wire format, the endpoint and the timeout are decided once
  # rather than assembled separately at each call site.
  #
  # The Faraday response comes back unclassified on purpose: translation
  # separates permanent failures from transient ones, detection only asks
  # whether another attempt could help, and neither classification belongs
  # to the transport.
  class ProviderClient
    # ModelTraits guesses two request parameters from the model's name, and a
    # name it has no rule for can guess wrong. The provider says so with a
    # 400 that names the parameter, so rather than hand the admin a 400 they
    # cannot act on, send the other form once.
    #
    # Matched against the whole body rather than a parsed message: every
    # provider nests its error differently, and the parameter name is what
    # matters, not where it sits.
    TOKEN_PARAM = /max_(?:completion_)?tokens/i
    TEMPERATURE_PARAM = /temperature/i

    TRAITS_CACHE_TTL = 30.days.to_i

    def initialize(config:, timeout:, on_response: nil)
      @config = config
      @timeout = timeout
      @on_response = on_response
    end

    def post(messages:, max_tokens:, system: nil)
      traits = learned_traits.merge(guessed_traits) { |_k, learned, _| learned }

      response = send_request(messages, max_tokens, system, traits)
      return response unless response.status == 400

      fallback = parameter_fallback(response, traits)
      return response if fallback.nil?
      # A second attempt that would send byte-identical JSON is not a retry.
      return response if fallback == traits.slice(*fallback.keys)

      Rails.logger.warn(
        "BabelReunited: #{@config[:provider]} rejected #{fallback.keys.join(", ")} " \
          "for #{@config[:model_name]}, retrying once with #{fallback.inspect}"
      )
      corrected = traits.merge(fallback)
      retried = send_request(messages, max_tokens, system, corrected)

      # Remembered so the correction outlives this request. Without it every
      # call repeats the rejected guess, and at a rate limit of one call a
      # minute the corrected attempt is refused before it is sent, retried
      # from the wrong guess again, and never gets through at all.
      remember_traits(corrected) if retried.success?
      retried
    end

    def parse(body)
      wire.parse_response(body)
    end

    private

    def guessed_traits
      {
        output_token_param: @config[:output_token_param] || :max_tokens,
        supports_temperature: @config.fetch(:supports_temperature, true)
      }
    end

    # Keyed by provider and model, so changing either asks the question
    # again. Expires rather than living forever: a provider that fixes its
    # API should not be worked around indefinitely.
    def traits_cache_key
      "babel_reunited:model_traits:#{@config[:provider]}:#{@config[:model_name]}"
    end

    def learned_traits
      raw = Discourse.redis.get(traits_cache_key)
      return {} if raw.blank?

      parsed = JSON.parse(raw)
      {}.tap do |traits|
        if parsed.key?("output_token_param")
          traits[:output_token_param] = parsed["output_token_param"].to_sym
        end
        if parsed.key?("supports_temperature")
          traits[:supports_temperature] = parsed["supports_temperature"]
        end
      end
    rescue JSON::ParserError
      {}
    end

    def remember_traits(traits)
      Discourse.redis.setex(
        traits_cache_key,
        TRAITS_CACHE_TTL,
        traits.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }.to_json
      )
    rescue StandardError
      # Best effort: losing the memo costs one wasted call, not correctness.
    end

    def send_request(messages, max_tokens, system, traits)
      # Charged here rather than by the caller, so the fallback attempt costs
      # what it actually is: a second provider call. Charging once around the
      # whole exchange let a retrying request spend twice its allowance and
      # go unseen by the daily counter.
      unless BabelReunited::RateLimiter.perform_request_if_allowed
        raise BabelReunited::RateLimitError, "Local rate limit exceeded"
      end

      body =
        wire.build_request_body(
          model: @config[:model_name],
          messages: messages,
          max_tokens: max_tokens,
          token_param: traits[:output_token_param],
          supports_temperature: traits[:supports_temperature],
          system: system
        )

      response =
        connection.post(@config[:path]) do |req|
          wire.headers(@config[:api_key]).each { |k, v| req.headers[k] = v }
          req.body = body.to_json
        end

      @on_response&.call(response)
      response
    end

    # Which parameter to send differently, or nil when the 400 is about
    # something a different request shape cannot fix.
    def parameter_fallback(response, traits)
      complaint = response.body.to_s
      override = {}

      if complaint.match?(TEMPERATURE_PARAM) && traits[:supports_temperature]
        override[:supports_temperature] = false
      end

      if complaint.match?(TOKEN_PARAM) && wire.varies_by_token_param?
        # Send the other name rather than reading the provider's advice: a
        # message like "max_tokens is not supported, use max_completion_tokens"
        # names both, and which one it wants depends on which we just sent.
        override[:output_token_param] = (
          if traits[:output_token_param] == :max_completion_tokens
            :max_tokens
          else
            :max_completion_tokens
          end
        )
      end

      override.presence
    end

    def wire
      @wire ||=
        case @config[:wire]
        when :anthropic
          Providers::Anthropic.new
        else
          Providers::OpenAiCompatible.new
        end
    end

    def connection
      @connection ||=
        Faraday.new(
          url: @config[:base_url],
          request: {
            timeout: @timeout,
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout
          }
        ) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
    end
  end
end
