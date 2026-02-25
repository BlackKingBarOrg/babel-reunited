# frozen_string_literal: true

module BabelReunited
  class PostTranslation < ActiveRecord::Base
    self.table_name = "post_translations"

    belongs_to :post

    before_save :sanitize_translation_fields

    validates :language, presence: true, length: { maximum: 10 }
    validates :translated_content, presence: true, unless: :translating?
    validates :translated_title, length: { maximum: 255 }, allow_blank: true
    validates :post_id, uniqueness: { scope: :language }
    validates :language,
              format: {
                with: /\A[a-z]{2}(-[a-z]{2})?\z/,
                message: "must be a valid language code",
              }

    scope :by_language, ->(lang) { where(language: lang) }
    scope :recent, -> { order(created_at: :desc) }

    def self.find_translation(post_id, language)
      find_by(post_id: post_id, language: language)
    end

    def self.translate_post(post, target_language)
      find_translation(post.id, target_language)
    end

    def source_language_detected?
      source_language.present?
    end

    def translating?
      status == "translating"
    end

    def completed?
      status == "completed"
    end

    def failed?
      status == "failed"
    end

    def provider_info
      metadata["provider_info"] || {}
    end

    def translation_confidence
      metadata["confidence"] || 0.0
    end

    # 新增方法
    def has_translated_title?
      translated_title.present?
    end

    def translated_title_or_original
      translated_title.presence || post.topic.title
    end

    # 获取topic的翻译标题（通过第一个post的翻译）
    def self.find_topic_translation(topic_id, language)
      first_post = Post.where(topic_id: topic_id, post_number: 1).first
      return nil unless first_post

      translation = find_translation(first_post.id, language)
      translation&.translated_title
    end

    # 获取topic的完整翻译信息
    def self.find_topic_translation_info(topic_id, language)
      first_post = Post.where(topic_id: topic_id, post_number: 1).first
      return nil unless first_post

      find_translation(first_post.id, language)
    end

    private

    # Central sanitization — runs on every save regardless of write path
    def sanitize_translation_fields
      if translated_content.present?
        self.translated_content = Loofah.html5_fragment(translated_content).scrub!(:prune).to_s
      end

      # Titles must be plain text; Loofah.text strips all tags and is idempotent
      if translated_title.present?
        self.translated_title = Loofah.html5_fragment(translated_title).text
      end
    end
  end
end
