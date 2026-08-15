# frozen_string_literal: true

module BabelReunited
  # Where a translation request goes and how it is shaped on the wire.
  #
  # Providers are few and stable; models are neither. A gateway fronts
  # hundreds of them and any list written here is wrong within weeks, so the
  # provider is an enum and the model is free text, with the per-model quirks
  # derived from its name by ModelTraits.
  class ModelConfig
    # :path is per provider, not per wire format: the OpenAI-compatible
    # endpoint sits at a different place on each host (Google mounts a shim
    # under /v1beta, OpenRouter serves its API under /api).
    PROVIDERS = {
      "openai" => {
        base_url: "https://api.openai.com",
        path: "/v1/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_openai_api_key
      },
      "anthropic" => {
        base_url: "https://api.anthropic.com",
        path: "/v1/messages",
        wire: :anthropic,
        api_key_setting: :babel_reunited_anthropic_api_key
      },
      "openrouter" => {
        base_url: "https://openrouter.ai",
        path: "/api/v1/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_openrouter_api_key
      },
      "google" => {
        base_url: "https://generativelanguage.googleapis.com",
        path: "/v1beta/openai/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_google_api_key
      },
      "xai" => {
        base_url: "https://api.x.ai",
        path: "/v1/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_xai_api_key
      },
      "deepseek" => {
        base_url: "https://api.deepseek.com",
        path: "/v1/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_deepseek_api_key
      },
      # base_url comes from the admin instead of this table; the path is
      # derived from whatever they pasted. See split_custom_url.
      #
      # The only provider that may run without a key: a model served from
      # your own hardware usually has no authentication to configure, and
      # demanding one would mean inventing a fake key to get past validation.
      "openai_compatible" => {
        base_url: nil,
        path: "/v1/chat/completions",
        wire: :openai,
        api_key_setting: :babel_reunited_custom_api_key,
        optional_api_key: true
      }
    }.freeze

    def self.get_config
      provider = SiteSetting.babel_reunited_provider
      spec = PROVIDERS[provider]
      return nil unless spec

      base_url, path =
        if spec[:base_url]
          [spec[:base_url], spec[:path]]
        else
          split_custom_url(SiteSetting.babel_reunited_custom_base_url)
        end

      model = SiteSetting.babel_reunited_model

      {
        provider: provider,
        wire: spec[:wire],
        model_name: model,
        base_url: base_url,
        path: path,
        api_key: SiteSetting.public_send(spec[:api_key_setting]),
        requires_api_key: !spec[:optional_api_key],
        max_output_tokens: SiteSetting.babel_reunited_max_output_tokens,
        chunk_size: SiteSetting.babel_reunited_chunk_size
      }.merge(ModelTraits.for(provider: provider, model: model))
    end

    # Admins paste an OpenAI-compatible endpoint in whichever form their
    # provider's own docs print it: bare origin, origin with a trailing
    # slash, or origin plus the /v1 the docs usually include. All three name
    # the same endpoint, and appending a fixed path to the third produces
    # /v1/v1/chat/completions.
    def self.split_custom_url(url)
      url = url.to_s.strip.sub(%r{/+\z}, "")
      return url, "/v1/chat/completions" if url.blank?

      uri =
        begin
          URI.parse(url)
        rescue URI::InvalidURIError
          nil
        end
      return url, "/v1/chat/completions" if uri.nil? || uri.host.blank?

      origin = "#{uri.scheme}://#{uri.host}#{uri.port ? ":#{uri.port}" : ""}"
      origin = "#{uri.scheme}://#{uri.host}" if default_port?(uri)

      prefix = uri.path.to_s.sub(%r{/+\z}, "")
      return origin, "/v1/chat/completions" if prefix.blank?
      return origin, prefix if prefix.end_with?("/chat/completions")

      [origin, "#{prefix}/chat/completions"]
    end

    def self.default_port?(uri)
      (uri.scheme == "https" && uri.port == 443) ||
        (uri.scheme == "http" && uri.port == 80)
    end
    private_class_method :default_port?
  end
end
