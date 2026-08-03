# frozen_string_literal: true

module BabelReunited
  module LayoutPreloaderExtension
    # banner_json_cache is process-wide and keyed only by interface locale,
    # because that is the single axis core's own banner localization varies
    # on. This plugin varies the banner by the reader's preferred language,
    # which is a separate axis: overriding Topic#banner without widening the
    # key would serve the first visitor's language to everyone who shares
    # their interface locale.
    #
    # The body mirrors core's ApplicationLayoutPreloader#banner_json; only the
    # cache key differs. Invalidation still runs through core, which clears
    # the whole cache rather than individual keys, so the extra axis needs no
    # matching invalidation of its own.
    def banner_json
      return super unless SiteSetting.babel_reunited_enabled
      return "{}" if !@guardian.authenticated? && SiteSetting.login_required?

      suffix = BabelReunited::BannerTranslator.cache_key_suffix(@guardian)

      self
        .class
        .banner_json_cache
        .defer_get_set("json_#{I18n.locale}_#{suffix}") do
          topic = Topic.where(archetype: Archetype.banner).first
          banner =
            if topic.present? && !topic.category&.read_restricted?
              topic.banner(@guardian)
            else
              {}
            end
          MultiJson.dump(banner)
        end
    end
  end
end
