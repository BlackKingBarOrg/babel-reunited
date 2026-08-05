# frozen_string_literal: true

# == Schema Information
#
# Table name: post_translations
#
#  id                   :bigint           not null, primary key
#  language             :string(10)       not null
#  metadata             :json
#  source_language      :string(10)
#  source_sha           :string(64)
#  status               :string           default("completed"), not null
#  translated_content   :text             not null
#  translated_raw       :text
#  translated_title     :text
#  translation_provider :string(50)
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  post_id              :bigint           not null
#
# Indexes
#
#  index_post_translations_on_created_at            (created_at)
#  index_post_translations_on_language              (language)
#  index_post_translations_on_post_id               (post_id)
#  index_post_translations_on_post_id_and_language  (post_id,language) UNIQUE
#  index_post_translations_on_status                (status)
#  index_post_translations_on_translated_title      (translated_title)
#
# Foreign Keys
#
#  fk_rails_...  (post_id => posts.id)
#
module BabelReunited
  class PostTranslation < ActiveRecord::Base
    self.table_name = "post_translations"

    belongs_to :post

    before_save :sanitize_translation_fields

    validates :language, presence: true, length: { maximum: 10 }
    validates :translated_content, presence: true, if: :completed?
    validates :translated_title, length: { maximum: 255 }, allow_blank: true
    validates :post_id, uniqueness: { scope: :language }
    validates :language,
              format: {
                with: BabelReunited::Locales::LANGUAGE_CODE_FORMAT,
                message: "must be a valid language code"
              }
    # On create only: rows that predate a shrink of the supported set must
    # stay updatable (recook, heal, stale-marking all go through update!).
    validates :language,
              inclusion: {
                in: BabelReunited::Locales::SUPPORTED,
                message: "is not a supported language"
              },
              on: :create

    scope :by_language, ->(lang) { where(language: lang) }
    scope :recent, -> { order(created_at: :desc) }

    # These two scopes must stay complementary: every completed record belongs
    # to exactly one of them, so no record can fall between the retranslation
    # and recook maintenance tasks. Blank means no non-whitespace character at
    # all — PostgreSQL's BTRIM would only strip plain spaces, letting a
    # "\n\t"-only raw slip into recookable where it can never cook to valid
    # content, hence the [[:space:]] regex.
    scope :needs_retranslation,
          -> do
            where(status: "completed").where(
              "translated_raw IS NULL OR translated_raw !~ '[^[:space:]]'"
            )
          end
    scope :recookable,
          -> do
            where(status: "completed").where("translated_raw ~ '[^[:space:]]'")
          end

    def self.find_translation(post_id, language)
      find_by(post_id: post_id, language: language)
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

    # Completed content whose source post changed after translation; still
    # displayable, but eligible for re-translation on next view.
    def stale?
      status == "stale"
    end

    # Whether this body may be shown to a reader.
    #
    # Only a translation of the post's current content qualifies. Every other
    # status — stale, failed, or a stale row re-claimed into translating —
    # carries a body produced from text the author has since changed, and the
    # change that matters is a redaction: an API key, a phone number, a name
    # pasted by mistake. In a long post that is a handful of characters, so no
    # length or ratio test can see it. Only "the content this was translated
    # from is still the content" can, and status is exactly that record: an
    # edit moves every completed translation off completed (see
    # BabelReunited.trigger_retranslation), and a translation that finished
    # against content which moved under it is saved as stale, never completed.
    #
    # The cost is that an edit hides a translation until it is redone. The
    # pre-translate layer redoes it at once; the lazy layer redoes it on next
    # view. Showing the original in the meantime is the safe direction.
    def safe_to_display?
      completed?
    end

    # A claim older than this is treated as abandoned: the worker died, the
    # enqueue failed, or the job was dropped. Twice the worst case a job can
    # legitimately run, so a translation still calling the provider is never
    # stolen — being slow to recover a stuck record is much cheaper than
    # paying a provider twice for the same work. updated_at is the claim
    # clock: every transition into "translating" refreshes it.
    def self.translation_lease
      BabelReunited.max_translation_runtime * 2
    end

    def translation_lease_expired?
      translating? && updated_at <= self.class.translation_lease.ago
    end

    def failed?
      status == "failed"
    end

    AUTO_RETRY_COOLDOWN = 30.minutes
    MAX_AUTO_RETRIES = 5

    FAILURE_METADATA_KEYS = %w[
      error
      error_class
      error_kind
      failure_count
      failed_at
    ].freeze

    # Auto-retry eligibility tracks consecutive failures against one body of
    # content, so anything that replaces the content clears the verdict.
    # Without this a post that failed permanently ("content too long") and was
    # then shortened can never be translated again: auto_retryable? stays
    # false and every view trigger noops on failed_not_retryable.
    def clear_failure_metadata!
      update!(metadata: (metadata || {}).except(*FAILURE_METADATA_KEYS))
    end

    # Whether an automated (view-triggered) request may re-enqueue this failed
    # translation. Manual retries are always allowed and bypass this check.
    def auto_retryable?
      return false unless failed?

      meta = metadata || {}
      return false if meta["error_kind"] == "permanent"
      return false if meta["failure_count"].to_i >= MAX_AUTO_RETRIES

      failed_at = meta["failed_at"]
      return true if failed_at.blank?

      parsed = Time.zone.parse(failed_at.to_s)
      parsed.nil? || parsed <= AUTO_RETRY_COOLDOWN.ago
    rescue ArgumentError
      true
    end

    def provider_info
      (metadata || {})["provider_info"] || {}
    end

    def translation_confidence
      (metadata || {})["confidence"] || 0.0
    end

    # Atomic in-flight claims for the automated view lane: only one caller can
    # move a record into "translating" (or create it), so concurrent viewers
    # cannot stack duplicate jobs and fuse counts while a translation runs.
    # Compare-and-swap on the exact row the caller read: matching the status
    # alone is not enough when re-claiming an expired lease, because the row
    # is already "translating" and every concurrent caller would win. Pinning
    # updated_at as well means the first claim moves the clock and the rest
    # match nothing — and any other transition that landed in between (the
    # job completing, say) also invalidates the claim.
    def self.claim_existing(record)
      where(
        id: record.id,
        status: record.status,
        updated_at: record.updated_at
      ).update_all(status: "translating", updated_at: Time.current) == 1
    end

    def self.claim_new(post_id, target_language)
      create!(
        post_id: post_id,
        language: target_language,
        status: "translating",
        translated_content: "",
        translated_title: "",
        translation_provider:
          BabelReunited::ModelConfig.get_config&.dig(:provider) || "unknown",
        metadata: {
          translating_started_at: Time.current
        }
      ).present?
    rescue ActiveRecord::RecordNotUnique
      false
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:post_id, :taken)
      false
    end

    # The state a claim replaced, so release_claim can put it back exactly.
    def self.claim_snapshot(record)
      return nil if record.nil?

      { status: record.status, updated_at: record.updated_at }
    end

    # Undoes a claim that never became work — the enqueue raised, or a guard
    # after the claim rejected the request. Without it the record sits in
    # "translating" until its lease expires (an hour on defaults, six at the
    # maximum configured provider timeout) while every later view noops on it.
    #
    # updated_at is restored, not refreshed: this row may be an expired lease
    # that was re-claimed, and stamping the clock forward would lock it for
    # another full lease — the exact state the rollback exists to undo.
    #
    # A nil snapshot means the claim created the row, so there is nothing to
    # revert to and the placeholder goes away entirely.
    def self.release_claim(post_id, target_language, snapshot)
      record = find_translation(post_id, target_language)
      return if record.nil? || !record.translating?

      if snapshot.nil?
        record.destroy
      else
        record.update_columns(
          status: snapshot[:status],
          updated_at: snapshot[:updated_at]
        )
      end
    end

    def self.create_or_update_record(post_id, target_language)
      record =
        find_or_initialize_by(post_id: post_id, language: target_language)
      attrs = {
        status: "translating",
        translation_provider:
          record.translation_provider.presence ||
            BabelReunited::ModelConfig.get_config&.dig(:provider) || "unknown",
        metadata:
          (record.metadata || {}).merge(translating_started_at: Time.current)
      }
      if record.new_record?
        attrs[:translated_content] = ""
        attrs[:translated_title] = ""
      end
      record.assign_attributes(attrs)
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      record = find_translation(post_id, target_language)
      record.update!(
        status: "translating",
        metadata:
          (record.metadata || {}).merge(translating_started_at: Time.current)
      )
      record
    end

    def has_translated_title?
      translated_title.present?
    end

    def translated_title_or_original
      translated_title.presence || post.topic.title
    end

    private

    # Central sanitization — runs on every save regardless of write path
    def sanitize_translation_fields
      if translated_content.present?
        self.translated_content =
          Loofah.html5_fragment(translated_content).scrub!(:prune).to_s
      end

      # Titles must be plain text; Loofah.text strips all tags and is idempotent
      if translated_title.present?
        self.translated_title = Loofah.html5_fragment(translated_title).text
      end
    end
  end
end
