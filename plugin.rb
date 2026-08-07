# frozen_string_literal: true

# name: babel-reunited
# about: AI-powered post translation plugin that automatically translates posts to multiple languages using third-party AI APIs
# meta_topic_id: TODO
# version: 0.1.0
# authors: Divine Rapier
# url: https://github.com/divine-rapier/babel-reunited
# required_version: 2026.7.0

enabled_site_setting :babel_reunited_enabled

register_asset "stylesheets/translated-title.scss"
register_asset "stylesheets/preferences.scss"
register_asset "stylesheets/language-tabs.scss"
register_asset "stylesheets/language-preference-modal.scss"
register_asset "stylesheets/topic-list-original-title.scss"

module ::BabelReunited
  PLUGIN_NAME = "babel-reunited"
  PREFERRED_LANGUAGE_FIELD = "babel_reunited_language"
  PREFERRED_ENABLED_FIELD = "babel_reunited_enabled"
  DETECTED_LOCALE_FIELD = "babel_detected_locale"
  DETECTED_SHA_FIELD = "babel_detected_sha"

  # Recorded when the detector answers in a well-formed way we cannot use: it
  # reports the language as undetermined, or names one outside the supported
  # list. Asking again sends the same text and gets the same answer, so this
  # is stored against the content like any other result. Readers still see
  # "unknown" -- detected_locale_for filters it out -- but the backfill counts
  # the post as answered, which is what lets a re-run reach zero.
  UNDETERMINED_LOCALE = "und"

  def self.preferred_language_for(user)
    return nil unless user

    cast = ActiveModel::Type::Boolean.new

    # Custom fields path
    enabled = user.custom_fields[PREFERRED_ENABLED_FIELD]
    return nil if !enabled.nil? && cast.cast(enabled) == false

    language = user.custom_fields[PREFERRED_LANGUAGE_FIELD]
    return language if language.present?

    # Legacy fallback
    legacy = user.user_preferred_language
    return nil if legacy&.enabled == false
    legacy&.language.presence
  end

  def self.translation_enabled_for_category?(category_id)
    allowed = SiteSetting.babel_reunited_enabled_categories
    return true if allowed.blank?
    return false if category_id.nil?

    allowed.split("|").include?(category_id.to_s)
  end

  def self.translation_enabled_for_post?(post)
    translation_enabled_for_category?(post.topic&.category_id)
  end

  # A deliberate deletion must win over a translation job that was already
  # running when the person deleted (write_result! re-creates rows that
  # vanish mid-flight, which is correct for the view lane's mechanical claim
  # cleanup but must not resurrect content a person chose to remove). The
  # tombstone records WHEN the deletion happened, and only jobs that started
  # before that moment defer to it — a job started afterwards is the deletion
  # being followed by a fresh request, and its result must land, not be
  # discarded by a leftover flag. The key outlives the longest possible
  # in-flight job.
  def self.tombstone_translation!(post_id, language)
    Discourse.redis.setex(
      translation_tombstone_key(post_id, language),
      max_translation_runtime.to_i,
      Time.current.to_f.to_s
    )
  end

  def self.translation_tombstoned_since?(post_id, language, started_at)
    deleted_at =
      Discourse.redis.get(translation_tombstone_key(post_id, language))
    deleted_at.present? && deleted_at.to_f > started_at.to_f
  end

  def self.translation_tombstone_key(post_id, language)
    "babel_reunited:deleted:#{post_id}:#{language}"
  end

  # Regional variants (en-us, pt-pt) translate identically to their base
  # language, so treating them as different languages would re-open
  # self-translation for readers with legacy regional preferences. Chinese
  # variants are distinct scripts and are never collapsed.
  def self.same_language?(a, b)
    return false if a.blank? || b.blank?

    a = a.to_s.downcase
    b = b.to_s.downcase
    return true if a == b

    primary_a = a.split("-").first
    primary_b = b.split("-").first
    return false if primary_a == "zh" || primary_b == "zh"

    primary_a == primary_b
  end

  # Worst case a single translation job can legitimately occupy: every chunk
  # plus the title, each allowed a full provider timeout, with slack for
  # cooking and persistence. Both the job's lock and the view lane's claim
  # lease derive from this, so neither can cut off work that is still
  # running — a fixed value would, since the timeout is configurable up to
  # half an hour per request.
  def self.max_translation_runtime
    timeout = SiteSetting.babel_reunited_request_timeout_seconds.to_i
    ((TranslationService::MAX_CHUNKS + 1) * timeout + 120).seconds
  end

  def self.enqueue_translation_jobs(post, target_languages, force_update: false)
    return if target_languages.blank?

    target_languages.each do |language|
      Jobs.enqueue(
        Jobs::BabelReunited::TranslatePostJob,
        post_id: post.id,
        target_language: language,
        force_update: force_update
      )
    end
  end

  def self.user_has_preferred_language?(user)
    return false unless user
    user.custom_fields[PREFERRED_LANGUAGE_FIELD].present? ||
      user.user_preferred_language.present?
  end

  # Full translation row for one language, honoring the per-language preload
  # (a preloaded miss is authoritative — no fallback query).
  def self.stream_translation_for(post, language)
    return nil if post.blank? || language.blank?

    preloaded = post.instance_variable_get(:@babel_reunited_translations)
    return preloaded[language] if preloaded&.key?(language)

    BabelReunited::PostTranslation.find_translation(post.id, language)
  end

  # Every path that hands a translation body to a reader goes through here,
  # so a stale translation of content that has since been cut never escapes.
  # Same-language records are legacy data (fanout no longer creates them) and
  # can be LLM answer-mode artifacts, so they never reach a reader either.
  def self.displayable_translation_for(post, language)
    return nil if same_language?(language, current_detected_locale_for(post))

    translation = stream_translation_for(post, language)
    return nil if translation.blank?
    return nil unless translation.safe_to_display?

    translation
  end

  def self.translated_title_for(post, language)
    # A translation into the post's own language is redundant and survives a
    # rewrite as permanently stale content, so it must never supply a title.
    return nil if same_language?(language, current_detected_locale_for(post))

    translation = displayable_translation_for(post, language)

    return nil if translation.blank? || translation.failed?
    return nil if translation.translated_title.blank?

    translation.translated_title
  end

  def self.preload_post_translations(posts, language)
    return if posts.blank? || language.blank?

    translations =
      BabelReunited::PostTranslation.where(
        post_id: posts.map(&:id),
        language: language
      ).index_by(&:post_id)

    posts.each do |post|
      preloaded =
        post.instance_variable_get(:@babel_reunited_translations) || {}
      preloaded[language] = translations[post.id]
      post.instance_variable_set(:@babel_reunited_translations, preloaded)
    end
  end

  def self.preloaded_post_translation(post, language)
    post.instance_variable_get(:@babel_reunited_translations)&.[](language)
  end

  # Lightweight metadata preload: never loads translation bodies. Bodies are
  # serialized only for the viewer's preferred language (see
  # preload_post_translations) and fetched on demand for other languages.
  def self.preload_all_post_translations(posts)
    return if posts.blank?

    post_ids = posts.map(&:id)
    translations =
      BabelReunited::PostTranslation
        .where(post_id: post_ids)
        .select(
          :id,
          :post_id,
          :language,
          :status,
          :source_language,
          :created_at
        )
        .order(created_at: :desc)
    grouped = translations.group_by(&:post_id)

    posts.each do |post|
      post.instance_variable_set(
        :@babel_reunited_all_translations,
        grouped[post.id] || []
      )
    end
  end

  DETECTION_PRELOAD_IVAR = :@babel_detection_fields

  # Detection lives in post custom fields, and both the original tab's label
  # and every translated title consult it, so without a preload each post in
  # a stream or a list costs its own custom-field query.
  #
  # TopicView.default_post_custom_fields does not help here: it only fills
  # TopicView's own sideload hash, never Post#custom_fields, which is what
  # this plugin reads.
  #
  # Deliberately not Post.preload_custom_fields either — that installs a
  # proxy which raises NotPreloadedError for any field outside the list, so
  # preloading two fields would turn every unrelated custom-field read on the
  # same objects into a 500. A private ivar cannot break anyone else's access.
  def self.preload_detection_fields(posts)
    posts = Array(posts).compact
    return if posts.empty?

    grouped = Hash.new { |h, k| h[k] = {} }
    PostCustomField
      .where(
        post_id: posts.map(&:id),
        name: [DETECTED_LOCALE_FIELD, DETECTED_SHA_FIELD]
      )
      .pluck(:post_id, :name, :value)
      .each { |post_id, name, value| grouped[post_id][name] = value }

    posts.each do |post|
      post.instance_variable_set(DETECTION_PRELOAD_IVAR, grouped[post.id])
    end
  end

  def self.detection_field(post, name)
    preloaded = post.instance_variable_get(DETECTION_PRELOAD_IVAR)
    return preloaded[name] if preloaded

    post.custom_fields[name]
  end

  def self.preloaded_all_translations(post)
    post.instance_variable_get(:@babel_reunited_all_translations)
  end

  def self.auto_translate_languages
    raw = SiteSetting.babel_reunited_auto_translate_languages
    return [] if raw.blank?

    codes = raw.split(",").map(&:strip).reject(&:blank?)
    valid, invalid = codes.partition { |code| Locales.valid?(code) }
    if invalid.any?
      Rails.logger.warn(
        "BabelReunited: ignoring unsupported auto_translate_languages entries: #{invalid.join(", ")}"
      )
    end
    valid
  end

  def self.detected_locale_for(post)
    return nil if post.blank?
    locale = detection_field(post, DETECTED_LOCALE_FIELD).presence
    locale == UNDETERMINED_LOCALE ? nil : locale
  end

  # Detection is bound to the raw content it sampled: a post rewritten in
  # another language re-detects instead of trusting a stale result forever.
  def self.detection_raw_sha(post)
    Digest::SHA256.hexdigest(post.raw.to_s)
  end

  # Whether an answer is on record for the post's current content -- a
  # language, or UNDETERMINED_LOCALE. Deliberately not the same question as
  # "do we know the language"; callers that need that ask
  # current_detected_locale_for. Keeping the two apart is what lets a post the
  # detector cannot classify count as answered instead of outstanding.
  def self.detection_current?(post)
    return false if post.blank?
    detection_field(post, DETECTED_LOCALE_FIELD).present? &&
      detection_field(post, DETECTED_SHA_FIELD) == detection_raw_sha(post)
  end

  # The only detection result callers may act on. A result bound to older
  # content proves nothing about the post's current language, so treating it
  # as unknown (nil) is what makes the degradation paths correct: fan out to
  # every configured language rather than silently skipping the wrong one.
  def self.current_detected_locale_for(post)
    detection_current?(post) ? detected_locale_for(post) : nil
  end

  # Mirrors the translate job's guards. Detection ships post content to a
  # third-party provider, so it must refuse the same posts translation does.
  #
  # The global switch belongs here rather than only at the entry points: it is
  # what an admin flips when something is wrong, and callers that check it
  # once and then work through a queue -- a job that was already enqueued, an
  # hour-long backfill -- would keep sending content after it was thrown.
  # Asked immediately before each call, throwing it stops everything that has
  # not gone out yet.
  def self.translatable_post?(post)
    return false unless SiteSetting.babel_reunited_enabled
    return false if post.blank? || post.raw.blank?
    return false if post.deleted_at.present? || post.hidden?
    translation_enabled_for_post?(post)
  end

  # The banner payload is cached process-wide and no post-level event
  # invalidates it, so a translation that lands (or is deleted) after the
  # banner was first rendered would otherwise never reach readers. Core clears
  # the whole cache rather than single keys, so this does the same.
  def self.clear_banner_cache_for(post)
    return if post.blank? || post.post_number != 1
    return unless post.topic&.archetype == Archetype.banner

    ApplicationLayoutPreloader.banner_json_cache.clear
  end

  # A preload is a snapshot, and reload does not touch it: it is a plain ivar,
  # not an association cache. Any code that has to see the field as it is now
  # -- after a write here, or after taking a lock somebody else may have
  # written under -- has to drop it first.
  def self.clear_detection_preload(post)
    return if post.blank?
    return unless post.instance_variable_defined?(DETECTION_PRELOAD_IVAR)

    post.remove_instance_variable(DETECTION_PRELOAD_IVAR)
  end

  def self.store_detected_locale(post, locale, raw_sha: nil)
    return if post.blank? || locale.blank?
    post.custom_fields[DETECTED_LOCALE_FIELD] = locale
    post.custom_fields[DETECTED_SHA_FIELD] = raw_sha || detection_raw_sha(post)
    post.save_custom_fields
    clear_detection_preload(post)
  end

  # The one way a detection result becomes a record. Both the job and the rake
  # backfill go through here, because the two guards below are easy to have in
  # one path and not the other, and each is silent when it is missing.
  #
  # The result is refused unless it still describes the post's current content.
  # A post edited mid-call may already carry a newer, correct detection -- the
  # edit triggers one -- and writing the older answer over it does not just
  # miss, it destroys a result that was right and leaves the post needing
  # detection again.
  #
  # Publishing is the other half: detection lands seconds after a page
  # renders, so a client that loaded in the gap believes the language is
  # unknown and offers to translate the post into itself. Only a real language
  # corrects that; an undetermined post already renders as one with no
  # detection, so it stays quiet.
  #
  # Returns whether the result was recorded.
  def self.record_detected_locale(post, locale, sampled_sha)
    return false if post.blank?

    recorded = false

    begin
      # The row lock is what makes deciding and writing one step. Checking and
      # then writing leaves a gap, and the writer that fits in it is the one
      # that matters: a detection triggered by the edit, holding the answer
      # for the new content. Every writer takes this lock, so they serialize
      # and the loser re-reads and stands down.
      post.with_lock do
        # with_lock reloads the row, but the detection preload is an ivar and
        # survives that. A caller that preloaded before its provider call --
        # the backfill does, for every post in the batch -- is holding a
        # snapshot taken before any of this, and reading it here would make
        # the check below answer about the past.
        clear_detection_preload(post)

        # Another detection of this same content may have finished while this
        # one was in flight -- a queued job and the backfill can overlap on
        # one post. Two answers for one sha are two calls that may disagree,
        # and since publishing happens after the transaction the second write
        # can reach clients before the first, leaving them on a locale the
        # database does not hold. First result recorded wins; this one stands
        # down having changed nothing.
        next if detection_current?(post)

        # Eligibility is checked before the call as well, but a post can be
        # hidden or trashed while it is in flight and neither shows up as a
        # missing row -- reload is unscoped, so only a hard delete raises.
        if detection_raw_sha(post) == sampled_sha && translatable_post?(post)
          store_detected_locale(post, locale, raw_sha: sampled_sha)
          recorded = true
        end
      end
    rescue ActiveRecord::RecordNotFound
      # Deleted outright while the call was in flight. Nothing to record, and
      # nothing to retry either.
      return false
    end

    # After the transaction: a message about a write that has not committed
    # describes something that may never become true.
    if recorded && locale != UNDETERMINED_LOCALE
      publish_detected_locale(post, locale)
    end
    recorded
  end

  def self.publish_detected_locale(post, locale)
    MessageBus.publish(
      "/post-translations/#{post.id}",
      { post_id: post.id, detected_locale: locale },
      **BabelReunited::MessageBusAudience.options_for(post)
    )
  end

  # Lazy convergence for posts created before detection existed. Deduplicated
  # via Redis so a burst of translate jobs enqueues one detection, not N.
  def self.detection_backfill_key(post_id)
    "babel_reunited:detect_enqueued:#{post_id}"
  end

  # Every post that carries a translation, as a relation rather than a list of
  # ids: the rake backfill streams it, and a subquery keeps translations whose
  # post is gone from being counted as work.
  def self.posts_needing_detection
    Post.where(id: BabelReunited::PostTranslation.select(:post_id))
  end

  def self.enqueue_detection_backfill(post)
    return false if post.blank?

    key = detection_backfill_key(post.id)
    return false unless Discourse.redis.set(key, "1", nx: true, ex: 600)

    Jobs.enqueue(Jobs::BabelReunited::DetectPostLanguageJob, post_id: post.id)
    true
  end

  # Enqueues pre-translate layer jobs, skipping the post's own language when
  # detection already identified it (the original tab covers that language).
  def self.fanout_translations(post)
    return unless SiteSetting.babel_reunited_enabled
    return unless translatable_post?(post)

    detected = current_detected_locale_for(post)
    languages =
      auto_translate_languages.reject { |l| same_language?(l, detected) }
    return if languages.empty?

    languages.each do |language|
      PostTranslation.create_or_update_record(post.id, language)
    end
    enqueue_translation_jobs(post, languages)
  end

  def self.trigger_auto_translation(post)
    return unless SiteSetting.babel_reunited_enabled
    return unless translatable_post?(post)

    Jobs.enqueue(
      Jobs::BabelReunited::DetectPostLanguageJob,
      post_id: post.id,
      then_fanout: true
    )
  end

  def self.trigger_retranslation(post)
    return unless SiteSetting.babel_reunited_enabled
    return if post.blank? || post.raw.blank?

    content_changed = !detection_current?(post)

    # When the content changed, the post may now be in a different language,
    # so no split can be trusted and every completed translation is outdated.
    # A metadata-only edit keeps the pre-translate layer, refreshed below.
    eager =
      if content_changed
        []
      else
        auto_translate_languages.reject do |l|
          same_language?(l, detected_locale_for(post))
        end
      end

    # Invalidation is local bookkeeping and runs for every post, including the
    # ones we will not send anywhere below: a hidden post whose content
    # changed still has outdated translations, and they must not resurface as
    # current when it becomes visible again. Rows are compared against the
    # translation fingerprint (which includes the title), not the raw-only
    # detection sha, so a title-only edit invalidates lazy rows too.
    current_sha = Jobs::BabelReunited::TranslatePostJob.content_sha(post)
    # IS DISTINCT FROM: legacy rows with a NULL source_sha are outdated too;
    # where.not would skip them under SQL NULL semantics.
    outdated =
      post
        .post_translations
        .where(status: "completed")
        .where("source_sha IS DISTINCT FROM ?", current_sha)
    outdated = outdated.where.not(language: eager) if eager.any?
    outdated.update_all(status: "stale", updated_at: Time.current)

    # A failure verdict describes the content that produced it, so new content
    # deserves a fresh attempt. Without this a translation that failed
    # permanently — "content too long", say — can never run again even after
    # the author shortens the post: auto_retryable? stays false forever and
    # every view trigger noops on failed_not_retryable.
    #
    # Judged by the same fingerprint as completed rows, so a title-only edit
    # clears the verdict too and a metadata-only edit leaves it standing.
    # Legacy rows with no fingerprint count as outdated: a fresh attempt is
    # the safe direction for a failure.
    post
      .post_translations
      .where(status: "failed")
      .where("source_sha IS DISTINCT FROM ?", current_sha)
      .find_each(&:clear_failure_metadata!)

    # Dispatching work, unlike invalidation, ships content to a third-party
    # provider: deleted, hidden, and disabled-category posts stop here.
    return unless translatable_post?(post)

    if content_changed
      Jobs.enqueue(
        Jobs::BabelReunited::DetectPostLanguageJob,
        post_id: post.id,
        then_fanout: true
      )
      return
    end

    return if eager.empty?

    eager.each do |language|
      PostTranslation.create_or_update_record(post.id, language)
    end
    enqueue_translation_jobs(post, eager, force_update: true)
  end
end

require_relative "lib/babel_reunited/engine"
require_relative "lib/babel_reunited/locales"
require_relative "lib/babel_reunited/usage_fuse"
require_relative "lib/babel_reunited/banner_translator"
require_relative "lib/babel_reunited/topic_extension"
require_relative "lib/babel_reunited/layout_preloader_extension"

# Load models BEFORE after_initialize
require_relative "app/models/babel_reunited/post_translation"
require_relative "app/models/babel_reunited/user_preferred_language"
require_relative "lib/babel_reunited/post_extension"

after_initialize do
  register_post_custom_field_type(
    BabelReunited::DETECTED_LOCALE_FIELD,
    :string,
    max_length: 10
  )
  register_post_custom_field_type(
    BabelReunited::DETECTED_SHA_FIELD,
    :string,
    max_length: 64
  )

  register_editable_user_custom_field(BabelReunited::PREFERRED_LANGUAGE_FIELD)
  register_editable_user_custom_field(BabelReunited::PREFERRED_ENABLED_FIELD)
  register_user_custom_field_type(
    BabelReunited::PREFERRED_LANGUAGE_FIELD,
    :string,
    max_length: 10
  )
  register_user_custom_field_type(
    BabelReunited::PREFERRED_ENABLED_FIELD,
    :boolean
  )
  DiscoursePluginRegistry.serialized_current_user_fields << BabelReunited::PREFERRED_LANGUAGE_FIELD
  DiscoursePluginRegistry.serialized_current_user_fields << BabelReunited::PREFERRED_ENABLED_FIELD

  # Load other required files
  require_relative "app/services/babel_reunited/translation_service"
  require_relative "app/services/babel_reunited/language_detection_service"
  require_relative "app/jobs/regular/babel_reunited/translate_post_job"
  require_relative "app/jobs/regular/babel_reunited/detect_post_language_job"
  require_relative "app/controllers/babel_reunited/translations_controller"
  require_relative "app/controllers/babel_reunited/admin_controller"
  require_relative "app/serializers/babel_reunited/post_translation_serializer"
  require_relative "lib/babel_reunited/rate_limiter"
  require_relative "lib/babel_reunited/translation_logger"
  require_relative "lib/babel_reunited/message_bus_audience"
  require_relative "lib/babel_reunited/markdown_protector"
  require_relative "lib/babel_reunited/content_splitter"
  require_relative "lib/babel_reunited/translated_cooked_post_processor"
  require_relative "lib/babel_reunited/translated_cooker"
  require_relative "lib/babel_reunited/translation_recooker"
  require_relative "lib/babel_reunited/translation_structure"
  require_relative "app/lib/babel_reunited/providers/base"
  require_relative "app/lib/babel_reunited/providers/open_ai_compatible"
  require_relative "app/lib/babel_reunited/providers/anthropic"

  # Mount the engine routes
  Discourse::Application.routes.append do
    mount ::BabelReunited::Engine, at: "/babel-reunited"
  end

  # Extend Post model with translation functionality
  reloadable_patch do
    Post.class_eval do # rubocop:disable Discourse/Plugins/NoMonkeyPatching
      has_many :post_translations,
               class_name: "BabelReunited::PostTranslation",
               dependent: :destroy

      prepend BabelReunited::PostExtension
    end
  end

  reloadable_patch do
    User.class_eval do # rubocop:disable Discourse/Plugins/NoMonkeyPatching
      has_one :user_preferred_language,
              class_name: "BabelReunited::UserPreferredLanguage",
              dependent: :destroy
    end
  end

  # The banner renders outside the post stream, so no connector or serializer
  # can reach it. These two are the only seams that exist.
  reloadable_patch do
    Topic.prepend(BabelReunited::TopicExtension)
    ApplicationLayoutPreloader.prepend(BabelReunited::LayoutPreloaderExtension)
  end

  plugin_enabled_condition = -> { SiteSetting.babel_reunited_enabled }

  add_to_serializer(
    :post,
    :babel_translations_meta,
    include_condition: plugin_enabled_condition
  ) do
    # The category setting scopes the whole feature: an excluded category
    # ships no translation data at all, matching the gated read endpoints.
    next nil unless BabelReunited.translation_enabled_for_post?(object)

    preloaded = BabelReunited.preloaded_all_translations(object)
    rows =
      preloaded ||
        object
          .post_translations
          .select(:id, :post_id, :language, :status, :source_language)
          .to_a
    # Every status ships: the client's state machine needs translating rows
    # to keep showing progress across reloads (and not re-enqueue, burning
    # fuse quota) and failed rows to offer a retry. Bodies stay guarded by
    # displayable_translation_for / the show endpoint; metadata is harmless.
    # Same-language records must not surface as switchable languages though.
    detected = BabelReunited.current_detected_locale_for(object)
    if detected
      rows =
        rows.reject { |t| BabelReunited.same_language?(t.language, detected) }
    end
    rows.map do |t|
      {
        language: t.language,
        status: t.status,
        source_language: t.source_language
      }
    end
  end

  add_to_serializer(
    :post,
    :show_translation_widget,
    include_condition: plugin_enabled_condition
  ) do
    next false unless BabelReunited.translation_enabled_for_post?(object)

    preloaded = BabelReunited.preloaded_all_translations(object)
    preloaded ? preloaded.any? : object.post_translations.exists?
  end

  add_to_serializer(
    :post,
    :show_translation_button,
    include_condition: plugin_enabled_condition
  ) { BabelReunited.translation_enabled_for_post?(object) }

  # Only a detection bound to the post's current content is reported: a stale
  # one would mislabel the original tab and hide the language the reader now
  # needs, until re-detection lands.
  add_to_serializer(
    :post,
    :babel_detected_locale,
    include_condition: plugin_enabled_condition
  ) do
    next nil unless BabelReunited.translation_enabled_for_post?(object)

    BabelReunited.current_detected_locale_for(object)
  end

  add_to_serializer(
    :current_user,
    :preferred_language,
    include_condition: plugin_enabled_condition
  ) { BabelReunited.preferred_language_for(object) }

  add_to_serializer(
    :current_user,
    :preferred_language_enabled,
    include_condition: plugin_enabled_condition
  ) do
    cast = ActiveModel::Type::Boolean.new
    enabled = object.custom_fields[BabelReunited::PREFERRED_ENABLED_FIELD]
    if enabled.nil?
      legacy = object.user_preferred_language
      legacy.nil? ? true : legacy.enabled
    else
      cast.cast(enabled)
    end
  end

  translated_title_condition = -> do
    SiteSetting.babel_reunited_enabled &&
      BabelReunited.preferred_language_for(scope&.user).present?
  end

  # Full body for exactly one language per post: the viewer's preference.
  # Everything else ships as babel_translations_meta and is fetched on demand.
  add_to_serializer(
    :post,
    :babel_preferred_translation,
    include_condition: translated_title_condition
  ) do
    next nil unless BabelReunited.translation_enabled_for_post?(object)

    language = BabelReunited.preferred_language_for(scope&.user)
    translation = BabelReunited.displayable_translation_for(object, language)
    if translation
      BabelReunited::PostTranslationSerializer.new(
        translation,
        root: false
      ).as_json
    end
  end

  # NOTE: Field is named `babel_translated_title` (not `translated_title`) to avoid
  # colliding with LocalizedFancyTopicTitleMixin's private `translated_title` method,
  # which is called by `fancy_title` in topic serializers.
  add_to_serializer(
    :topic_view,
    :babel_translated_title,
    include_condition: translated_title_condition
  ) do
    unless BabelReunited.translation_enabled_for_category?(
             object.topic&.category_id
           )
      return nil
    end

    language = BabelReunited.preferred_language_for(scope&.user)
    return nil unless language

    BabelReunited.translated_title_for(object.topic&.first_post, language)
  end

  add_to_serializer(
    :listable_topic,
    :babel_translated_title,
    include_condition: translated_title_condition
  ) do
    unless BabelReunited.translation_enabled_for_category?(object.category_id)
      return nil
    end

    language = BabelReunited.preferred_language_for(scope&.user)
    return nil unless language

    BabelReunited.translated_title_for(object.first_post, language)
  end

  add_to_serializer(
    :topic_list_item,
    :babel_translated_title,
    include_condition: translated_title_condition
  ) do
    unless BabelReunited.translation_enabled_for_category?(object.category_id)
      return nil
    end

    language = BabelReunited.preferred_language_for(scope&.user)
    return nil unless language

    BabelReunited.translated_title_for(object.first_post, language)
  end

  TopicView.on_preload do |topic_view|
    next unless SiteSetting.babel_reunited_enabled

    posts = topic_view.posts
    BabelReunited.preload_all_post_translations(posts) if posts.present?

    # Ahead of the preferred-language check: babel_detected_locale is
    # serialized for every reader, including those with no preference, and
    # topic.first_post is a separate object from its stream copy.
    BabelReunited.preload_detection_fields(
      posts.to_a + [topic_view.topic&.first_post]
    )

    language = BabelReunited.preferred_language_for(topic_view.guardian&.user)
    next if language.blank?

    # Full rows (with bodies) for the preferred language: every stream post
    # feeds babel_preferred_translation, the first post also feeds the
    # topic-level translated title. No uniq: the first_post association object
    # is distinct from its stream copy and needs its own preload ivar.
    targets = (posts.to_a + [topic_view.topic&.first_post]).compact
    BabelReunited.preload_post_translations(targets, language)
  end

  TopicList.on_preload do |topics, topic_list|
    next unless SiteSetting.babel_reunited_enabled

    # Only the translated title consults detection here, so this can sit
    # behind the preference check — but the check has to come after the
    # first_posts load either way.
    language = BabelReunited.preferred_language_for(topic_list.current_user)
    next if language.blank?

    first_posts = topics.map(&:first_post).compact
    BabelReunited.preload_post_translations(first_posts, language)
    BabelReunited.preload_detection_fields(first_posts)
  end

  # The banner payload is cached with whatever these settings allowed when it
  # was built, and nothing else invalidates it, so turning the plugin off or
  # narrowing the enabled categories would otherwise keep serving the
  # translation until some unrelated event cleared the cache.
  on(:site_setting_changed) do |name, _old_value, _new_value|
    if %i[babel_reunited_enabled babel_reunited_enabled_categories].include?(
         name.to_sym
       )
      ApplicationLayoutPreloader.banner_json_cache.clear
    end
  end

  # Event handlers for automatic translation
  on(:post_created) { |post| BabelReunited.trigger_auto_translation(post) }

  on(:post_edited) { |post| BabelReunited.trigger_retranslation(post) }

  on(:category_created) do |category|
    BabelReunited.trigger_auto_translation(category.topic&.first_post)
  end

  # User login event handler for language preference prompt
  on(:user_logged_in) do |user|
    next unless SiteSetting.babel_reunited_enabled
    next if BabelReunited.user_has_preferred_language?(user)

    MessageBus.publish(
      "/language-preference-prompt/#{user.id}",
      { user_id: user.id, username: user.username },
      user_ids: [user.id]
    )
  end

  # Add admin route
  add_admin_route "babel_reunited.title",
                  "babel-reunited",
                  use_new_show_route: true
end
