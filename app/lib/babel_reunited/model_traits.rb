# frozen_string_literal: true

module BabelReunited
  # The two request quirks that make a model reject a request outright,
  # derived from the model's name.
  #
  # The name is the only thing known about a free-text model, and it carries
  # enough. Matching the bare name rather than the provider means a model
  # reached through a gateway ("openai/gpt-5" on OpenRouter) is shaped the
  # same way as the direct one.
  module ModelTraits
    # OpenAI's reasoning families and Anthropic's Opus 4 line reject
    # `temperature` outright rather than clamping it.
    NO_TEMPERATURE = /\A(?:gpt-5|o[134]|claude-opus-4)/

    # OpenAI renamed the output cap on its own API; gpt-3.5 predates the
    # rename. Every other provider, and every OpenAI-compatible gateway,
    # still takes max_tokens.
    LEGACY_OUTPUT_CAP = /\Agpt-3/

    def self.for(provider:, model:)
      bare = model.to_s.split("/").last.to_s.downcase

      {
        supports_temperature: !bare.match?(NO_TEMPERATURE),
        output_token_param:
          if provider == "openai" && !bare.match?(LEGACY_OUTPUT_CAP)
            :max_completion_tokens
          else
            :max_tokens
          end
      }
    end
  end
end
