# frozen_string_literal: true

module BabelReunited
  class PostTranslationSerializer < ApplicationSerializer
    attributes :id,
               :language,
               :translated_content,
               :translated_title,
               :source_language,
               :translation_provider,
               :created_at,
               :updated_at,
               :confidence,
               :status

    def translated_content
      # New path: pre-computed cooked content (already sanitized at write time)
      return object.translated_content if object.translated_raw.present?

      # Legacy path: old records without translated_raw
      legacy = object.translated_content
      return legacy if legacy.blank?
      Loofah.html5_fragment(legacy).scrub!(:prune).to_s
    end

    # Title is sanitized to plain text by model before_save; no extra escaping needed
    # (Loofah.text is idempotent, CGI.escapeHTML is not — avoid double-escape)

    def confidence
      object.translation_confidence
    end

    def source_language_detected?
      object.source_language_detected?
    end

    def has_translated_title?
      object.has_translated_title?
    end
  end
end
