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

    # Length ratios between languages vary widely (CJK vs Latin), so only
    # extremes count, and short texts are skipped entirely.
    MIN_LENGTH_FOR_RATIO = 200
    LENGTH_RATIO_RANGE = (0.25..4.0)

    def self.signature(text)
      lines = text.to_s.lines
      {
        headings: lines.count { |l| l.match?(/\A\#{1,6}\s/) },
        fences: lines.count { |l| l.match?(/\A\s*```/) },
        list_items: lines.count { |l| l.match?(/\A\s*(?:[-*+]|\d+[.)])\s/) },
        blockquotes: lines.count { |l| l.match?(/\A\s*>/) },
        length: text.to_s.length
      }
    end

    # Returns human-readable drift reasons; empty when the translation's
    # shape is compatible with the source's.
    def self.drift(original, translated)
      a = signature(original)
      b = signature(translated)

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
        unless LENGTH_RATIO_RANGE.cover?(ratio)
          reasons << "length ratio #{ratio.round(2)}"
        end
      end

      reasons
    end

    def self.drifted?(original, translated)
      drift(original, translated).any?
    end
  end
end
