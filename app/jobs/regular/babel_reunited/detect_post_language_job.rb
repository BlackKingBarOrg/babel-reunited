# frozen_string_literal: true

class Jobs::BabelReunited::DetectPostLanguageJob < ::Jobs::Base
  sidekiq_options retry: 3

  sidekiq_retry_in do |count, exception|
    case exception.wrapped
    when BabelReunited::RateLimitError
      (count + 1) * 30 + rand(15)
    end
  end

  sidekiq_retries_exhausted do |msg|
    args = msg["args"]&.first || {}
    next unless args["then_fanout"]

    # Detection could not run; fan out to every configured language so the
    # pre-translate layer never silently stalls behind detection.
    post = Post.find_by(id: args["post_id"])
    BabelReunited.fanout_translations(post) if post
  end

  def execute(args)
    post = Post.find_by(id: args[:post_id])
    return if post.blank? || post.raw.blank?

    then_fanout = args[:then_fanout] || false

    if BabelReunited.detected_locale_for(post).blank?
      result = BabelReunited::LanguageDetectionService.new(post: post).call

      if result.success?
        BabelReunited.store_detected_locale(post, result.locale)
      else
        ::BabelReunited::TranslationLogger.log_translation_skipped(
          post_id: post.id,
          target_language: "detect",
          reason: "detection_failed: #{result.error}"
        )
      end
    end

    BabelReunited.fanout_translations(post) if then_fanout
  rescue BabelReunited::RateLimitError
    raise
  end
end
