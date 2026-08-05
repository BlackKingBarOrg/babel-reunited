# frozen_string_literal: true

module BabelReunited
  class RateLimitError < StandardError
  end

  # A detection attempt that another try could resolve. Raised so sidekiq
  # retries instead of fanning out on an unknown source language.
  class DetectionError < StandardError
  end

  class RateLimiter
    DAILY_CALLS_TTL = 2.days

    def self.perform_request_if_allowed
      rate_limit = SiteSetting.babel_reunited_rate_limit_per_minute

      if rate_limit > 0
        current_minute = Time.current.to_i / 60
        key = "babel_reunited_rate_limit:#{current_minute}"

        new_count = Discourse.redis.incr(key)
        Discourse.redis.expire(key, 120) if new_count == 1

        if new_count > rate_limit
          Discourse.redis.decr(key)
          return false
        end
      end

      record_daily_call
      true
    end

    # Observability only: counts every allowed provider call (translation
    # chunks, titles, detections) so admins can see the real call volume next
    # to the enqueue-level fuses. Never used for enforcement.
    def self.record_daily_call
      key = daily_calls_key
      count = Discourse.redis.incr(key)
      Discourse.redis.expire(key, DAILY_CALLS_TTL) if count == 1
    end

    def self.daily_calls_key(date = Time.zone.now)
      "babel_llm_calls:#{date.strftime("%Y%m%d")}"
    end

    def self.todays_call_count
      Discourse.redis.get(daily_calls_key).to_i
    end

    def self.remaining_requests
      rate_limit = SiteSetting.babel_reunited_rate_limit_per_minute
      return Float::INFINITY if rate_limit <= 0

      current_minute = Time.current.to_i / 60
      key = "babel_reunited_rate_limit:#{current_minute}"

      current_count = Discourse.redis.get(key).to_i
      [rate_limit - current_count, 0].max
    end
  end
end
