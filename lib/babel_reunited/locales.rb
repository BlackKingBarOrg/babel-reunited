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
      el
      en
      eo
      es
      et
      eu
      fa
      fi
      fil
      fj
      fo
      fr
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
      no
      pa
      pl
      ps
      pt
      pt-br
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
      zh-tw
      zu
    ].freeze

    SUPPORTED_SET = SUPPORTED.to_set.freeze

    def self.valid?(code)
      code.present? && SUPPORTED_SET.include?(code)
    end

    def self.format_valid?(code)
      code.present? && code.match?(LANGUAGE_CODE_FORMAT)
    end
  end
end
