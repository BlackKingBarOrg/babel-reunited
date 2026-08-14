# frozen_string_literal: true

module BabelReunited
  # Structural fingerprint of markdown text. A faithful translation keeps the
  # source's structure — headings stay headings, fences stay fences — so a
  # large shape difference means the output is not a translation of the input
  # (answer-mode output, truncation, commentary). Shared by the translation
  # service (reject before persisting) and the anomaly scan (sweep existing
  # records), so both judge by exactly the same rule.
  module TranslationStructure
    COUNTED = %i[headings fences list_items blockquotes].freeze

    # Structure counts are language-independent, so a faithful translation
    # matches them nearly exactly; small wobble is tolerated only when both
    # relative and absolute thresholds are exceeded is it drift.
    ABSOLUTE_TOLERANCE = 2
    RELATIVE_TOLERANCE = 0.34

    # Short texts have no stable ratio to measure.
    MIN_LENGTH_FOR_RATIO = 200

    # Length ratio is a property of the script pair before it is one of
    # fidelity: Chinese to English expands three to five times and the
    # reverse compresses to a fifth, so one window cuts straight through
    # what a faithful translation looks like. Where the extreme sits depends
    # on whether the pair crosses scripts.
    SAME_SCRIPT_RATIO_RANGE = (0.25..4.0)
    CROSS_SCRIPT_RATIO_RANGE = (0.08..8.0)

    CJK = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/

    # Above this share of non-space characters a text reads as CJK.
    CJK_SCRIPT_SHARE = 0.2

    # A post written in two languages puts one after the other, so its two
    # halves differ in script. Overall share cannot see this: Chinese is
    # dense enough that a document carrying equal Chinese and English content
    # measures only 13-26% CJK by character, which is indistinguishable from
    # English prose quoting Chinese terms. The gap between the halves is what
    # separates them -- measured across the flagged staging records it runs
    # 0.09-0.51 for bilingual originals and under 0.05 for everything else.
    MIN_SCRIPT_SPLIT_GAP = 0.08

    # And the source has to contain some CJK at all, or a pure-Latin post
    # whose translation collapsed to nothing would be read as bilingual on
    # the strength of its small counts alone.
    MIN_BILINGUAL_CJK_SHARE = 0.02

    # CJK authors routinely write "1.项目" with no space after the marker,
    # and a translation normalizes it to "1. Item". Requiring the space
    # counts zero list items in the source and three in the translation,
    # reporting invented structure where punctuation was normalized.
    #
    # Only numeric markers get that allowance. A bullet character followed
    # straight by CJK is far more often emphasis -- "*说得很准确*" is an
    # italic line, not a list item -- while a digit, a period and a
    # character can be nothing else.
    LIST_ITEM =
      /\A\s*(?:[-*+]\s|\d+[.)](?:\s|(?=[\p{Han}\p{Hiragana}\p{Katakana}])))/

    def self.signature(text)
      lines = text.to_s.lines
      {
        headings: lines.count { |l| l.match?(/\A\#{1,6}\s/) },
        fences: lines.count { |l| l.match?(/\A\s*```/) },
        list_items: lines.count { |l| l.match?(LIST_ITEM) },
        blockquotes: lines.count { |l| l.match?(/\A\s*>/) },
        # Collapsed: a post padded with long runs of blank lines otherwise
        # counts as far longer than it reads, which pushed a faithful
        # translation of post 23994 down to a ratio of 0.19.
        length: text.to_s.gsub(/\s+/, " ").strip.length
      }
    end

    # Returns human-readable drift reasons; empty when the translation's
    # shape is compatible with the source's.
    def self.drift(original, translated)
      a = signature(original)
      b = signature(translated)

      reasons = compare(a, b, cross_script?(original, translated))
      return reasons if reasons.empty?

      # A post written in two languages carries the same document twice, so
      # a complete translation of it has half the structure. That is also
      # what truncation looks like, so the halved reading is only tried once
      # the direct one has already failed, and only accepted when it
      # explains the difference completely.
      return reasons unless bilingual_source?(original)

      if compare(halve(a), b, cross_script?(original, translated)).empty?
        []
      else
        reasons
      end
    end

    def self.drifted?(original, translated)
      drift(original, translated).any?
    end

    def self.compare(a, b, cross_script)
      reasons =
        COUNTED.filter_map do |key|
          x = a[key]
          y = b[key]
          next if x == y

          diff = (x - y).abs
          next if diff <= ABSOLUTE_TOLERANCE
          next if diff.to_f / [x, y].max <= RELATIVE_TOLERANCE

          "#{key} #{x}->#{y}"
        end

      if a[:length] >= MIN_LENGTH_FOR_RATIO
        ratio = b[:length].to_f / a[:length]
        range =
          cross_script ? CROSS_SCRIPT_RATIO_RANGE : SAME_SCRIPT_RATIO_RANGE
        reasons << "length ratio #{ratio.round(2)}" unless range.cover?(ratio)
      end

      reasons
    end
    private_class_method :compare

    def self.halve(signature)
      signature.transform_values { |v| v / 2 }
    end
    private_class_method :halve

    def self.cjk_share(text)
      compact = text.to_s.gsub(/\s+/, "")
      return 0.0 if compact.empty?

      compact.scan(CJK).size.to_f / compact.length
    end

    def self.bilingual_source?(text)
      compact = text.to_s.gsub(/\s+/, "")
      return false if compact.length < MIN_LENGTH_FOR_RATIO
      return false if cjk_share(text) < MIN_BILINGUAL_CJK_SHARE

      mid = compact.length / 2
      gap = (cjk_share(compact[0...mid]) - cjk_share(compact[mid..])).abs
      gap >= MIN_SCRIPT_SPLIT_GAP
    end
    private_class_method :bilingual_source?

    def self.cross_script?(original, translated)
      (cjk_share(original) >= CJK_SCRIPT_SHARE) !=
        (cjk_share(translated) >= CJK_SCRIPT_SHARE)
    end
    private_class_method :cross_script?
  end
end
