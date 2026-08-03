# frozen_string_literal: true

module BabelReunited
  module Providers
    class OpenAiCompatible < Base
      def endpoint_path
        "/v1/chat/completions"
      end

      def headers(api_key)
        {
          "Authorization" => "Bearer #{api_key}",
          "Content-Type" => "application/json"
        }
      end

      def build_request_body(
        model:,
        messages:,
        max_tokens:,
        token_param:,
        supports_temperature:
      )
        body = {
          :model => model,
          :messages => messages,
          token_param => max_tokens
        }
        body[:temperature] = 0.3 if supports_temperature != false
        body
      end

      def parse_response(body)
        choices = body.dig("choices")
        unless choices&.any?
          return { error: "Invalid response format", error_kind: "transient" }
        end

        first_choice = choices.first

        if first_choice.dig("finish_reason") == "length"
          return(
            {
              error: "Translation truncated (output token limit reached)",
              error_kind: "permanent"
            }
          )
        end

        text = first_choice.dig("message", "content")
        if text.blank?
          return(
            { error: "No translation in response", error_kind: "transient" }
          )
        end

        {
          text: text.strip,
          model: body.dig("model"),
          tokens_used: body.dig("usage", "total_tokens")
        }
      end
    end
  end
end
