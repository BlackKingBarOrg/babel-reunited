# frozen_string_literal: true

module BabelReunited
  class MarkdownProtector
    # Pass 1: Block-level structures (outermost first)
    BLOCK_PATTERNS = [
      /^```[\s\S]*?^```/m, # fenced code blocks
      %r{\[code\][\s\S]*?\[/code\]}m, # BBCode code
      %r{\[quote[^\]]*\][\s\S]*?\[/quote\]}m, # BBCode quote
      %r{\[details[^\]]*\][\s\S]*?\[/details\]}m, # BBCode details
    ]

    # Pass 2: Inline structures (after blocks are protected)
    INLINE_PATTERNS = [
      /`[^`\n]+`/, # inline code
      /\[([^\]]*)\]\(([^)]+)\)/, # markdown links
      %r{https?://\S+}, # bare URLs
      /@[\w.-]+/, # @mentions
      /:[a-z0-9_+-]+:/, # emoji shortcodes
    ]

    TOKEN_PREFIX = "\u27E6TK"
    TOKEN_SUFFIX = "\u27E7"

    def initialize(text)
      @text = text
      @tokens = {}
      @counter = 0
    end

    def protect
      result = @text.dup
      BLOCK_PATTERNS.each { |pat| result = tokenize(result, pat) }
      INLINE_PATTERNS.each { |pat| result = tokenize(result, pat) }
      [result, @tokens]
    end

    def self.restore(text, tokens)
      result = text.dup
      tokens.to_a.reverse.each { |key, value| result.gsub!(key, value) }
      result
    end

    private

    def tokenize(text, pattern)
      text.gsub(pattern) do |match|
        key = "#{TOKEN_PREFIX}#{@counter}#{TOKEN_SUFFIX}"
        @tokens[key] = match
        @counter += 1
        key
      end
    end
  end
end
