# frozen_string_literal: true

module BabelReunited
  module PostExtension
    extend ActiveSupport::Concern

    def translate_to_language(target_language, force_update: false)
      BabelReunited::TranslationService.new(
        post: self,
        target_language: target_language,
        force_update: force_update,
      ).call
    end

    def get_translation(language)
      post_translations.find_by(language: language)
    end

    def has_translation?(language)
      post_translations.exists?(language: language)
    end

    def available_translations
      post_translations.pluck(:language)
    end

    def enqueue_translation_jobs(target_languages, force_update: false)
      return if target_languages.blank?

      target_languages.each do |language|
        # Always enqueue translation job - no skipping based on existing translations
        Jobs.enqueue(
          Jobs::BabelReunited::TranslatePostJob,
          post_id: id,
          target_language: language,
          force_update: force_update,
        )
      end
    end

    def create_or_update_translation_record(target_language)
      record =
        BabelReunited::PostTranslation.find_or_initialize_by(post_id: id, language: target_language)

      record.assign_attributes(
        status: "translating",
        translated_content: "",
        translated_title: "",
        translation_provider: record.translation_provider.presence || "openai",
        metadata: (record.metadata || {}).merge(translating_started_at: Time.current),
      )
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      record = BabelReunited::PostTranslation.find_translation(id, target_language)
      record.update!(
        status: "translating",
        translated_content: "",
        translated_title: "",
        metadata: record.metadata.merge(translating_started_at: Time.current),
      )
      record
    end
  end
end
