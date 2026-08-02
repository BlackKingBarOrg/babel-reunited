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

  def self.translated_title_for(post, language)
    # A translation into the post's own language is redundant and survives a
    # rewrite as permanently stale content, so it must never supply a title.
    return nil if language == current_detected_locale_for(post)

    translation = stream_translation_for(post, language)

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
    post.custom_fields[DETECTED_LOCALE_FIELD].presence
  end

  # Detection is bound to the raw content it sampled: a post rewritten in
  # another language re-detects instead of trusting a stale result forever.
  def self.detection_raw_sha(post)
    Digest::SHA256.hexdigest(post.raw.to_s)
  end

  def self.detection_current?(post)
    return false if post.blank?
    detected_locale_for(post).present? &&
      post.custom_fields[DETECTED_SHA_FIELD] == detection_raw_sha(post)
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
  def self.translatable_post?(post)
    return false if post.blank? || post.raw.blank?
    return false if post.deleted_at.present? || post.hidden?
    translation_enabled_for_post?(post)
  end

  def self.store_detected_locale(post, locale, raw_sha: nil)
    return if post.blank? || locale.blank?
    post.custom_fields[DETECTED_LOCALE_FIELD] = locale
    post.custom_fields[DETECTED_SHA_FIELD] = raw_sha || detection_raw_sha(post)
    post.save_custom_fields
  end

  # Lazy convergence for posts created before detection existed. Deduplicated
  # via Redis so a burst of translate jobs enqueues one detection, not N.
  def self.enqueue_detection_backfill(post)
    return if post.blank?

    key = "babel_reunited:detect_enqueued:#{post.id}"
    return unless Discourse.redis.set(key, "1", nx: true, ex: 600)

    Jobs.enqueue(Jobs::BabelReunited::DetectPostLanguageJob, post_id: post.id)
  end

  # Enqueues pre-translate layer jobs, skipping the post's own language when
  # detection already identified it (the original tab covers that language).
  def self.fanout_translations(post)
    return unless SiteSetting.babel_reunited_enabled
    return unless translatable_post?(post)

    languages =
      auto_translate_languages - [current_detected_locale_for(post)].compact
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
        auto_translate_languages - [detected_locale_for(post)].compact
      end

    # Invalidation is local bookkeeping and runs for every post, including the
    # ones we will not send anywhere below: a hidden post whose content
    # changed still has outdated translations, and they must not resurface as
    # current when it becomes visible again.
    outdated = post.post_translations.where(status: "completed")
    outdated = outdated.where.not(language: eager) if eager.any?
    outdated.update_all(status: "stale", updated_at: Time.current)

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
  TopicView.default_post_custom_fields << BabelReunited::DETECTED_LOCALE_FIELD

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

  plugin_enabled_condition = -> { SiteSetting.babel_reunited_enabled }

  add_to_serializer(
    :post,
    :babel_translations_meta,
    include_condition: plugin_enabled_condition
  ) do
    preloaded = BabelReunited.preloaded_all_translations(object)
    rows =
      preloaded ||
        object
          .post_translations
          .select(:id, :post_id, :language, :status, :source_language)
          .to_a
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
  ) { BabelReunited.current_detected_locale_for(object) }

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
    language = BabelReunited.preferred_language_for(scope&.user)
    translation = BabelReunited.stream_translation_for(object, language)
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

    language = BabelReunited.preferred_language_for(topic_list.current_user)
    next if language.blank?

    first_posts = topics.map(&:first_post).compact
    BabelReunited.preload_post_translations(first_posts, language)
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
