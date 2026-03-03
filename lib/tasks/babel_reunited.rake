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

    auto_translate_languages = SiteSetting.babel_reunited_auto_translate_languages
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
    posts_with_translations = BabelReunited::PostTranslation.select(:post_id).distinct
    posts_without_translations =
      Post
        .where.not(id: posts_with_translations)
        .where("raw IS NOT NULL AND raw != ''")
        .where(deleted_at: nil)

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
          languages.each { |language| BabelReunited::PostTranslation.create_or_update_record(post.id, language) }
          BabelReunited.enqueue_translation_jobs(post, languages)
          processed += 1

          puts "Processed #{processed}/#{total_count} posts..." if processed % 100 == 0
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

    legacy_records =
      BabelReunited::PostTranslation.where(translated_raw: nil).where(status: "completed")

    total = legacy_records.count
    puts "Found #{total} legacy translation records without translated_raw"

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
          force_update: true,
        )
        queued += 1
        puts "Queued #{queued}/#{total}..." if queued % 100 == 0
      end

      puts ""
      puts "Queued: #{queued} re-translation jobs"
      puts "Skipped: #{skipped} (deleted/missing posts)"
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

      user.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = pref.language
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
