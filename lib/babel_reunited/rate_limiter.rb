# frozen_string_literal: true

module BabelReunited
  class RateLimiter
    def self.perform_request_if_allowed
      rate_limit = SiteSetting.babel_reunited_rate_limit_per_minute
      return true if rate_limit <= 0

      current_minute = Time.current.to_i / 60
      key = "babel_reunited_rate_limit:#{current_minute}"

      new_count = Discourse.redis.incr(key)
      Discourse.redis.expire(key, 120) if new_count == 1

      if new_count > rate_limit
        Discourse.redis.decr(key)
        return false
      end

      true
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
