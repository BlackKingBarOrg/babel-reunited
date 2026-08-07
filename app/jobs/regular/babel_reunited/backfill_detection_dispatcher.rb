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
# A chain carries only where it stopped, never a list of what is left: each
# pass asks the database, so a dispatcher that dies is replaced by starting
# another one, and the rake task's re-run sweeps up whatever a chain skipped.
class Jobs::BabelReunited::BackfillDetectionDispatcher < ::Jobs::Base
  sidekiq_options retry: 3

  INTERVAL = 60

  def execute(args)
    token = args[:lease_token]

    # Taking the lease first is also the check that this chain should still be
    # running. It reclaims an unheld lease rather than giving up on one: an
    # outage longer than the TTL expires the lease while this pass is still
    # queued, and quitting there would lose the backfill instead of delaying
    # it. Only a lease somebody else holds ends this chain.
    return unless BabelReunited.hold_backfill_lease(token)

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

    # Each pass resumes where the last one stopped. Restarting the scan every
    # minute would re-read every post already dealt with, which is quadratic
    # over a backfill this long. Anything skipped stays skipped for this
    # chain; the rake task's re-run is what sweeps up stragglers.
    after_id = args[:after_id].to_i
    dispatched, last_id = dispatch(per_minute, after_id)

    remaining = remaining.to_i - dispatched if remaining

    # Fewer than the share means the scan reached the end: nothing is left for
    # this chain to find, so it stops and hands the lease back.
    if dispatched < per_minute
      BabelReunited.release_backfill_lease(token)
      return
    end

    if remaining && remaining <= 0
      # The share is spent, but the detections just handed out have not run.
      # Releasing now would let a second LIMIT run dispatch another batch into
      # this same minute, which is exactly the burst being paced against.
      BabelReunited.expire_backfill_lease(token, INTERVAL)
      return
    end

    Jobs.enqueue_in(
      INTERVAL,
      self.class,
      per_minute: args[:per_minute],
      remaining: remaining,
      after_id: last_id,
      lease_token: token
    )
  end

  private

  # Returns how many were handed out and the last post id examined, which is
  # where the next pass picks up.
  def dispatch(per_minute, after_id)
    dispatched = 0
    last_id = after_id
    return dispatched, last_id if per_minute < 1

    BabelReunited
      .posts_needing_detection
      .where("posts.id > ?", after_id)
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
          return dispatched, last_id if dispatched >= per_minute
          last_id = post.id

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

    [dispatched, last_id]
  end
end
