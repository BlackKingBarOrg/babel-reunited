# frozen_string_literal: true

# Rake tasks for Babel Reunited plugin
# These tasks are automatically loaded by Discourse when the plugin is activated
# See: lib/plugin/instance.rb line 839

namespace :babel_reunited do
  desc "Process posts without any translations and add translation jobs to Sidekiq"
  task process_missing_posts: :environment do |_, args|
    dry_run = ENV["DRY_RUN"] != "false"

    unless SiteSetting.babel_reunited_enabled
      puts "ERROR: Babel Reunited plugin is not enabled"
      puts "Please enable it in Site Settings first"
      exit 1
    end

    # The filtered accessor, not a raw split: unsupported codes in the
    # setting must not reach the model or the provider from here either.
    languages = BabelReunited.auto_translate_languages
    if languages.empty?
      puts "ERROR: No supported auto-translate languages configured"
      puts "Please set babel_reunited_auto_translate_languages in Site Settings"
      exit 1
    end
    puts "Auto-translate languages: #{languages.join(", ")}"
    puts ""

    # Find all posts that have no translations at all
    # Using subquery to find posts without any translation records
    posts_with_translations =
      BabelReunited::PostTranslation.select(:post_id).distinct
    posts_without_translations =
      Post
        .joins(:topic)
        .where.not(id: posts_with_translations)
        .where("posts.raw IS NOT NULL AND posts.raw != ''")
        .where(posts: { deleted_at: nil })

    enabled_categories = SiteSetting.babel_reunited_enabled_categories
    if enabled_categories.present?
      category_ids = enabled_categories.split("|").map(&:to_i)
      posts_without_translations =
        posts_without_translations.where(topics: { category_id: category_ids })
      puts "Filtering by enabled categories: #{category_ids.join(", ")}"
    else
      puts "No category restriction (all categories)"
    end
    puts ""

    total_count = posts_without_translations.count
    puts "Found #{total_count} posts without any translations"

    if total_count == 0
      puts "No posts need translation processing"
      next
    end

    if dry_run
      puts ""
      puts "DRY RUN mode - no jobs will be queued"
      puts "Use DRY_RUN=false to actually queue translation jobs"
      puts ""
      puts "Sample posts that would be processed:"
      posts_without_translations
        .limit(10)
        .find_each do |post|
          puts "  Post ID: #{post.id}, Topic ID: #{post.topic_id}, User: #{post.user&.username || "system"}"
        end
      puts "  ... and #{total_count - 10} more posts" if total_count > 10
      puts ""
      puts "Would queue #{total_count * languages.size} translation jobs (#{total_count} posts × #{languages.size} languages)"
    else
      processed = 0
      failed = 0

      puts "Processing posts and queueing translation jobs..."
      posts_without_translations.find_each do |post|
        begin
          languages.each do |language|
            BabelReunited::PostTranslation.create_or_update_record(
              post.id,
              language
            )
          end
          BabelReunited.enqueue_translation_jobs(post, languages)
          processed += 1

          if processed % 100 == 0
            puts "Processed #{processed}/#{total_count} posts..."
          end
        rescue => e
          puts "Error processing post #{post.id}: #{e.message}"
          failed += 1
        end
      end

      puts ""
      puts "=" * 50
      puts "Processing complete"
      puts "=" * 50
      puts "Processed: #{processed} posts"
      puts "Failed: #{failed} posts"
      puts "Queued: #{processed * languages.size} translation jobs"
      puts "=" * 50
    end
  end

  desc "Re-translate legacy records that have no translated_raw column populated"
  task retranslate_legacy: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    unless SiteSetting.babel_reunited_enabled
      puts "ERROR: Babel Reunited plugin is not enabled"
      exit 1
    end

    # Complementary to recook_translations: blank (including whitespace-only)
    # translated_raw cannot be recooked and needs a real re-translation.
    legacy_records = BabelReunited::PostTranslation.needs_retranslation

    total = legacy_records.count
    puts "Found #{total} legacy translation records without usable translated_raw"

    if total == 0
      puts "Nothing to do"
      next
    end

    if dry_run
      puts ""
      puts "DRY RUN mode - no jobs will be queued"
      puts "Use DRY_RUN=false to actually queue translation jobs"
      puts ""
      puts "Sample records:"
      legacy_records
        .limit(10)
        .each do |t|
          puts "  Translation ID: #{t.id}, Post ID: #{t.post_id}, Language: #{t.language}"
        end
      puts "  ... and #{total - 10} more" if total > 10
      puts ""
      puts "Would queue #{total} translation jobs"
    else
      queued = 0
      skipped = 0

      legacy_records.find_each do |t|
        post = Post.find_by(id: t.post_id)
        if post.nil? || post.deleted_at.present?
          skipped += 1
          next
        end

        Jobs.enqueue(
          Jobs::BabelReunited::TranslatePostJob,
          post_id: t.post_id,
          target_language: t.language,
          force_update: true
        )
        queued += 1
        puts "Queued #{queued}/#{total}..." if queued % 100 == 0
      end

      puts ""
      puts "Queued: #{queued} re-translation jobs"
      puts "Skipped: #{skipped} (deleted/missing posts)"
    end
  end

  desc "Scan completed translations whose structure drifted from the source (read-only)"
  task scan_translation_anomalies: :environment do
    unless SiteSetting.babel_reunited_enabled
      puts "ERROR: Babel Reunited plugin is not enabled"
      exit 1
    end

    limit = ENV["LIMIT"]&.to_i
    scanned = 0
    flagged = 0

    scope = BabelReunited::PostTranslation.recookable.order(:id)
    if ENV["TARGET_LANGUAGE"].present?
      scope = scope.where(language: ENV["TARGET_LANGUAGE"])
    end

    scope.find_each(batch_size: 200) do |t|
      break if limit && scanned >= limit
      post = Post.find_by(id: t.post_id)
      next if post.nil? || post.raw.blank?

      scanned += 1
      reasons =
        BabelReunited::TranslationStructure.drift(post.raw, t.translated_raw)
      next if reasons.empty?

      flagged += 1
      puts "translation #{t.id} post #{t.post_id} topic #{post.topic_id} " \
             "#{t.language}: #{reasons.join(", ")}"
    end

    puts ""
    puts "Scanned: #{scanned}, flagged: #{flagged}"
    if flagged > 0
      puts "Review flagged records, then re-translate (force_update) or delete them."
    end
  end

  desc "Recook completed translations from stored translated_raw (no LLM calls)"
  task recook_translations: :environment do
    unless SiteSetting.babel_reunited_enabled
      puts "ERROR: Babel Reunited plugin is not enabled"
      exit 1
    end

    dry_run = ENV["DRY_RUN"] != "false"
    validate = ENV["VALIDATE"] == "true"
    dry_run = false if validate

    if validate
      puts "VALIDATE mode: cooking runs (may access the network for oneboxes/images) but nothing is written"
    elsif !dry_run
      puts "LIVE mode: recooked translated_content will be written"
    end

    recooker =
      BabelReunited::TranslationRecooker.new(
        dry_run: dry_run,
        validate: validate,
        limit: ENV["LIMIT"]&.to_i,
        start_id: ENV["START_ID"]&.to_i,
        batch_size: (ENV["BATCH_SIZE"] || 500).to_i,
        post_id: ENV["POST_ID"]&.to_i,
        language: ENV["TARGET_LANGUAGE"],
        logger: ->(msg) { puts msg }
      )

    stats = recooker.run

    puts ""
    puts "Matched:          #{stats.matched}"
    unless dry_run
      puts "Handled:          #{stats.handled}"
      puts "#{validate ? "Would change:     " : "Processed:        "}#{stats.processed}"
      puts "Unchanged:        #{stats.unchanged}"
      puts "Skipped (deleted post): #{stats.skipped_deleted}"
      puts "Skipped (changed mid-run): #{stats.skipped_changed}"
      puts "Failed (content kept): #{stats.failed}"
      puts "Last handled ID:  #{stats.last_id || "-"} (use START_ID=#{stats.last_id.to_i + 1} to resume)"
    end
  end

  desc "Report language codes in existing data that are not in the supported list"
  task audit_language_codes: :environment do
    supported = BabelReunited::Locales::SUPPORTED

    translation_codes =
      BabelReunited::PostTranslation.distinct.pluck(:language) - supported
    puts "post_translations languages outside the supported list: " \
           "#{translation_codes.sort.join(", ").presence || "none"}"
    translation_codes.sort.each do |code|
      count = BabelReunited::PostTranslation.where(language: code).count
      puts "  #{code}: #{count} records"
    end

    pref_codes =
      UserCustomField
        .where(name: BabelReunited::PREFERRED_LANGUAGE_FIELD)
        .distinct
        .pluck(:value)
        .compact - supported
    legacy_pref_codes =
      BabelReunited::UserPreferredLanguage.distinct.pluck(:language).compact -
        supported
    all_pref_codes = (pref_codes + legacy_pref_codes).uniq.sort
    puts "user preference languages outside the supported list: " \
           "#{all_pref_codes.join(", ").presence || "none"}"
    puts ""
    puts "These codes can no longer be requested for translation. Extend " \
           "BabelReunited::Locales::SUPPORTED (and the client mirror) or " \
           "migrate the data."
  end

  desc "Detect the source language of posts that already have translations but no current detection (one micro call each; no translations are started)"
  task backfill_detected_locales: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    limit = ENV["LIMIT"]&.to_i
    batch_size = (ENV["BATCH_SIZE"] || 500).to_i

    unless SiteSetting.babel_reunited_enabled
      puts "ERROR: Babel Reunited plugin is not enabled"
      exit 1
    end

    if batch_size < 1
      puts "ERROR: BATCH_SIZE must be a positive integer"
      exit 1
    end

    if limit && limit < 1
      puts "ERROR: LIMIT must be a positive integer"
      exit 1
    end

    # Without a provider every job fails on the same missing setting and
    # records nothing, so the run would queue thousands of certain failures
    # and this task could never report zero. A dry run still works: seeing the
    # scale is useful before the key is in place.
    unless dry_run
      config_error = BabelReunited::LanguageDetectionService.configuration_error
      if config_error
        puts "ERROR: #{config_error}"
        puts "Detection cannot run, so every job would fail without recording " \
               "anything and this task would never reach zero."
        exit 1
      end
    end

    # cleanup_same_language_copies treats the detected locale as ground truth
    # and leaves every post without one alone. Detection only ever ran for
    # posts created, edited or translated since it shipped, so on a forum with
    # pre-existing translations that cleanup would be a near no-op until this
    # backfill has run. Detection only: no translations are started.
    #
    # The detection runs here, in this process, rather than being handed to
    # Sidekiq. Detection shares one per-minute allowance with live translation
    # traffic, so the work has to be paced; and anything that paces by queueing
    # -- scheduled jobs, or a dispatcher enqueueing a batch a minute -- only
    # promises "not before T". A Sidekiq outage during a run of this length
    # leaves the whole backlog runnable at once, and the burst dies against the
    # rate limiter three short retries later without recording anything.
    # In-process there is no queue to burst: one call, then a sleep.
    #
    # It costs a held terminal for the duration, and that is the trade. What it
    # buys is that interrupting the run is exact -- what is recorded stays
    # recorded, nothing is in flight -- and a re-run resumes from the database
    # with no cursor, lease or chain to reconcile.
    site_limit = SiteSetting.babel_reunited_rate_limit_per_minute
    per_minute = (ENV["PER_MINUTE"] || site_limit / 2).to_i
    per_minute = 1 if per_minute < 1
    # Pacing above the allowance is not pacing: the calls would arrive at a
    # rate the limiter refuses, and every refusal is a wait anyway.
    if per_minute > site_limit
      puts "PER_MINUTE #{per_minute} is above " \
             "babel_reunited_rate_limit_per_minute (#{site_limit}); " \
             "using #{site_limit}"
      per_minute = site_limit
    end

    # A relation rather than a plucked id list, so nothing is materialized
    # whole and BATCH_SIZE really does bound what is in memory.
    scope = BabelReunited.posts_needing_detection
    total = scope.count

    outstanding = 0
    already = 0
    unclassifiable = 0
    ineligible = 0
    undetectable = 0
    samples = []
    truncated = false

    # includes(:topic): the eligibility check reads the post's category
    # through its topic, which would be one query per post otherwise.
    scope
      .includes(:topic)
      .find_in_batches(batch_size: batch_size) do |posts|
        Post.preload_custom_fields(
          posts,
          [
            BabelReunited::DETECTED_LOCALE_FIELD,
            BabelReunited::DETECTED_SHA_FIELD
          ]
        )

        posts.each do |post|
          if limit && outstanding >= limit
            truncated = true
            break
          end

          # Answered against this content, one way or the other. The detector
          # reporting "no language I support" is an answer and stays one until
          # the post is edited; counting it as outstanding is what would keep
          # this task from ever reaching zero.
          if BabelReunited.detection_current?(post)
            if BabelReunited.detected_locale_for(post)
              already += 1
            else
              unclassifiable += 1
            end
            next
          end

          # Deleted, hidden and disabled-category posts are refused by the job
          # itself; counting them here keeps the reported total honest.
          unless BabelReunited.translatable_post?(post)
            ineligible += 1
            next
          end

          # A post with nothing but a code block or a link fails detection the
          # same way on every attempt. Counting it here is what lets this task
          # ever report itself finished.
          unless BabelReunited::LanguageDetectionService.new(
                   post: post
                 ).detectable?
            undetectable += 1
            next
          end

          if samples.size < 10
            samples << "  Post ID: #{post.id}, Topic ID: #{post.topic_id}"
          end

          outstanding += 1
        end

        break if truncated
      end

    puts "Posts with translations: #{total}"
    puts "  already detected against current content: #{already}"
    puts "  answered as no supported language: #{unclassifiable}"
    puts "  not eligible (deleted, hidden, disabled category): #{ineligible}"
    puts "  too short to ever detect: #{undetectable}"
    puts "  still needing detection: #{outstanding}"
    puts "  (stopped early at LIMIT, counts above are partial)" if truncated

    if outstanding == 0
      puts ""
      puts "Nothing left to detect."
      puts "cleanup_same_language_copies can run now." unless truncated
      next
    end

    minutes = (outstanding.to_f / per_minute).ceil

    if dry_run
      puts ""
      puts "DRY RUN mode - nothing was detected"
      puts "Use DRY_RUN=false to run it"
      puts ""
      puts "Would take ~#{minutes} minute(s) at #{per_minute}/minute"
      puts ""
      puts "Sample posts:"
      samples.each { |line| puts line }
      if outstanding > samples.size
        puts "  ... and #{outstanding - samples.size} more"
      end
      next
    end

    # Re-read before every wait rather than fixed at startup: an admin
    # lowering the allowance means it now, and this run may have started an
    # hour ago. Pacing on the value it had then would keep asking at the old
    # rate, and every ask the limiter refuses spends part of a post's retry
    # budget for nothing. PER_MINUTE stays the ceiling -- raising the site
    # limit mid-run does not speed the backfill past what was asked for.
    current_interval =
      lambda do
        allowed = [
          per_minute,
          SiteSetting.babel_reunited_rate_limit_per_minute.to_i
        ].min
        allowed = 1 if allowed < 1
        60.0 / allowed
      end

    puts ""
    puts "Detecting #{outstanding} post(s) at #{per_minute}/minute " \
           "(~#{minutes} minute(s)). Leave this process running."
    puts "Interrupting is safe: results are recorded as they land, and " \
           "re-running picks up whatever is left."
    puts "Run only one at a time. A second process cannot push past the site " \
           "rate limit, but it can detect the same post twice and pay twice."
    puts ""

    detected = 0
    unresolved = 0
    failed = 0
    superseded = 0
    interrupted = false
    stop = false
    disabled = false

    begin
      scope
        .includes(:topic)
        .find_in_batches(batch_size: batch_size) do |posts|
          # Not Post.preload_custom_fields: that installs a read-only proxy,
          # and this pass writes the field it is reading.
          BabelReunited.preload_detection_fields(posts)

          posts.each do |post|
            processed = detected + unresolved + failed + superseded
            if limit && processed >= limit
              stop = true
              break
            end

            # translatable_post? refuses everything once the switch is off, so
            # nothing would go out either way. Stopping on it explicitly is so
            # the operator sees why, instead of watching the run skip eighteen
            # hundred posts and claim it finished.
            unless SiteSetting.babel_reunited_enabled
              disabled = true
              stop = true
              break
            end

            next if BabelReunited.detection_current?(post)
            next unless BabelReunited.translatable_post?(post)

            service = BabelReunited::LanguageDetectionService.new(post: post)
            next unless service.detectable?

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            # Taken before the call, checked after it: this is a live forum,
            # and a post edited mid-call may already carry a newer detection
            # that the edit itself triggered. record_detected_locale is what
            # refuses to write this answer over that one.
            sampled_sha = BabelReunited.detection_raw_sha(post)
            # A taken slot ends this post's turn instead of starting a wait.
            # Holding it here meant sleeping a full pacing window and then
            # sending again -- and a second send re-opens every question the
            # first one answered: the sample was captured before the wait, so
            # an edit made during it went to the provider as the post's
            # current content, and the switch, the post and its category all
            # needed re-checking too. Re-running the task is what picks the
            # post up, on fresh content. That is the contract it already has.
            result =
              begin
                service.call
              rescue BabelReunited::RateLimitError
                BabelReunited::LanguageDetectionService::Result.new(
                  error: "Rate limited",
                  retryable: true
                )
              end

            if result.success? || result.undetermined?
              locale = result.locale || BabelReunited::UNDETERMINED_LOCALE
              if BabelReunited.record_detected_locale(post, locale, sampled_sha)
                result.success? ? detected += 1 : unresolved += 1
              else
                # The content moved under this answer, or another detection
                # recorded one for it first. Either way what is on record now
                # is at least as current as this, so there is nothing to do
                # and nothing to fix.
                superseded += 1
              end
            else
              # Nothing recorded, so the next run finds this post again. That
              # is the retry: there is no queue here to hold one.
              failed += 1
              ::BabelReunited::TranslationLogger.log_translation_skipped(
                post_id: post.id,
                target_language: "detect",
                reason: "backfill_detection_failed: #{result.error}"
              )
            end

            processed = detected + unresolved + failed + superseded
            if (processed % 25).zero?
              puts "  #{processed}/#{outstanding} " \
                     "(detected #{detected}, unresolved #{unresolved}, " \
                     "failed #{failed})"
            end

            interval = current_interval.call
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            sleep(interval - elapsed) if elapsed < interval
          end

          break if stop
        end
    rescue Interrupt
      interrupted = true
    end

    puts ""
    puts "Interrupted; stopping here." if interrupted
    if disabled
      puts "Plugin was disabled mid-run; stopped without sending more."
    end
    puts "Detected: #{detected}"
    puts "No supported language (recorded, will not be retried): #{unresolved}"
    puts "Failed, left for a re-run: #{failed}"
    puts "Superseded mid-detection, discarded: #{superseded}" if superseded > 0
    puts ""
    puts "Do NOT run cleanup_same_language_copies yet."
    puts "Re-run this task and wait until 'still needing detection' reaches 0."
  end

  desc "Remove translation records whose language matches the post's detected language (legacy source-to-source copies)"
  task cleanup_same_language_copies: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    # Only provably redundant records are touched: the post's detected locale
    # is the ground truth, and the original view already covers that language.
    # Posts without a detected locale are left alone.
    batch_size = (ENV["BATCH_SIZE"] || 500).to_i

    candidates =
      BabelReunited::PostTranslation.joins(
        "INNER JOIN post_custom_fields pcf " \
          "ON pcf.post_id = post_translations.post_id " \
          "AND pcf.name = '#{BabelReunited::DETECTED_LOCALE_FIELD}'"
      ).where("post_translations.language = pcf.value")

    total = 0
    skipped = 0
    deleted = 0
    samples = []

    # Fully streaming: legacy data can hold one same-language copy per post,
    # so nothing accumulates across batches. Each batch preloads both
    # detection custom fields once (detection_current? would otherwise query
    # them per record) and, outside dry runs, deletes before moving on, which
    # also keeps the verify-to-delete window inside a single batch.
    candidates.in_batches(of: batch_size) do |batch|
      records = batch.includes(:post).to_a
      posts = records.filter_map(&:post).uniq(&:id)
      Post.preload_custom_fields(
        posts,
        [
          BabelReunited::DETECTED_LOCALE_FIELD,
          BabelReunited::DETECTED_SHA_FIELD
        ]
      )

      # A detection bound to older content proves nothing: the post may have
      # been rewritten in another language, which makes this record the
      # translation that is now needed rather than a redundant copy.
      redundant =
        records.select do |t|
          t.post && BabelReunited.detection_current?(t.post)
        end

      skipped += records.size - redundant.size
      total += redundant.size

      redundant
        .first(10 - samples.size)
        .each do |t|
          samples << "  Translation ID: #{t.id}, Post ID: #{t.post_id}, Language: #{t.language}"
        end

      unless dry_run
        deleted +=
          BabelReunited::PostTranslation.where(
            id: redundant.map(&:id)
          ).delete_all
      end
    end

    puts "Found #{total} same-language translation records"
    if skipped > 0
      puts "Skipped #{skipped} records whose post changed after detection"
    end

    if total == 0
      puts "Nothing to do"
      next
    end

    if dry_run
      puts ""
      puts "DRY RUN mode - nothing will be deleted"
      puts "Use DRY_RUN=false to actually delete these records"
      puts ""
      puts "Sample records:"
      samples.each { |line| puts line }
      puts "  ... and #{total - 10} more" if total > 10
    else
      puts "Deleted: #{deleted} records"
    end
  end

  desc "Migrate user language preferences from legacy table to custom fields"
  task migrate_user_preferences: :environment do
    migrated = 0
    skipped = 0

    BabelReunited::UserPreferredLanguage.find_each do |pref|
      user = User.find_by(id: pref.user_id)
      unless user
        skipped += 1
        next
      end

      user.custom_fields[
        BabelReunited::PREFERRED_LANGUAGE_FIELD
      ] = pref.language
      user.custom_fields[BabelReunited::PREFERRED_ENABLED_FIELD] = pref.enabled
      user.save_custom_fields
      migrated += 1
      puts "Migrated #{migrated}..." if migrated % 100 == 0
    end

    puts ""
    puts "Migrated: #{migrated} user preferences"
    puts "Skipped: #{skipped} (missing users)"
  end
end
