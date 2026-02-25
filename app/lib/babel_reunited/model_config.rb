# frozen_string_literal: true

module BabelReunited
  class ModelConfig
    PRESET_MODELS = {
      # OpenAI Models
      "gpt-5" => {
        provider: "openai",
        model_name: "gpt-5",
        base_url: "https://api.openai.com",
        max_tokens: 128_000,
        max_output_tokens: 16_000,
        output_token_param: :max_completion_tokens,
        supports_temperature: false,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI next-generation flagship model",
        tier: "High",
      },
      "gpt-5-mini" => {
        provider: "openai",
        model_name: "gpt-5-mini",
        base_url: "https://api.openai.com",
        max_tokens: 128_000,
        max_output_tokens: 16_000,
        output_token_param: :max_completion_tokens,
        supports_temperature: false,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI GPT-5 cost-effective variant",
        tier: "Medium",
      },
      "gpt-5-nano" => {
        provider: "openai",
        model_name: "gpt-5-nano",
        base_url: "https://api.openai.com",
        max_tokens: 16_385,
        max_output_tokens: 4_096,
        output_token_param: :max_completion_tokens,
        supports_temperature: false,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI GPT-5 lightweight variant for speed and cost",
        tier: "Low",
      },
      "gpt-4o" => {
        provider: "openai",
        model_name: "gpt-4o",
        base_url: "https://api.openai.com",
        max_tokens: 128_000,
        max_output_tokens: 16_000,
        output_token_param: :max_completion_tokens,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI latest flagship model, strongest performance",
        tier: "High",
      },
      "gpt-4o-mini" => {
        provider: "openai",
        model_name: "gpt-4o-mini",
        base_url: "https://api.openai.com",
        max_tokens: 128_000,
        max_output_tokens: 16_000,
        output_token_param: :max_completion_tokens,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI cost-effective model, excellent performance",
        tier: "Medium",
      },
      "gpt-3.5-turbo" => {
        provider: "openai",
        model_name: "gpt-3.5-turbo",
        base_url: "https://api.openai.com",
        max_tokens: 16_385,
        max_output_tokens: 4_096,
        output_token_param: :max_tokens,
        api_key_setting: :babel_reunited_openai_api_key,
        description: "OpenAI economical model, fast speed",
        tier: "Low",
      },
      # xAI Models (including latest Grok-4)
      "grok-4" => {
        provider: "xai",
        model_name: "grok-4",
        base_url: "https://api.x.ai",
        max_tokens: 132_000,
        max_output_tokens: 36_000,
        api_key_setting: :babel_reunited_xai_api_key,
        description: "xAI latest flagship model, HLE test leader, super strong math reasoning",
        tier: "High",
      },
      "grok-4-fast-non-reasoning" => {
        provider: "xai",
        model_name: "grok-4-fast-non-reasoning",
        base_url: "https://api.x.ai",
        max_tokens: 2_000_000,
        max_output_tokens: 36_000,
        api_key_setting: :babel_reunited_xai_api_key,
        description: "xAI Grok-4 fast non-reasoning model, optimized for low latency",
        tier: "Medium",
      },
      "grok-3" => {
        provider: "xai",
        model_name: "grok-3",
        base_url: "https://api.x.ai",
        max_tokens: 131_072,
        max_output_tokens: 16_000,
        api_key_setting: :babel_reunited_xai_api_key,
        description: "xAI medium model, balanced performance and cost",
        tier: "Medium",
      },
      "grok-2" => {
        provider: "xai",
        model_name: "grok-2",
        base_url: "https://api.x.ai",
        max_tokens: 128_000,
        max_output_tokens: 16_000,
        api_key_setting: :babel_reunited_xai_api_key,
        description: "xAI economical model, fast response",
        tier: "Low",
      },
      # DeepSeek Models
      "deepseek-r1" => {
        provider: "deepseek",
        model_name: "deepseek-r1",
        base_url: "https://api.deepseek.com",
        max_tokens: 64_000,
        max_output_tokens: 16_000,
        api_key_setting: :babel_reunited_deepseek_api_key,
        description: "DeepSeek latest flagship model, strong Chinese capabilities",
        tier: "High",
      },
      "deepseek-v3" => {
        provider: "deepseek",
        model_name: "deepseek-v3",
        base_url: "https://api.deepseek.com",
        max_tokens: 64_000,
        max_output_tokens: 16_000,
        api_key_setting: :babel_reunited_deepseek_api_key,
        description: "DeepSeek general conversation model, cost-effective",
        tier: "Medium",
      },
    }.freeze

    def self.get_config
      preset_model = SiteSetting.babel_reunited_preset_model

      if preset_model == "custom"
        return(
          {
            provider: "custom",
            model_name: SiteSetting.babel_reunited_custom_model_name,
            base_url: SiteSetting.babel_reunited_custom_base_url,
            max_tokens: SiteSetting.babel_reunited_custom_max_tokens,
            max_output_tokens: SiteSetting.babel_reunited_custom_max_output_tokens,
            api_key: SiteSetting.babel_reunited_custom_api_key,
          }
        )
      end

      config = PRESET_MODELS[preset_model]
      return nil unless config

      config.merge(api_key: SiteSetting.public_send(config[:api_key_setting]))
    end

    def self.get_api_key
      get_config&.dig(:api_key)
    end

    def self.get_model_name
      get_config&.dig(:model_name)
    end

    def self.get_base_url
      get_config&.dig(:base_url)
    end

    def self.get_max_tokens
      get_config&.dig(:max_tokens)
    end

    def self.get_max_output_tokens
      get_config&.dig(:max_output_tokens)
    end

    def self.get_provider
      get_config&.dig(:provider)
    end

    def self.get_description
      get_config&.dig(:description)
    end

    def self.get_tier
      get_config&.dig(:tier)
    end

    def self.list_available_models
      PRESET_MODELS.map do |key, config|
        {
          key: key,
          name: config[:model_name],
          provider: config[:provider],
          description: config[:description],
          tier: config[:tier],
          max_tokens: config[:max_tokens],
          max_output_tokens: config[:max_output_tokens],
        }
      end
    end

    def self.list_models_by_provider(provider)
      PRESET_MODELS.select { |_, config| config[:provider] == provider }
    end

    def self.list_models_by_tier(tier)
      PRESET_MODELS.select { |_, config| config[:tier] == tier }
    end
  end
end
