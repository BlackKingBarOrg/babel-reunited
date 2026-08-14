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

    def initialize(config:, timeout:, on_response: nil)
      @config = config
      @timeout = timeout
      @on_response = on_response
    end

    def post(messages:, max_tokens:, system: nil)
      traits = {
        output_token_param: @config[:output_token_param] || :max_tokens,
        supports_temperature: @config.fetch(:supports_temperature, true)
      }

      response = send_request(messages, max_tokens, system, traits)
      return response unless response.status == 400

      fallback = parameter_fallback(response, traits)
      return response if fallback.nil?

      Rails.logger.warn(
        "BabelReunited: #{@config[:provider]} rejected #{fallback.keys.join(", ")} " \
          "for #{@config[:model_name]}, retrying once with #{fallback.inspect}"
      )
      send_request(messages, max_tokens, system, traits.merge(fallback))
    end

    def parse(body)
      wire.parse_response(body)
    end

    private

    def send_request(messages, max_tokens, system, traits)
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

      if complaint.match?(TOKEN_PARAM)
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
