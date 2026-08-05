# frozen_string_literal: true

require "digest/sha2"

class Jobs::BabelReunited::TranslatePostJob < ::Jobs::Base
  # Derived from the configured provider timeout rather than fixed: a lock
  # shorter than the work it guards lets a second job start while the first
  # is still calling the provider.
  def self.lock_ttl
    BabelReunited.max_translation_runtime.to_i
  end

  sidekiq_options retry: 5

  sidekiq_retry_in do |count, exception|
    case exception.wrapped
    when BabelReunited::RateLimitError
      (count + 1) * 30 + rand(15)
    end
  end

  sidekiq_retries_exhausted do |msg|
    args = msg["args"]&.first || {}
    post_id = args["post_id"]
    target_language = args["target_language"]

    if post_id && target_language
      translation =
        ::BabelReunited::PostTranslation.find_translation(
          post_id,
          target_language
        )
      if translation
        meta = translation.metadata || {}
        translation.update!(
          status: "failed",
          metadata:
            meta.merge(
              error: "Translation failed after all retries",
              error_kind: "transient",
              failure_count: meta["failure_count"].to_i + 1,
              failed_at: Time.current
            )
        )
      end
    end

    Rails.logger.error(
      "Translation job exhausted retries for post #{post_id} (#{target_language}): #{msg["error_message"]}"
    )
  end

  # Failures that retrying cannot fix; automated view-triggered retries skip
  # these while manual retries stay allowed.
  PERMANENT_ERROR_PATTERNS = [
    /content too long/i,
    /dropped \d+ protected placeholder/i,
    /\Abad request/i,
    /\Apost.not.found\z/i,
    /\Apost_deleted_or_hidden\z/,
    /\Acategory_not_enabled\z/,
    /\ATarget language not specified\z/
  ].freeze

  # The service classifies its own failures; this only covers the callers
  # that raise or return a bare message (post/category guards, unexpected
  # exceptions), where there is no structured kind to read.
  def self.error_kind_for(message, kind = nil)
    return kind if kind.present?

    if PERMANENT_ERROR_PATTERNS.any? { |p| message.to_s.match?(p) }
      "permanent"
    else
      "transient"
    end
  end

  # Content fingerprint for change detection. Includes the topic title for
  # first posts (mirroring TranslationService#prepare_title) so title edits
  # invalidate translations that carry a translated_title.
  def self.content_sha(post)
    parts = [post.raw]
    if post.post_number == 1 && SiteSetting.babel_reunited_translate_title &&
         post.topic&.title.present?
      parts << post.topic.title
    end
    Digest::SHA256.hexdigest(parts.join("\0"))
  end

  def execute(args)
    post_id = args[:post_id]
    target_language = args[:target_language]
    force_update = args[:force_update] || false

    return if post_id.blank? || target_language.blank?

    # Anchors the deletion tombstone check in write_result!: a deletion
    # after this moment wins over this job, one before it does not.
    @job_started_at = Time.current

    with_translation_lock(post_id, target_language) do
      post = find_post(post_id, target_language)
      return unless post

      unless BabelReunited.detection_current?(post)
        BabelReunited.enqueue_detection_backfill(post)
      end

      source_sha = self.class.content_sha(post)
      translation = ensure_translation_record(post, target_language)

      # Skip if source unchanged and not force_update
      if !force_update && translation.source_sha == source_sha &&
           translation.completed?
        log_skipped(post_id, target_language, "source_unchanged")
        # Re-announce completion so a client that requested this translation
        # without having it serialized (or raced the job) resolves instead of
        # waiting forever. The title rides along, or a client that resolved
        # this way would keep the original title until a reload.
        publish_status(
          post,
          target_language,
          "completed",
          translation: translation
        )
        publish_translated_title(post, translation)
        return
      end

      # Any non-completed record whose stored fingerprint still matches the
      # current content and which already carries a body needs no LLM call:
      # heal it back to completed. Covers stale rows from metadata-only edits,
      # records the view lane claimed into "translating", and failed rows
      # whose content never actually changed.
      if !force_update && !translation.completed? &&
           translation.source_sha == source_sha &&
           translation.translated_content.present?
        translation.update!(
          status: "completed",
          metadata: success_metadata(translation)
        )
        log_skipped(post_id, target_language, "content_unchanged_heal")
        BabelReunited.clear_banner_cache_for(post)
        publish_status(
          post,
          target_language,
          "completed",
          translation: translation
        )
        publish_translated_title(post, translation)
        return
      end

      start_time = Time.current
      log_start(post_id, target_language, post, force_update)

      result =
        ::BabelReunited::TranslationService.new(
          post: post,
          target_language: target_language,
          force_update: force_update
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
          force_update
        )
      else
        handle_failure(
          result,
          post_id,
          target_language,
          translation,
          processing_time,
          source_sha
        )
      end
    end
  rescue BabelReunited::RateLimitError
    raise
  rescue => e
    handle_unexpected_error(e, args[:post_id], args[:target_language])
  end

  private

  def with_translation_lock(post_id, language)
    lock_key = "babel_reunited:translate:#{post_id}:#{language}"
    lock_token = SecureRandom.hex(16)
    acquired =
      Discourse.redis.set(
        lock_key,
        lock_token,
        nx: true,
        ex: self.class.lock_ttl
      )
    unless acquired
      log_skipped(post_id, language, "locked")
      return
    end
    begin
      yield
    ensure
      # Atomic compare-and-delete via Lua to avoid TOCTOU race on lock release.
      # Must use namespace_key because eval bypasses DiscourseRedis key prefixing.
      namespaced_key = Discourse.redis.namespace_key(lock_key)
      Discourse.redis.eval(
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
        keys: [namespaced_key],
        argv: [lock_token]
      )
    end
  end

  def find_post(post_id, target_language)
    post = Post.find_by(id: post_id)
    if post.blank?
      mark_translation_failed(post_id, target_language, "post_not_found")
      log_skipped(post_id, target_language, "post_not_found")
      return nil
    end
    if post.deleted_at.present? || post.hidden?
      mark_translation_failed(
        post_id,
        target_language,
        "post_deleted_or_hidden"
      )
      log_skipped(post_id, target_language, "post_deleted_or_hidden")
      return nil
    end
    unless BabelReunited.translation_enabled_for_post?(post)
      mark_translation_failed(post_id, target_language, "category_not_enabled")
      log_skipped(post_id, target_language, "category_not_enabled")
      return nil
    end
    post
  end

  def mark_translation_failed(post_id, target_language, reason)
    translation =
      BabelReunited::PostTranslation.find_translation(post_id, target_language)
    return unless translation && !translation.failed?

    translation.update!(
      status: "failed",
      metadata: failure_metadata(translation, reason)
    )
  end

  # A success wipes the failure history: auto-retry eligibility tracks
  # consecutive failures, not lifetime totals.
  def success_metadata(translation, extra = {})
    (translation.metadata || {}).except(
      *::BabelReunited::PostTranslation::FAILURE_METADATA_KEYS
    ).merge(extra)
  end

  def failure_metadata(translation, message, kind: nil, **extra)
    meta = translation.metadata || {}
    meta.merge(
      error: message,
      error_kind: self.class.error_kind_for(message, kind),
      failure_count: meta["failure_count"].to_i + 1,
      failed_at: Time.current
    ).merge(extra)
  end

  # Stores a finished translation, re-creating the row if it went away while
  # the provider was running.
  #
  # That happens on two paths. Staff can delete a translation outright at any
  # time, and the job holds its record across a call that takes tens of
  # seconds. The view lane also deletes a claim it could not turn into work —
  # a fuse rejection or a failed enqueue — and a job started by the manual
  # lane may be holding that same row.
  #
  # Neither is caught by writing through the record we loaded: ActiveRecord
  # reports success for an UPDATE that matched no row, so the translation we
  # already paid for would be dropped without a trace. Writing through a
  # fresh lookup puts it back instead.
  def write_result!(post, target_language, attrs)
    if BabelReunited.translation_tombstoned_since?(
         post.id,
         target_language,
         @job_started_at
       )
      log_skipped(post.id, target_language, "deleted_while_translating")
      return nil
    end

    record =
      ::BabelReunited::PostTranslation.find_or_initialize_by(
        post_id: post.id,
        language: target_language
      )
    record.assign_attributes(attrs)
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Re-created between the lookup and the insert; that row is as good as
    # this one, so write into it.
    record =
      ::BabelReunited::PostTranslation.find_translation(
        post.id,
        target_language
      )
    raise if record.nil?
    record.update!(attrs)
    record
  end

  def ensure_translation_record(post, target_language)
    translation =
      BabelReunited::PostTranslation.find_translation(post.id, target_language)
    translation ||
      BabelReunited::PostTranslation.create_or_update_record(
        post.id,
        target_language
      )
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
    # Post-processing failures degrade to plain-cooked HTML: for a brand-new
    # translation there is no better content to fall back to.
    cook_result =
      ::BabelReunited::TranslatedCooker.call(
        raw: result.translated_raw,
        post: post
      )
    unless cook_result.post_processed?
      Rails.logger.warn(
        "BabelReunited: cooked post-processing failed for post #{post.id}: " \
          "#{cook_result.post_processing_error.message}"
      )
    end
    translated_cooked = cook_result.html

    translated_title = result.translated_title
    if translated_title.present? && translated_title.length > 255
      translated_title = translated_title[0...252] + "..."
    end

    # The LLM call runs long enough for the post to change underneath us.
    # Re-fingerprint before the final write: on a mismatch the result is still
    # readable but recorded as stale (it translates an older revision), and
    # one follow-up job chases the current content once the lock is released.
    post.reload
    final_status =
      self.class.content_sha(post) == source_sha ? "completed" : "stale"

    translation =
      write_result!(
        post,
        target_language,
        status: final_status,
        translated_raw: result.translated_raw,
        translated_content: translated_cooked,
        translated_title: translated_title,
        translation_provider: translation.translation_provider,
        source_language:
          BabelReunited.current_detected_locale_for(post) ||
            result.source_language,
        source_sha: source_sha,
        metadata:
          success_metadata(
            translation,
            confidence: result.ai_response[:confidence],
            provider_info: result.ai_response[:provider_info],
            translated_at: Time.current,
            completed_at: Time.current
          )
      )

    return if translation.nil? # deleted while the provider ran; deletion wins

    BabelReunited.clear_banner_cache_for(post)

    ::BabelReunited::TranslationLogger.log_translation_success(
      post_id: post.id,
      target_language: target_language,
      translation_id: translation.id,
      ai_response: result.ai_response,
      processing_time: processing_time,
      force_update: force_update,
      translated_length: result.translated_raw&.length || 0
    )

    publish_status(
      post,
      target_language,
      "completed",
      translation: translation,
      result: result
    )
    publish_translated_title(post, translation)

    if final_status == "stale"
      log_skipped(post.id, target_language, "content_changed_midflight")
      Jobs.enqueue_in(
        5.seconds,
        Jobs::BabelReunited::TranslatePostJob,
        post_id: post.id,
        target_language: target_language
      )
    end
  end

  def handle_failure(
    result,
    post_id,
    target_language,
    translation,
    processing_time,
    source_sha
  )
    post = Post.find_by(id: post_id)

    # A verdict describes the content that produced it. If the post changed
    # while this ran, the verdict says nothing about what the post holds now,
    # and recording it as permanent would strand the language forever:
    # trigger_retranslation only clears records that were already failed when
    # the edit landed, so this one would never be reached and every later view
    # would noop on failed_not_retryable.
    if post && self.class.content_sha(post) != source_sha
      translation.update!(status: "failed", metadata: void_verdict(translation))
      log_skipped(post_id, target_language, "failed_against_stale_content")
      publish_status(post, target_language, "failed", error: result.error)
      return
    end

    translation.update!(
      status: "failed",
      metadata:
        failure_metadata(translation, result.error, kind: result.error_kind)
    )

    ::BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: StandardError.new(result.error),
      processing_time: processing_time,
      context: {
        phase: "service_failure"
      }
    )
    Rails.logger.error(
      "Translation failed for post #{post_id}: #{result.error}"
    )

    publish_status(post, target_language, "failed", error: result.error) if post
  end

  # Failed, but with no verdict attached, so auto_retryable? says yes.
  def void_verdict(translation)
    (translation.metadata || {}).except(
      *::BabelReunited::PostTranslation::FAILURE_METADATA_KEYS
    )
  end

  def handle_unexpected_error(error, post_id, target_language)
    if post_id && target_language
      translation =
        ::BabelReunited::PostTranslation.find_translation(
          post_id,
          target_language
        )
      if translation
        translation.update!(
          status: "failed",
          metadata:
            failure_metadata(
              translation,
              error.message,
              error_class: error.class.name
            )
        )
      end
    end

    ::BabelReunited::TranslationLogger.log_translation_error(
      post_id: post_id,
      target_language: target_language,
      error: error,
      processing_time: 0,
      context: {
        phase: "unexpected_exception"
      }
    )
    Rails.logger.error(
      "Unexpected error in translation job for post #{post_id}: #{error.message}"
    )
    Rails.logger.error(error.backtrace.join("\n")) if error.backtrace
  end

  def publish_status(
    post,
    language,
    status,
    translation: nil,
    result: nil,
    error: nil
  )
    return unless post

    audience = ::BabelReunited::MessageBusAudience.options_for(post)
    payload = { post_id: post.id, language: language, status: status }

    # Pushing the body to open pages bypasses the serializer and the
    # controller, so the same guard has to hold here or it holds nowhere.
    if status == "completed" && translation && !translation.safe_to_display?
      MessageBus.publish(
        "/post-translations/#{post.id}",
        { post_id: post.id, language: language, status: "withheld" },
        **audience
      )
      return
    end

    if status == "completed" && translation
      payload[:translation] = {
        language: language,
        translated_content: translation.translated_content,
        translated_title: translation.translated_title,
        source_language: translation.source_language,
        status: translation.status,
        metadata: {
          confidence: result&.ai_response&.dig(:confidence),
          provider_info: result&.ai_response&.dig(:provider_info),
          translated_at: Time.current,
          completed_at: Time.current
        }
      }
    end

    payload[:error] = error if error

    MessageBus.publish("/post-translations/#{post.id}", payload, **audience)
  end

  # The title lives outside the post stream, so the body swapping in over
  # MessageBus leaves it in the original language until a reload. Topic-level
  # channel because that is the id the title component reliably has.
  def publish_translated_title(post, translation)
    return unless post.post_number == 1
    return if translation.translated_title.blank?
    return unless translation.safe_to_display?

    MessageBus.publish(
      "/babel-translated-title/#{post.topic_id}",
      {
        topic_id: post.topic_id,
        language: translation.language,
        translated_title: translation.translated_title
      },
      **::BabelReunited::MessageBusAudience.options_for(post)
    )
  end

  def log_skipped(post_id, target_language, reason)
    ::BabelReunited::TranslationLogger.log_translation_skipped(
      post_id: post_id,
      target_language: target_language,
      reason: reason
    )
  end

  def log_start(post_id, target_language, post, force_update)
    ::BabelReunited::TranslationLogger.log_translation_start(
      post_id: post_id,
      target_language: target_language,
      content_length: post.raw&.length || 0,
      force_update: force_update
    )
  end
end
