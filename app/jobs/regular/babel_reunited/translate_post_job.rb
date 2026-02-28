# frozen_string_literal: true

require "digest/sha2"

class Jobs::BabelReunited::TranslatePostJob < ::Jobs::Base
  LOCK_TTL = 300 # 5 minutes

  def execute(args)
    post_id = args[:post_id]
    target_language = args[:target_language]
    force_update = args[:force_update] || false

    return if post_id.blank? || target_language.blank?

    with_translation_lock(post_id, target_language) do
      post = find_post(post_id, target_language)
      return unless post

      source_sha = Digest::SHA256.hexdigest(post.raw)
      translation = ensure_translation_record(post, target_language)

      # Skip if source unchanged and not force_update
      if !force_update && translation.source_sha == source_sha && translation.completed?
        log_skipped(post_id, target_language, "source_unchanged")
        return
      end

      start_time = Time.current
      log_start(post_id, target_language, post, force_update)

      result =
        ::BabelReunited::TranslationService.new(
          post: post,
          target_language: target_language,
          force_update: force_update,
        ).call

      processing_time = ((Time.current - start_time) * 1000).round(2)

      if result.success?
        handle_success(
          result,
          post,
          target_language,
          source_sha,
          translation,
          processing_time,
          force_update,
        )
      else
        handle_failure(result, post_id, target_language, translation, processing_time)
      end
    end
  rescue => e
    handle_unexpected_error(e, args[:post_id], args[:target_language])
  end

  private

  def with_translation_lock(post_id, language)
    lock_key = "babel_reunited:translate:#{post_id}:#{language}"
    lock_token = SecureRandom.hex(16)
    acquired = Discourse.redis.set(lock_key, lock_token, nx: true, ex: LOCK_TTL)
    unless acquired
      log_skipped(post_id, language, "locked")
      return
    end
    begin
      yield
    ensure
      # Only release if we still own the lock (compare-and-delete)
      Discourse.redis.del(lock_key) if Discourse.redis.get(lock_key) == lock_token
    end
  end

  def find_post(post_id, target_language)
    post = Post.find_by(id: post_id)
    if post.blank?
      log_skipped(post_id, target_language, "post_not_found")
      return nil
    end
    if post.deleted_at.present? || post.hidden?
      log_skipped(post_id, target_language, "post_deleted_or_hidden")
      return nil
    end
    post
  end

  def ensure_translation_record(post, target_language)
    translation = BabelReunited::PostTranslation.find_translation(post.id, target_language)
    translation || BabelReunited::PostTranslation.create_or_update_record(post.id, target_language)
  end

  def handle_success(
    result,
    post,
    target_language,
    source_sha,
    translation,
    processing_time,
    force_update
  )
    translated_cooked = PrettyText.cook(result.translated_raw, topic_id: post.topic_id)
    translated_cooked = Loofah.html5_fragment(translated_cooked).scrub!(:prune).to_s

    translation.update!(
      status: "completed",
      translated_raw: result.translated_raw,
      translated_content: translated_cooked,
      translated_title: result.translated_title,
      source_language: result.source_language,
      source_sha: source_sha,
      metadata:
        (translation.metadata || {}).merge(
          confidence: result.ai_response[:confidence],
          provider_info: result.ai_response[:provider_info],
          translated_at: Time.current,
          completed_at: Time.current,
        ),
    )

    ::BabelReunited::TranslationLogger.log_translation_success(
      post_id: post.id,
      target_language: target_language,
      translation_id: translation.id,
      ai_response: result.ai_response,
      processing_time: processing_time,
      force_update: force_update,
    )

    publish_status(post, target_language, "completed", translation: translation, result: result)
  end

  def handle_failure(result, post_id, target_language, translation, processing_time)
    translation.update!(
      status: "failed",
      metadata: (translation.metadata || {}).merge(error: result.error, failed_at: Time.current),
    )

    ::BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: StandardError.new(result.error),
      processing_time: processing_time,
      context: {
        phase: "service_failure",
      },
    )
    Rails.logger.error("Translation failed for post #{post_id}: #{result.error}")

    post = Post.find_by(id: post_id)
    publish_status(post, target_language, "failed", error: result.error) if post
  end

  def handle_unexpected_error(error, post_id, target_language)
    if post_id && target_language
      translation = ::BabelReunited::PostTranslation.find_translation(post_id, target_language)
      if translation
        translation.update!(
          status: "failed",
          metadata:
            (translation.metadata || {}).merge(
              error: error.message,
              error_class: error.class.name,
              failed_at: Time.current,
            ),
        )
      end
    end

    ::BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: error,
      processing_time: 0,
      context: {
        phase: "unexpected_exception",
      },
    )
    Rails.logger.error("Unexpected error in translation job for post #{post_id}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n")) if error.backtrace
  end

  def publish_status(post, language, status, translation: nil, result: nil, error: nil)
    return unless post

    audience = ::BabelReunited::MessageBusAudience.options_for(post)
    payload = { post_id: post.id, language: language, status: status }

    if status == "completed" && translation
      payload[:translation] = {
        language: language,
        translated_content: translation.translated_content,
        translated_title: translation.translated_title,
        source_language: translation.source_language,
        status: "completed",
        metadata: {
          confidence: result&.ai_response&.dig(:confidence),
          provider_info: result&.ai_response&.dig(:provider_info),
          translated_at: Time.current,
          completed_at: Time.current,
        },
      }
    end

    payload[:error] = error if error

    MessageBus.publish("/post-translations/#{post.id}", payload, **audience)
  end

  def log_skipped(post_id, target_language, reason)
    ::BabelReunited::TranslationLogger.log_translation_skipped(
      post_id: post_id,
      target_language: target_language,
      reason: reason,
    )
  end

  def log_start(post_id, target_language, post, force_update)
    ::BabelReunited::TranslationLogger.log_translation_start(
      post_id: post_id,
      target_language: target_language,
      content_length: post.raw&.length || 0,
      force_update: force_update,
    )
  end
end
