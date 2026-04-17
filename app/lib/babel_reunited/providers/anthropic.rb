# frozen_string_literal: true

module BabelReunited
  module Providers
    class Anthropic < Base
      ANTHROPIC_VERSION = "2023-06-01"

      def endpoint_path
        "/v1/messages"
      end

      def headers(api_key)
        {
          "x-api-key" => api_key,
          "anthropic-version" => ANTHROPIC_VERSION,
          "content-type" => "application/json",
        }
      end

      def build_request_body(model:, messages:, max_tokens:, token_param:, supports_temperature:)
        body = { model: model, messages: messages, max_tokens: max_tokens }
        body[:temperature] = 0.3 if supports_temperature != false
        body
      end

      def parse_response(body)
        content = body.dig("content")
        return { error: "Invalid response format" } unless content.is_a?(Array) && content.any?

        if body.dig("stop_reason") == "max_tokens"
          return { error: "Translation truncated (output token limit reached)" }
        end

        text_block = content.find { |block| block["type"] == "text" }
        text = text_block&.dig("text")
        return { error: "No translation in response" } if text.blank?

        usage = body["usage"] || {}
        tokens_used = usage["input_tokens"].to_i + usage["output_tokens"].to_i

        { text: text.strip, model: body.dig("model"), tokens_used: tokens_used }
      end
    end
  end
end
