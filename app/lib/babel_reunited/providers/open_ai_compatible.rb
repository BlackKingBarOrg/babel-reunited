# frozen_string_literal: true

module BabelReunited
  module Providers
    class OpenAiCompatible < Base
      def varies_by_token_param?
        true
      end

      # No key means no Authorization header at all. Sending a bare
      # "Bearer " is worse than sending nothing: a local model server or a
      # reverse proxy in front of one reads it as a credential and rejects
      # it, so the keyless endpoints this provider exists to support would
      # answer 401.
      def headers(api_key)
        headers = { "Content-Type" => "application/json" }
        headers["Authorization"] = "Bearer #{api_key}" if api_key.present?
        headers
      end

      def build_request_body(
        model:,
        messages:,
        max_tokens:,
        token_param:,
        supports_temperature:,
        system: nil
      )
        if system.present?
          messages = [{ role: "system", content: system }] + messages
        end
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
