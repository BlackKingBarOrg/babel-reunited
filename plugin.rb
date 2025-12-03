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

  # Add translation methods to PostSerializer
  add_to_serializer(:post, :available_translations, include_condition: -> { true }) do
    object.available_translations
  end

  add_to_serializer(:post, :post_translations, include_condition: -> { true }) do
    object
      .post_translations
      .recent
      .limit(5)
      .map do |translation|
        BabelReunited::PostTranslationSerializer.new(translation).as_json
      end
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

  # Add translated title to Topic serializers
  add_to_serializer(:topic_view, :translated_title, include_condition: -> { 
    SiteSetting.babel_reunited_enabled && 
    scope&.user&.user_preferred_language&.enabled != false &&
    scope&.user&.user_preferred_language&.language.present?
  }) do
    return nil unless scope&.user
    user_preferred_language = scope.user.user_preferred_language
    return nil unless user_preferred_language&.enabled && user_preferred_language.language.present?
    
    # Get the first post's translation for the topic title
    first_post = object.topic.first_post
    return nil unless first_post
    
    translation = BabelReunited::PostTranslation.find_translation(
      first_post.id, 
      user_preferred_language.language
    )
    
    # Only return translated title if it exists and is completed
    if translation&.completed? && translation.translated_title.present?
      translation.translated_title
    else
      nil
    end
  end

  # Also add to listable topics for topic lists
  add_to_serializer(:listable_topic, :translated_title, include_condition: -> { 
    SiteSetting.babel_reunited_enabled && 
    scope&.user&.user_preferred_language&.enabled != false &&
    scope&.user&.user_preferred_language&.language.present?
  }) do
    return nil unless scope&.user
    user_preferred_language = scope.user.user_preferred_language
    return nil unless user_preferred_language&.enabled && user_preferred_language.language.present?
    
    first_post = object.first_post
    return nil unless first_post
    
    translation = BabelReunited::PostTranslation.find_translation(
      first_post.id, 
      user_preferred_language.language
    )
    
    # Only return translated title if it exists and is completed
    if translation&.completed? && translation.translated_title.present?
      translation.translated_title
    else
      nil
    end
  end

  # Add to topic list item serializer for topic lists
  add_to_serializer(:topic_list_item, :translated_title, include_condition: -> { 
    SiteSetting.babel_reunited_enabled && 
    scope&.user&.user_preferred_language&.enabled != false &&
    scope&.user&.user_preferred_language&.language.present?
  }) do
    return nil unless scope&.user
    user_preferred_language = scope.user.user_preferred_language
    return nil unless user_preferred_language&.enabled && user_preferred_language.language.present?
    
    first_post = object.first_post
    return nil unless first_post
    
    translation = BabelReunited::PostTranslation.find_translation(
      first_post.id, 
      user_preferred_language.language
    )
    
    # Only return translated title if it exists and is completed
    if translation&.completed? && translation.translated_title.present?
      translation.translated_title
    else
      nil
    end
  end

  # Event handlers for automatic translation
  on(:post_created) do |post|
    next unless SiteSetting.babel_reunited_enabled
    next if post.raw.blank?

    auto_translate_languages = SiteSetting.babel_reunited_auto_translate_languages
    if auto_translate_languages.present?
      languages = auto_translate_languages.split(",").map(&:strip)
      
      # Pre-create translation records to show "translating" status immediately
      languages.each do |language|
        post.create_or_update_translation_record(language)
      end
      
      post.enqueue_translation_jobs(languages)
    end
  end

  on(:post_edited) do |post|
    next unless SiteSetting.babel_reunited_enabled
    next if post.raw.blank?

    # Re-translate existing translations when post is edited
    existing_languages = post.available_translations
    if existing_languages.any?
      # Pre-update translation records to show "translating" status immediately
      existing_languages.each do |language|
        post.create_or_update_translation_record(language)
      end
      
      post.enqueue_translation_jobs(existing_languages, force_update: true)
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
