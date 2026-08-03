# frozen_string_literal: true

module BabelReunited
  # Single source of truth for which language codes the plugin accepts.
  # Mirrored client-side in assets/javascripts/discourse/lib/babel-locales.js;
  # spec/lib/babel_reunited/locales_spec.rb asserts the two lists stay in sync.
  module Locales
    LANGUAGE_CODE_FORMAT = /\A[a-z]{2,3}(-[a-z]{2})?\z/

    SUPPORTED = %w[
      af
      am
      ar
      az
      be
      bg
      bn
      bs
      ca
      ceb
      ckb
      cs
      cy
      da
      de
      de-at
      de-ch
      el
      en
      en-au
      en-ca
      en-gb
      en-us
      eo
      es
      es-ar
      es-mx
      et
      eu
      fa
      fi
      fil
      fj
      fo
      fr
      fr-be
      fr-ca
      fr-ch
      fy
      ga
      gd
      gl
      gu
      ha
      haw
      he
      hi
      hr
      ht
      hu
      hy
      id
      ig
      is
      it
      it-ch
      ja
      jv
      ka
      kk
      km
      kn
      ko
      ku
      ky
      la
      lb
      lo
      lt
      lv
      mg
      mi
      mk
      ml
      mn
      mr
      ms
      mt
      my
      ne
      nl
      nl-be
      no
      pa
      pl
      ps
      pt
      pt-br
      pt-pt
      ro
      ru
      rw
      sd
      si
      sk
      sl
      sm
      sn
      so
      sq
      sr
      st
      su
      sv
      sw
      ta
      te
      tg
      th
      tk
      to
      tr
      tt
      ug
      uk
      ur
      uz
      vi
      xh
      yi
      yo
      yue
      zh-cn
      zh-hk
      zh-tw
      zu
    ].freeze

    SUPPORTED_SET = SUPPORTED.to_set.freeze

    # Country-level variants stay valid so records and preferences that
    # predate the curated list keep working, but they are not offered for
    # selection: an LLM translating into "American English" rather than
    # "English" produces the same text at twice the price, and readers
    # spreading across variants fragment the cache the lazy layer depends on.
    #
    # Script differences are the exception and stay selectable — zh-cn and
    # zh-tw are genuinely different writing systems. zh-hk is not one: written
    # Hong Kong Chinese is close to zh-tw, and Cantonese has its own code.
    LEGACY_VARIANTS = %w[
      de-at
      de-ch
      en-au
      en-ca
      en-gb
      en-us
      es-ar
      es-mx
      fr-be
      fr-ca
      fr-ch
      it-ch
      nl-be
      pt-pt
      zh-hk
    ].freeze

    SELECTABLE = (SUPPORTED - LEGACY_VARIANTS).freeze

    def self.valid?(code)
      code.present? && SUPPORTED_SET.include?(code)
    end

    def self.selectable?(code)
      code.present? && SELECTABLE.include?(code)
    end

    def self.format_valid?(code)
      code.present? && code.match?(LANGUAGE_CODE_FORMAT)
    end
  end
end
