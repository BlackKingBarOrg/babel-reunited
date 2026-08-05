# frozen_string_literal: true

module BabelReunited
  class AdminController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    def index
      # Statistics will be calculated in the view
    end

    def stats
      render json: {
               total_translations: PostTranslation.count,
               unique_languages: PostTranslation.distinct.count(:language),
               language_distribution: PostTranslation.group(:language).count,
               status_distribution: PostTranslation.group(:status).count,
               today_usage: {
                 # Enqueue-level counter the daily fuses act on (manual +
                 # view-triggered requests, staff exempt)
                 accepted_ondemand_requests: UsageFuse.site_count,
                 # Provider-call-level counter, observability only: includes
                 # fan-out, detection, chunks, and titles
                 provider_calls_today: RateLimiter.todays_call_count,
                 site_daily_limit:
                   SiteSetting.babel_reunited_daily_translation_limit,
                 user_daily_limit:
                   SiteSetting.babel_reunited_user_daily_translation_limit,
                 view_triggered_enabled:
                   SiteSetting.babel_reunited_view_triggered_translation
               },
               recent_translations:
                 PostTranslation
                   .includes(:post)
                   .recent
                   .limit(10)
                   .map do |t|
                     {
                       id: t.id,
                       post_id: t.post_id,
                       language: t.language,
                       provider: t.translation_provider,
                       created_at: t.created_at
                     }
                   end
             }
    end
  end
end
