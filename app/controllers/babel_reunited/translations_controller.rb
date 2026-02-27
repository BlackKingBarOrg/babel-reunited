# frozen_string_literal: true

module BabelReunited
  class TranslationsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :find_post, except: %i[set_user_preferred_language get_user_preferred_language]

    def index
      translations = @post.post_translations.recent
      render_serialized(translations, PostTranslationSerializer)
    end

    def show
      translation = @post.get_translation(params[:language])
      return render json: { error: "Translation not found" }, status: :not_found unless translation

      render_serialized(translation, PostTranslationSerializer)
    end

    def create
      target_language = params[:target_language]
      force_update = params[:force_update] || false

      if target_language.blank?
        return render json: { error: "Target language required" }, status: :bad_request
      end

      # 验证语言代码格式 - 支持 zh-cn 格式
      unless target_language.match?(/\A[a-z]{2}(-[a-z]{2})?\z/)
        return render json: { error: "Invalid language code format" }, status: :bad_request
      end

      RateLimiter.new(current_user, "babel-reunited-translate", 10, 1.minute).performed!

      # Always enqueue translation job - no skipping based on existing translations
      @post.enqueue_translation_jobs([target_language], force_update: force_update)

      render json: {
               message: "Translation job enqueued",
               post_id: @post.id,
               target_language: target_language,
               force_update: force_update,
               status: "queued",
             }
    end

    def destroy
      translation = @post.post_translations.find_by(language: params[:language])
      return render json: { error: "Translation not found" }, status: :not_found unless translation

      translation.destroy!
      render json: { message: "Translation deleted" }
    end

    def get_user_preferred_language
      preferred_language = current_user.user_preferred_language

      if preferred_language
        render json: { language: preferred_language.language, enabled: preferred_language.enabled }
      else
        render json: {
                 language: nil,
                 enabled: true, # Default to enabled if no preference set
               }
      end
    end

    def set_user_preferred_language
      language = params[:language]
      enabled = params[:enabled]

      preferred_language =
        current_user.user_preferred_language || current_user.build_user_preferred_language

      if language.present?
        # Validate language code format - 支持 zh-cn 格式
        unless language.match?(/\A[a-z]{2}(-[a-z]{2})?\z/)
          return render json: { error: "Invalid language code format" }, status: :bad_request
        end
        preferred_language.language = language
      end

      preferred_language.enabled = enabled if enabled.present?

      if preferred_language.save
        render json: {
                 success: true,
                 language: preferred_language.language,
                 enabled: preferred_language.enabled,
               }
      else
        render json: { errors: preferred_language.errors.full_messages }, status: :bad_request
      end
    end

    def translation_status
      translations = @post.post_translations
      pending_languages = translations.where(status: "translating").pluck(:language)

      render json: {
               post_id: @post.id,
               pending_translations: pending_languages,
               available_translations: translations.pluck(:language),
               last_updated: translations.maximum(:updated_at),
             }
    end

    private

    def find_post
      @post = Post.find_by(id: params[:post_id])
      return render json: { error: "Post not found" }, status: :not_found unless @post

      # Check permissions
      render json: { error: "Access denied" }, status: :forbidden unless guardian.can_see?(@post)
    end
  end
end
