# frozen_string_literal: true

# name: babel-reunited
# about: AI-powered post translation plugin that automatically translates posts to multiple languages using third-party AI APIs
# meta_topic_id: TODO
# version: 0.1.0
# authors: Divine Rapier
# url: https://github.com/divine-rapier/babel-reunited
# required_version: 2.7.0

enabled_site_setting :babel_reunited_enabled

register_asset "stylesheets/translated-title.scss"

module ::BabelReunited
  PLUGIN_NAME = "babel-reunited"
  PREFERRED_LANGUAGE_FIELD = "babel_reunited_language"
  PREFERRED_ENABLED_FIELD = "babel_reunited_enabled"

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

  def self.enqueue_translation_jobs(post, target_languages, force_update: false)
    return if target_languages.blank?

    target_languages.each do |language|
      Jobs.enqueue(
        Jobs::BabelReunited::TranslatePostJob,
        post_id: post.id,
        target_language: language,
        force_update: force_update,
      )
    end
  end

  def self.user_has_preferred_language?(user)
    return false unless user
    user.custom_fields[PREFERRED_LANGUAGE_FIELD].present? || user.user_preferred_language.present?
  end

  def self.translated_title_for(post, language)
    return nil if post.blank? || language.blank?

    preloaded = post.instance_variable_get(:@babel_reunited_translations)
    translation =
      if preloaded&.key?(language)
        preloaded[language]
      else
        BabelReunited::PostTranslation.find_translation(post.id, language)
      end

    return nil unless translation&.completed? && translation.translated_title.present?

    translation.translated_title
  end

  def self.preload_post_translations(posts, language)
    return if posts.blank? || language.blank?

    translations =
      BabelReunited::PostTranslation.where(post_id: posts.map(&:id), language: language).index_by(
        &:post_id
      )

    posts.each do |post|
      preloaded = post.instance_variable_get(:@babel_reunited_translations) || {}
      preloaded[language] = translations[post.id]
      post.instance_variable_set(:@babel_reunited_translations, preloaded)
    end
  end

  def self.preloaded_post_translation(post, language)
    post.instance_variable_get(:@babel_reunited_translations)&.[](language)
  end

  def self.preload_all_post_translations(posts)
    return if posts.blank?

    post_ids = posts.map(&:id)
    translations = BabelReunited::PostTranslation.where(post_id: post_ids).order(created_at: :desc)
    grouped = translations.group_by(&:post_id)

    posts.each do |post|
      post.instance_variable_set(:@babel_reunited_all_translations, grouped[post.id] || [])
    end
  end

  def self.preloaded_all_translations(post)
    post.instance_variable_get(:@babel_reunited_all_translations)
  end
end

require_relative "lib/babel_reunited/engine"

# Load models BEFORE after_initialize
require_relative "app/models/babel_reunited/post_translation"
require_relative "app/models/babel_reunited/user_preferred_language"
require_relative "lib/babel_reunited/post_extension"

after_initialize do
  register_editable_user_custom_field(BabelReunited::PREFERRED_LANGUAGE_FIELD)
  register_editable_user_custom_field(BabelReunited::PREFERRED_ENABLED_FIELD)
  register_user_custom_field_type(BabelReunited::PREFERRED_LANGUAGE_FIELD, :string, max_length: 10)
  register_user_custom_field_type(BabelReunited::PREFERRED_ENABLED_FIELD, :boolean)
  DiscoursePluginRegistry.serialized_current_user_fields << BabelReunited::PREFERRED_LANGUAGE_FIELD
  DiscoursePluginRegistry.serialized_current_user_fields << BabelReunited::PREFERRED_ENABLED_FIELD

  # Load other required files
  require_relative "app/services/babel_reunited/translation_service"
  require_relative "app/jobs/regular/babel_reunited/translate_post_job"
  require_relative "app/controllers/babel_reunited/translations_controller"
  require_relative "app/controllers/babel_reunited/admin_controller"
  require_relative "app/serializers/babel_reunited/post_translation_serializer"
  require_relative "lib/babel_reunited/rate_limiter"
  require_relative "lib/babel_reunited/translation_logger"
  require_relative "lib/babel_reunited/message_bus_audience"
  require_relative "lib/babel_reunited/markdown_protector"

  # Mount the engine routes
  Discourse::Application.routes.append { mount ::BabelReunited::Engine, at: "/babel-reunited" }

  # Extend Post model with translation functionality
  reloadable_patch do
    Post.class_eval do # rubocop:disable Discourse/Plugins/NoMonkeyPatching
      has_many :post_translations, class_name: "BabelReunited::PostTranslation", dependent: :destroy

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

  add_to_serializer(:post, :available_translations, include_condition: plugin_enabled_condition) do
    preloaded = BabelReunited.preloaded_all_translations(object)
    if preloaded
      preloaded.map(&:language)
    else
      object.post_translations.pluck(:language)
    end
  end

  add_to_serializer(:post, :post_translations, include_condition: plugin_enabled_condition) do
    preloaded = BabelReunited.preloaded_all_translations(object)
    translations =
      if preloaded
        preloaded.first(5)
      else
        object.post_translations.recent.limit(5).to_a
      end
    translations.map { |t| BabelReunited::PostTranslationSerializer.new(t).as_json }
  end

  add_to_serializer(:post, :show_translation_widget, include_condition: plugin_enabled_condition) do
    preloaded = BabelReunited.preloaded_all_translations(object)
    if preloaded
      preloaded.any?
    else
      object.post_translations.exists?
    end
  end

  add_to_serializer(:post, :show_translation_button, include_condition: plugin_enabled_condition) do
    true
  end

  add_to_serializer(
    :current_user,
    :preferred_language,
    include_condition: plugin_enabled_condition,
  ) { BabelReunited.preferred_language_for(object) }

  add_to_serializer(
    :current_user,
    :preferred_language_enabled,
    include_condition: plugin_enabled_condition,
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
    SiteSetting.babel_reunited_enabled && BabelReunited.preferred_language_for(scope&.user).present?
  end

  add_to_serializer(
    :topic_view,
    :translated_title,
    include_condition: translated_title_condition,
  ) do
    language = BabelReunited.preferred_language_for(scope&.user)
    return nil unless language

    BabelReunited.translated_title_for(object.topic&.first_post, language)
  end

  add_to_serializer(
    :listable_topic,
    :translated_title,
    include_condition: translated_title_condition,
  ) do
    language = BabelReunited.preferred_language_for(scope&.user)
    return nil unless language

    BabelReunited.translated_title_for(object.first_post, language)
  end

  add_to_serializer(
    :topic_list_item,
    :translated_title,
    include_condition: translated_title_condition,
  ) do
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

    first_post = topic_view.topic&.first_post
    BabelReunited.preload_post_translations([first_post].compact, language)
  end

  TopicList.on_preload do |topics, topic_list|
    next unless SiteSetting.babel_reunited_enabled

    language = BabelReunited.preferred_language_for(topic_list.current_user)
    next if language.blank?

    first_posts = topics.map(&:first_post).compact
    BabelReunited.preload_post_translations(first_posts, language)
  end

  # Event handlers for automatic translation
  on(:post_created) do |post|
    next unless SiteSetting.babel_reunited_enabled
    next if post.raw.blank?

    auto_translate_languages = SiteSetting.babel_reunited_auto_translate_languages
    if auto_translate_languages.present?
      languages = auto_translate_languages.split(",").map(&:strip)

      languages.each do |language|
        BabelReunited::PostTranslation.create_or_update_record(post.id, language)
      end

      BabelReunited.enqueue_translation_jobs(post, languages)
    end
  end

  on(:post_edited) do |post|
    next unless SiteSetting.babel_reunited_enabled
    next if post.raw.blank?

    existing_languages = post.post_translations.pluck(:language)

    auto_translate_languages = SiteSetting.babel_reunited_auto_translate_languages
    target_languages =
      if auto_translate_languages.present?
        auto_translate_languages.split(",").map(&:strip)
      else
        []
      end

    languages_to_translate = (existing_languages + target_languages).uniq

    if languages_to_translate.any?
      languages_to_translate.each do |language|
        BabelReunited::PostTranslation.create_or_update_record(post.id, language)
      end

      BabelReunited.enqueue_translation_jobs(post, languages_to_translate, force_update: true)
    end
  end

  # User login event handler for language preference prompt
  on(:user_logged_in) do |user|
    next unless SiteSetting.babel_reunited_enabled
    next if BabelReunited.user_has_preferred_language?(user)

    MessageBus.publish(
      "/language-preference-prompt/#{user.id}",
      { user_id: user.id, username: user.username },
      user_ids: [user.id],
    )
  end

  # Add admin route
  add_admin_route "babel_reunited.title", "babel-reunited", use_new_show_route: true

  # Register frontend widgets and components
  register_asset "stylesheets/preferences.scss"
  register_asset "stylesheets/language-tabs.scss"
  register_asset "stylesheets/language-preference-modal.scss"
end
