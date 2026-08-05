# frozen_string_literal: true

module BabelReunited
  # Picks which language the site banner is rendered in.
  #
  # The banner is not part of the post stream, so the language tabs never run
  # for it and the reader gets no switcher: whatever this returns is all they
  # see. That makes the fallback shape the whole design -- never leave a reader
  # in front of a language they cannot read while we already hold something
  # better, and never spend a translation to find that out.
  #
  # Read-only by construction. The banner is on every page, so a path that
  # could enqueue work here would turn every visitor into a trigger.
  module BannerTranslator
    # Translated cooked HTML for this reader, or nil to keep the original.
    def self.cooked_for(post, guardian)
      return nil unless SiteSetting.babel_reunited_enabled
      return nil if post.blank?
      # An admin narrowing the enabled categories is saying "no machine
      # translation here". The post stream honors that by hiding the tabs;
      # the banner has no tabs, so it has to honor it by showing the
      # original. Existing translations are not deleted, just not served.
      return nil unless BabelReunited.translation_enabled_for_post?(post)

      detected = BabelReunited.current_detected_locale_for(post)

      candidates(guardian).each do |language|
        # The original already is this language. Without this step a reader who
        # prefers Chinese, looking at a Chinese banner, would find no zh-cn
        # translation (a post is never translated into its own language), fall
        # through to the site default, and be shown English instead of the
        # Chinese they asked for.
        return nil if language == detected

        # displayable_translation_for already applies the display guard, so
        # anything that reaches here is a translation of the post's current
        # content. A blank body is a claim that has not produced one yet.
        translation = BabelReunited.displayable_translation_for(post, language)
        next if translation.blank? || translation.translated_content.blank?

        return translation.translated_content
      end

      nil
    end

    # Preferred language first, then the site default. Anonymous readers have
    # no preference and land on the site default, which is the language the
    # rest of the interface already speaks to them in.
    def self.candidates(guardian)
      [
        BabelReunited.preferred_language_for(guardian&.user),
        normalize(SiteSetting.default_locale)
      ].compact.uniq
    end

    # I18n writes locales as "zh_CN"; language codes here are "zh-cn".
    def self.normalize(locale)
      code = locale.to_s.downcase.tr("_", "-")
      BabelReunited::Locales.valid?(code) ? code : nil
    end

    # Cache axis for the banner payload: two readers whose banner can come out
    # in different languages must not share a cache entry.
    def self.cache_key_suffix(guardian)
      BabelReunited.preferred_language_for(guardian&.user).presence || "-"
    end
  end
end
