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
      translation = BabelReunited::PostTranslation.find_translation(@post.id, params[:language])
      return render json: { error: "Translation not found" }, status: :not_found unless translation

      render_serialized(translation, PostTranslationSerializer)
    end

    def create
      target_language = params[:target_language]
      force_update = params[:force_update] || false

      if target_language.blank?
        return render json: { error: "Target language required" }, status: :bad_request
      end

      unless target_language.match?(/\A[a-z]{2}(-[a-z]{2})?\z/)
        return render json: { error: "Invalid language code format" }, status: :bad_request
      end

      ::RateLimiter.new(current_user, "babel-reunited-translate", 10, 1.minute).performed!

      BabelReunited.enqueue_translation_jobs(@post, [target_language], force_update: force_update)

      render json: {
               message: "Translation job enqueued",
               post_id: @post.id,
               target_language: target_language,
               force_update: force_update,
               status: "queued",
             }
    end

    def destroy
      unless guardian.is_admin? || guardian.is_moderator? || (@post.user_id == current_user.id)
        return render json: { error: "Not authorized" }, status: :forbidden
      end

      translation = @post.post_translations.find_by(language: params[:language])
      return render json: { error: "Translation not found" }, status: :not_found unless translation

      translation.destroy!
      render json: { message: "Translation deleted" }
    end

    def get_user_preferred_language
      language = BabelReunited.preferred_language_for(current_user)
      cast = ActiveModel::Type::Boolean.new
      enabled_val = current_user.custom_fields[BabelReunited::PREFERRED_ENABLED_FIELD]

      if enabled_val.nil?
        legacy = current_user.user_preferred_language
        enabled = legacy.nil? ? true : legacy.enabled
      else
        enabled = cast.cast(enabled_val)
      end

      render json: { language: language, enabled: enabled }
    end

    def set_user_preferred_language
      language = params[:language]
      enabled = params[:enabled]
      cast = ActiveModel::Type::Boolean.new

      if language.present?
        unless language.match?(/\A[a-z]{2}(-[a-z]{2})?\z/)
          return render json: { error: "Invalid language code format" }, status: :bad_request
        end
        current_user.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = language
      end

      unless enabled.nil?
        current_user.custom_fields[BabelReunited::PREFERRED_ENABLED_FIELD] = cast.cast(enabled)
      end

      current_user.save_custom_fields

      # Dual-write to legacy table for rollback safety
      legacy = current_user.user_preferred_language || current_user.build_user_preferred_language
      legacy.language = language if language.present?
      legacy.enabled = cast.cast(enabled) unless enabled.nil?
      legacy.save

      final_language =
        current_user.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] || legacy.language
      final_enabled = current_user.custom_fields[BabelReunited::PREFERRED_ENABLED_FIELD]
      final_enabled = legacy.enabled if final_enabled.nil?

      render json: { success: true, language: final_language, enabled: cast.cast(final_enabled) }
    end

    def translation_status
      rows = @post.post_translations.select(:language, :status, :updated_at).to_a
      pending = rows.select { |r| r.status == "translating" }.map(&:language)
      last_updated = rows.map(&:updated_at).compact.max

      render json: {
               post_id: @post.id,
               pending_translations: pending,
               available_translations: rows.map(&:language),
               last_updated: last_updated,
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
