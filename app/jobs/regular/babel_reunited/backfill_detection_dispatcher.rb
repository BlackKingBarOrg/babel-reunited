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
    token = args[:lease_token]

    # Renewing first is also the check that this chain is still the one that
    # should be running: a chain whose lease expired has been replaced, and
    # two chains dispatching would double the rate this exists to hold.
    return unless BabelReunited.renew_backfill_lease(token)

    unless SiteSetting.babel_reunited_enabled &&
             BabelReunited::LanguageDetectionService.configuration_error.nil?
      # A missing provider makes every dispatch a certain failure that records
      # nothing. Give the lease back rather than re-arming forever.
      BabelReunited.release_backfill_lease(token)
      return
    end

    # Read from the setting every pass, not once at the start: an admin who
    # lowers the allowance mid-run means it now, and this chain may have been
    # started an hour ago.
    per_minute = args[:per_minute].to_i
    per_minute = 1 if per_minute < 1
    per_minute = [
      per_minute,
      SiteSetting.babel_reunited_rate_limit_per_minute
    ].min
    per_minute = 1 if per_minute < 1

    # nil means "everything"; a number is what LIMIT asked for and has to
    # survive the whole chain, or a cautious first pass turns into a full run.
    remaining = args[:remaining]
    per_minute = [per_minute, remaining.to_i].min if remaining

    dispatched = dispatch(per_minute)

    remaining = remaining.to_i - dispatched if remaining

    # Nothing left to hand out, or the requested share is spent. Either way
    # this chain is done and the lease belongs to whoever comes next.
    if dispatched.zero? || (remaining && remaining <= 0)
      BabelReunited.release_backfill_lease(token)
      return
    end

    Jobs.enqueue_in(
      INTERVAL,
      self.class,
      per_minute: args[:per_minute],
      remaining: remaining,
      lease_token: token
    )
  end

  private

  def dispatch(per_minute)
    dispatched = 0
    return dispatched if per_minute < 1

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
