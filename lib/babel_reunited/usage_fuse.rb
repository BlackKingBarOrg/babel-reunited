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

    # Reserves one translation against both daily fuses. Returns nil when the
    # request is admitted, or the name of the fuse that rejected it.
    #
    # Counting and checking are one step on purpose. Reading the counter and
    # incrementing it separately lets every concurrent request see the same
    # under-limit value and pass together, so the fuse leaks precisely when it
    # is under load — the case it exists for. INCR returns the value after
    # incrementing, so the caller that pushes the counter past the limit is
    # the one rejected, and no two callers can be handed the same slot.
    #
    # The user fuse is charged first: someone already over their own limit
    # must not spend site quota to find that out. A rejected request leaves
    # its increment behind, which only makes a tripped fuse slightly stickier
    # until the key expires — the safe direction for a circuit breaker.
    def self.admit(user)
      if user.present?
        limit = SiteSetting.babel_reunited_user_daily_translation_limit
        return "user_daily_limit" unless claim(user_key(user), limit)
      end

      limit = SiteSetting.babel_reunited_daily_translation_limit
      return "site_daily_limit" unless claim(site_key, limit)

      nil
    end

    def self.claim(key, limit)
      return true if limit.to_i <= 0

      count = Discourse.redis.incr(key)
      Discourse.redis.expire(key, TTL) if count == 1
      return true if count <= limit

      Rails.logger.warn(
        "BabelReunited: daily translation fuse tripped (#{key} #{count}/#{limit})"
      )
      false
    end
  end
end
