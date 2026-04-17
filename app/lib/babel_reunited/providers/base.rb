# frozen_string_literal: true

module BabelReunited
  module Providers
    class Base
      def endpoint_path
        raise NotImplementedError
      end

      def headers(api_key)
        raise NotImplementedError
      end

      def build_request_body(model:, messages:, max_tokens:, token_param:, supports_temperature:)
        raise NotImplementedError
      end

      def parse_response(body)
        raise NotImplementedError
      end
    end
  end
end
