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

    auto_translate_languages =
      SiteSetting.babel_reunited_auto_translate_languages
    if auto_translate_languages.blank?
      puts "ERROR: No auto-translate languages configured"
      puts "Please set babel_reunited_auto_translate_languages in Site Settings"
      exit 1
    end

    languages = auto_translate_languages.split(",").map(&:strip)
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

  desc "Remove translation records whose language matches the post's detected language (legacy source-to-source copies)"
  task cleanup_same_language_copies: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    # Only provably redundant records are touched: the post's detected locale
    # is the ground truth, and the original view already covers that language.
    # Posts without a detected locale are left alone.
    candidates =
      BabelReunited::PostTranslation
        .joins(
          "INNER JOIN post_custom_fields pcf " \
            "ON pcf.post_id = post_translations.post_id " \
            "AND pcf.name = '#{BabelReunited::DETECTED_LOCALE_FIELD}'"
        )
        .where("post_translations.language = pcf.value")
        .includes(:post)

    # A detection bound to older content proves nothing: the post may have
    # been rewritten in another language, which makes this record the
    # translation that is now needed rather than a redundant copy.
    records, skipped =
      candidates.partition { |t| BabelReunited.detection_current?(t.post) }

    total = records.size
    puts "Found #{total} same-language translation records"
    if skipped.any?
      puts "Skipped #{skipped.size} records whose post changed after detection"
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
      records
        .first(10)
        .each do |t|
          puts "  Translation ID: #{t.id}, Post ID: #{t.post_id}, Language: #{t.language}"
        end
      puts "  ... and #{total - 10} more" if total > 10
    else
      deleted =
        BabelReunited::PostTranslation.where(id: records.map(&:id)).delete_all
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
