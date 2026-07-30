# frozen_string_literal: true

module BabelReunited
  # Daily circuit breakers for translation enqueues. These are abuse/incident
  # fuses, not spend budgets: defaults sit far above organic traffic so
  # legitimate readers never hit them, and they only bite during an attack or
  # a client bug. Both request lanes (manual and view-triggered) count; staff
  # are exempt at the call sites.
  module UsageFuse
    KEY_PREFIX = "babel_daily"
    TTL = 2.days

    def self.site_key(date = Time.zone.now)
      "#{KEY_PREFIX}:#{date.strftime("%Y%m%d")}"
    end

    def self.user_key(user, date = Time.zone.now)
      "#{site_key(date)}:u#{user.id}"
    end

    def self.site_count
      Discourse.redis.get(site_key).to_i
    end

    def self.user_count(user)
      return 0 if user.blank?
      Discourse.redis.get(user_key(user)).to_i
    end

    def self.site_exhausted?
      limit = SiteSetting.babel_reunited_daily_translation_limit
      return false if limit <= 0

      count = site_count
      return false if count < limit

      Rails.logger.warn(
        "BabelReunited: site daily translation fuse tripped (#{count}/#{limit})"
      )
      true
    end

    def self.user_exhausted?(user)
      limit = SiteSetting.babel_reunited_user_daily_translation_limit
      return false if limit <= 0 || user.blank?

      user_count(user) >= limit
    end

    def self.record!(user)
      count = Discourse.redis.incr(site_key)
      Discourse.redis.expire(site_key, TTL) if count == 1

      return if user.blank?

      user_counter = Discourse.redis.incr(user_key(user))
      Discourse.redis.expire(user_key(user), TTL) if user_counter == 1
    end
  end
end
