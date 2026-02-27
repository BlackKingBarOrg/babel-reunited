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

  def self.preferred_language_for(user)
    return nil unless user

    user_preferred_language = user.user_preferred_language
    return nil if user_preferred_language&.enabled == false

    user_preferred_language&.language.presence
  end

  def self.translated_title_for(post, language)
    return nil if post.blank? || language.blank?

    translation =
      preloaded_post_translation(post, language) ||
        BabelReunited::PostTranslation.find_translation(post.id, language)

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
end

require_relative "lib/babel_reunited/engine"

# Load models BEFORE after_initialize
require_relative "app/models/babel_reunited/post_translation"
require_relative "app/models/babel_reunited/user_preferred_language"
require_relative "lib/babel_reunited/post_extension"

after_initialize do
  # Load other required files
  require_relative "app/services/babel_reunited/translation_service"
  require_relative "app/jobs/regular/babel_reunited/translate_post_job"
  require_relative "app/controllers/babel_reunited/translations_controller"
  require_relative "app/controllers/babel_reunited/admin_controller"
  require_relative "app/serializers/babel_reunited/post_translation_serializer"
  require_relative "lib/babel_reunited/rate_limiter"
  require_relative "lib/babel_reunited/translation_logger"

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

  # Add translation methods to PostSerializer
  add_to_serializer(:post, :available_translations, include_condition: -> { true }) do
    object.available_translations
  end

  add_to_serializer(:post, :post_translations, include_condition: -> { true }) do
    object
      .post_translations
      .recent
      .limit(5)
      .map { |translation| BabelReunited::PostTranslationSerializer.new(translation).as_json }
  end

  add_to_serializer(:post, :show_translation_widget, include_condition: -> { true }) do
    object.post_translations.exists?
  end

  add_to_serializer(:post, :show_translation_button, include_condition: -> { true }) { true }

  add_to_serializer(:current_user, :preferred_language, include_condition: -> { true }) do
    object.user_preferred_language&.language
  end

  add_to_serializer(:current_user, :preferred_language_enabled, include_condition: -> { true }) do
    object.user_preferred_language&.enabled
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

      # Pre-create translation records to show "translating" status immediately
      languages.each { |language| post.create_or_update_translation_record(language) }

      post.enqueue_translation_jobs(languages)
    end
  end

  on(:post_edited) do |post|
    next unless SiteSetting.babel_reunited_enabled
    next if post.raw.blank?

    # Get existing translations
    existing_languages = post.available_translations

    # Get auto-translate languages from settings
    auto_translate_languages = SiteSetting.babel_reunited_auto_translate_languages
    target_languages =
      if auto_translate_languages.present?
        auto_translate_languages.split(",").map(&:strip)
      else
        []
      end

    # Combine existing translations and auto-translate languages
    # This ensures we re-translate existing ones AND create missing ones
    languages_to_translate = (existing_languages + target_languages).uniq

    if languages_to_translate.any?
      # Pre-create/update translation records to show "translating" status immediately
      languages_to_translate.each { |language| post.create_or_update_translation_record(language) }

      # Use force_update for existing translations, normal for new ones
      post.enqueue_translation_jobs(languages_to_translate, force_update: true)
    end
  end

  on(:post_destroyed) do |post|
    # Translations will be automatically deleted due to dependent: :destroy
  end

  # User login event handler for language preference prompt
  on(:user_logged_in) do |user|
    next unless SiteSetting.babel_reunited_enabled
    next if user.user_preferred_language.present?

    # Use MessageBus to trigger frontend modal display
    MessageBus.publish(
      "/language-preference-prompt/#{user.id}",
      { user_id: user.id, username: user.username },
    )
  end

  # Add admin route
  add_admin_route "babel_reunited.title", "babel-reunited", use_new_show_route: true

  # Register frontend widgets and components
  register_asset "stylesheets/translation-widgets.scss"
  register_asset "stylesheets/preferences.scss"
  register_asset "stylesheets/language-tabs.scss"
  register_asset "stylesheets/language-preference-modal.scss"
end
