# frozen_string_literal: true

module BabelReunited
  module Providers
    # A wire format: how a request body and its headers are shaped, and how a
    # response is read back. Where the request goes is not part of this --
    # the same format is served at different paths on different hosts, so the
    # endpoint comes from ModelConfig::PROVIDERS.
    class Base
      def headers(api_key)
        raise NotImplementedError
      end

      def build_request_body(
        model:,
        messages:,
        max_tokens:,
        token_param:,
        supports_temperature:,
        system: nil
      )
        raise NotImplementedError
      end

      def parse_response(body)
        raise NotImplementedError
      end
    end
  end
end
