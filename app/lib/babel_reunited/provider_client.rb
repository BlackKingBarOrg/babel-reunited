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
    def initialize(config:, timeout:)
      @config = config
      @timeout = timeout
    end

    def post(messages:, max_tokens:, system: nil)
      body =
        wire.build_request_body(
          model: @config[:model_name],
          messages: messages,
          max_tokens: max_tokens,
          token_param: @config[:output_token_param] || :max_tokens,
          supports_temperature: @config.fetch(:supports_temperature, true),
          system: system
        )

      connection.post(@config[:path]) do |req|
        wire.headers(@config[:api_key]).each { |k, v| req.headers[k] = v }
        req.body = body.to_json
      end
    end

    def parse(body)
      wire.parse_response(body)
    end

    private

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
