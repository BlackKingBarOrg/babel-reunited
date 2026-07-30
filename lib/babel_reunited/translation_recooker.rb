# frozen_string_literal: true

module BabelReunited
  # Backfills translated_content for existing completed translations by
  # re-running the cooking pipeline over their stored translated_raw. No LLM
  # calls are made, but post-processing can hit the network (onebox fetches,
  # remote image probing), so DRY_RUN stays fully offline.
  #
  # Modes:
  # - dry_run (default): count and sample matching records only. No cooking,
  #   no network, no writes.
  # - validate: run the full cooking pipeline but never write. May access the
  #   network. Reports what would change.
  # - live (dry_run: false): cook and write, guarded by an optimistic
  #   concurrency check so a translation refreshed mid-run is never
  #   overwritten with stale output.
  #
  # Unlike the translation job, a post-processing failure here never degrades
  # content: the record already holds something usable, so it is kept as-is
  # and counted as failed.
  class TranslationRecooker
    Stats =
      Struct.new(
        :matched,
        :handled,
        :last_id,
        :processed,
        :unchanged,
        :skipped_deleted,
        :skipped_changed,
        :failed,
        keyword_init: true
      )

    def initialize(
      dry_run: true,
      validate: false,
      limit: nil,
      start_id: nil,
      batch_size: 500,
      post_id: nil,
      language: nil,
      logger: nil
    )
      @dry_run = dry_run
      @validate = validate
      @limit = limit
      @start_id = start_id
      @batch_size = batch_size
      @post_id = post_id
      @language = language
      @logger = logger || ->(msg) {}
    end

    def run
      stats =
        Stats.new(
          matched: effective_scope.count,
          handled: 0,
          last_id: nil,
          processed: 0,
          unchanged: 0,
          skipped_deleted: 0,
          skipped_changed: 0,
          failed: 0
        )

      if @dry_run
        report_dry_run(stats)
        return stats
      end

      effective_scope.find_each(batch_size: @batch_size) do |translation|
        stats.handled += 1
        stats.last_id = translation.id
        recook(translation, stats)
      end

      stats
    end

    private

    def scope
      scope = PostTranslation.recookable
      scope = scope.where(post_id: @post_id) if @post_id
      scope = scope.where(language: @language) if @language
      scope = scope.where(id: @start_id..) if @start_id
      scope
    end

    # Single source of truth for what a run touches: matched counts, dry-run
    # samples, and the live iteration must all see the same record set, or
    # canary runs with LIMIT report misleading numbers.
    def effective_scope
      @limit ? scope.limit(@limit) : scope
    end

    def report_dry_run(stats)
      log("DRY RUN: no cooking, no network access, no writes.")
      sample_size = [@limit, 10].compact.min
      effective_scope
        .order(:id)
        .limit(sample_size)
        .each do |t|
          post_state =
            Post.find_by(id: t.post_id) ? "post present" : "post missing"
          log(
            "  would recook translation #{t.id} (post #{t.post_id}, #{t.language}, #{post_state})"
          )
        end
      if stats.matched > sample_size
        log("  ... and #{stats.matched - sample_size} more")
      end
      log(
        "Matched #{stats.matched} records. Use DRY_RUN=false to recook, VALIDATE=true to cook without writing."
      )
    end

    def recook(translation, stats)
      post = Post.find_by(id: translation.post_id)
      if post.nil? || post.deleted_at.present?
        stats.skipped_deleted += 1
        return
      end

      # Captured before the (potentially slow, network-bound) cooking step;
      # compared again under lock before writing.
      captured_raw = translation.translated_raw
      captured_sha = translation.source_sha
      captured_updated_at = translation.updated_at

      result = TranslatedCooker.call(raw: captured_raw, post: post)

      unless result.post_processed?
        stats.failed += 1
        log(
          "  FAILED translation #{translation.id} (post #{translation.post_id}, " \
            "#{translation.language}): #{result.post_processing_error.message} — keeping existing content"
        )
        return
      end

      if @validate
        changed = result.html != translation.translated_content
        stats.processed += 1 if changed
        stats.unchanged += 1 unless changed
        return
      end

      write_if_unchanged(
        translation,
        result.html,
        captured_raw,
        captured_sha,
        captured_updated_at,
        stats
      )
    rescue => e
      stats.failed += 1
      log(
        "  FAILED translation #{translation.id} (post #{translation.post_id}, " \
          "#{translation.language}): #{e.class}: #{e.message}"
      )
    end

    def write_if_unchanged(
      translation,
      html,
      captured_raw,
      captured_sha,
      captured_updated_at,
      stats
    )
      PostTranslation.transaction do
        current = PostTranslation.lock.find_by(id: translation.id)

        if current.nil? || current.status != "completed" ||
             current.translated_raw != captured_raw ||
             current.source_sha != captured_sha ||
             current.updated_at != captured_updated_at
          stats.skipped_changed += 1
          next
        end

        if current.translated_content == html
          stats.unchanged += 1
          next
        end

        current.update!(translated_content: html)
        stats.processed += 1
      end
    end

    def log(message)
      @logger.call(message)
    end
  end
end
