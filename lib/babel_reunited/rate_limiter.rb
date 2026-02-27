# frozen_string_literal: true

module BabelReunited
  class RateLimiter
    def self.can_make_request?
      rate_limit = SiteSetting.babel_reunited_rate_limit_per_minute
      return true if rate_limit <= 0

      current_minute = Time.current.to_i / 60
      key = "babel_reunited_rate_limit:#{current_minute}"

      current_count = Discourse.redis.get(key).to_i
      current_count < rate_limit
    end

    def self.record_request
      rate_limit = SiteSetting.babel_reunited_rate_limit_per_minute
      return if rate_limit <= 0

      current_minute = Time.current.to_i / 60
      key = "babel_reunited_rate_limit:#{current_minute}"

      Discourse.redis.multi do |multi|
        multi.incr(key)
        multi.expire(key, 120) # Expire after 2 minutes to handle edge cases
      end
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
