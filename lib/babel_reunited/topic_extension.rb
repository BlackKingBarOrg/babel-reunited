# frozen_string_literal: true

module BabelReunited
  module TopicExtension
    # Core already localizes the banner, but on the interface-language axis
    # (its own ContentLocalization). This plugin's axis is the reader's
    # preferred language, so it layers on top: core's result stands whenever
    # we have nothing better.
    #
    # Called with no guardian from make_banner!/remove_banner!, where the
    # result is broadcast to every connected client. Falling through to the
    # site default there is correct: it is one language for everyone, and it
    # is the one the site itself defaults to.
    def banner(guardian = nil)
      result = super

      translated =
        BabelReunited::BannerTranslator.cooked_for(
          ordered_posts.first,
          guardian
        )
      result[:html] = translated if translated.present?

      result
    end
  end
end
