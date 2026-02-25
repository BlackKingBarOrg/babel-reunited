# frozen_string_literal: true

class Jobs::BabelReunited::TranslatePostJob < ::Jobs::Base
  def execute(args)
    post_id = args[:post_id]
    target_language = args[:target_language]
    force_update = args[:force_update] || false
    start_time = Time.current

    return unless validate_arguments(post_id, target_language)

    post = find_and_validate_post(post_id, target_language)
    return unless post

    # Find existing translation record (should already be created by event handler)
    translation = post.get_translation(target_language)

    # If translation record doesn't exist, create it (fallback for manual job execution)
    translation ||= post.create_or_update_translation_record(target_language)

    log_translation_start(post_id, target_language, post, force_update)

    result = execute_translation_service(post, target_language, force_update)
    processing_time = calculate_processing_time(start_time)

    handle_translation_result(
      result,
      post_id,
      target_language,
      post.topic_id,
      processing_time,
      force_update,
      translation,
    )
  rescue => e
    # Handle any unexpected exceptions during translation
    processing_time = calculate_processing_time(start_time)
    handle_unexpected_error(e, post_id, target_language, processing_time)
  end

  private

  def validate_arguments(post_id, target_language)
    return false if post_id.blank? || target_language.blank?
    true
  end

  def find_and_validate_post(post_id, target_language)
    post = Post.find_by(id: post_id)

    if post.blank?
      handle_post_not_found(post_id, target_language)
      return nil
    end

    if post.deleted_at.present? || post.hidden?
      handle_post_deleted_or_hidden(post_id, target_language, post.topic_id)
      return nil
    end

    post
  end

  def handle_post_deleted_or_hidden(post_id, target_language, topic_id)
    BabelReunited::TranslationLogger.log_translation_skipped(
      post_id: post_id,
      target_language: target_language,
      reason: "post_deleted_or_hidden",
    )
  end

  def handle_post_not_found(post_id, target_language)
    BabelReunited::TranslationLogger.log_translation_skipped(
      post_id: post_id,
      target_language: target_language,
      reason: "post_not_found",
    )
  end

  def log_translation_start(post_id, target_language, post, force_update)
    BabelReunited::TranslationLogger.log_translation_start(
      post_id: post_id,
      target_language: target_language,
      content_length: post.raw&.length || 0,
      force_update: force_update,
    )
  end

  def execute_translation_service(post, target_language, force_update)
    BabelReunited::TranslationService.new(
      post: post,
      target_language: target_language,
      force_update: force_update,
    ).call
  end

  def calculate_processing_time(start_time)
    ((Time.current - start_time) * 1000).round(2)
  end

  def handle_translation_result(
    result,
    post_id,
    target_language,
    topic_id,
    processing_time,
    force_update,
    translation
  )
    if result.failure?
      handle_translation_failure(
        result,
        post_id,
        target_language,
        topic_id,
        processing_time,
        translation,
      )
    else
      handle_translation_success(
        result,
        post_id,
        target_language,
        topic_id,
        processing_time,
        force_update,
        translation,
      )
    end
  end

  def handle_translation_failure(
    result,
    post_id,
    target_language,
    topic_id,
    processing_time,
    translation
  )
    # Update translation status to failed
    translation.update!(
      status: "failed",
      metadata: translation.metadata.merge(error: result.error, failed_at: Time.current),
    )

    BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: StandardError.new(result.error),
      processing_time: processing_time,
      context: {
        topic_id: topic_id,
        phase: "service_failure",
        force_update: translation&.metadata&.dig(:force_update),
      },
    )
    Rails.logger.error("Translation failed for post #{post_id}: #{result.error}")
  end

  def handle_translation_success(
    result,
    post_id,
    target_language,
    topic_id,
    processing_time,
    force_update,
    translation
  )
    # Model before_save callback handles sanitization of translated_content and translated_title
    translation.update!(
      status: "completed",
      translated_content: result.translation.translated_content,
      translated_title: result.translation.translated_title,
      source_language: result.translation.source_language,
      metadata:
        translation.metadata.merge(
          confidence: result.ai_response[:confidence],
          provider_info: result.ai_response[:provider_info],
          translated_at: Time.current,
          completed_at: Time.current,
        ),
    )

    ai_response = result.ai_response || {}
    BabelReunited::TranslationLogger.log_translation_success(
      post_id: post_id,
      target_language: target_language,
      translation_id: translation.id,
      ai_response: ai_response,
      processing_time: processing_time,
      force_update: force_update,
    )

    # MessageBus reads from the already-sanitized DB record
    MessageBus.publish(
      "/post-translations/#{post_id}",
      {
        post_id: post_id,
        language: target_language,
        status: "completed",
        completed_at: Time.current,
        translation: {
          language: target_language,
          translated_content: translation.translated_content,
          translated_title: translation.translated_title,
          source_language: translation.source_language,
          status: "completed",
          metadata: {
            confidence: result.ai_response[:confidence],
            provider_info: result.ai_response[:provider_info],
            translated_at: Time.current,
            completed_at: Time.current,
          },
        },
      },
    )
  end

  def handle_unexpected_error(error, post_id, target_language, processing_time)
    # Try to find the translation record to update its status
    translation = BabelReunited::PostTranslation.find_translation(post_id, target_language)

    if translation.present?
      translation.update!(
        status: "failed",
        metadata:
          translation.metadata.merge(
            error: error.message,
            error_class: error.class.name,
            failed_at: Time.current,
          ),
      )
    end

    # Log the error
    BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: error,
      processing_time: processing_time,
      context: {
        phase: "unexpected_exception",
      },
    )

    Rails.logger.error("Unexpected error in translation job for post #{post_id}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n")) if error.backtrace
  end
end
