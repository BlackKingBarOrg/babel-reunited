# frozen_string_literal: true

# Paces the detection backfill by dispatching, not by scheduling.
#
# Spreading the jobs themselves with enqueue_in only promises "not before T".
# If Sidekiq is stopped during the run -- a container restart on deploy day,
# which is exactly when this is used -- every overdue job becomes runnable at
# once on recovery, they all hit the per-minute allowance, burn their three
# short retries and die without recording anything.
#
# So the pace is enforced where it has to hold: at execution. This wakes once
# a minute, hands out at most PER_MINUTE jobs, and schedules its own next run
# relative to when it actually ran. Downtime delays the backfill; it cannot
# compress it.
#
# There is no cursor and no list to resume: each pass asks which posts still
# need detection, so a dispatcher that dies mid-run is replaced simply by
# starting another one.
class Jobs::BabelReunited::BackfillDetectionDispatcher < ::Jobs::Base
  sidekiq_options retry: 3

  INTERVAL = 60

  def execute(args)
    return unless SiteSetting.babel_reunited_enabled
    # A missing provider makes every dispatch a certain failure that records
    # nothing, and this would keep re-arming itself forever.
    return if BabelReunited::LanguageDetectionService.configuration_error

    per_minute = args[:per_minute].to_i
    per_minute = 1 if per_minute < 1

    dispatched = dispatch(per_minute)

    # Nothing left means nothing to come back for. The rake task is what
    # starts a new dispatcher once there is.
    return if dispatched.zero?

    Jobs.enqueue_in(
      INTERVAL,
      self.class,
      per_minute: per_minute,
      dispatcher_id: args[:dispatcher_id]
    )
  end

  private

  def dispatch(per_minute)
    dispatched = 0

    BabelReunited
      .posts_needing_detection
      .includes(:topic)
      .find_in_batches(batch_size: [per_minute * 4, 200].min) do |posts|
        Post.preload_custom_fields(
          posts,
          [
            BabelReunited::DETECTED_LOCALE_FIELD,
            BabelReunited::DETECTED_SHA_FIELD
          ]
        )

        posts.each do |post|
          return dispatched if dispatched >= per_minute
          next if BabelReunited.detection_current?(post)
          next unless BabelReunited.translatable_post?(post)
          unless BabelReunited::LanguageDetectionService.new(
                   post: post
                 ).detectable?
            next
          end

          # Claims and enqueues; a post another pass already handed out is
          # skipped without consuming this pass's share.
          dispatched += 1 if BabelReunited.enqueue_detection_backfill(post)
        end
      end

    dispatched
  end
end
