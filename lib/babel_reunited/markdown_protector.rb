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
      %r{https?://\S+}, # bare URLs
      /@[\w.-]+/, # @mentions
      /:[a-z0-9_+-]+:/, # emoji shortcodes
    ]

    # Markdown links get special handling: only protect the URL, not the display text
    MARKDOWN_LINK_PATTERN = /\[([^\]]*)\]\(([^)]+)\)/

    TOKEN_OPEN = "\u27E6"
    TOKEN_CLOSE = "\u27E7"

    def initialize(text)
      @text = text
      @tokens = {}
      @counter = 0
      @salt = SecureRandom.hex(4)
    end

    def protect
      result = @text.dup
      BLOCK_PATTERNS.each { |pat| result = tokenize(result, pat) }
      result = tokenize_link_urls(result)
      INLINE_PATTERNS.each { |pat| result = tokenize(result, pat) }
      [result, @tokens]
    end

    def self.restore(text, tokens)
      restore_and_verify(text, tokens).first
    end

    # Returns [restored_text, missing_keys]. A missing key means the LLM
    # dropped that placeholder and its original content (link/code/mention)
    # is unrecoverable from this response — callers should treat the
    # translation as failed rather than silently store it.
    # Restoring in reverse insertion order keeps nested tokens working: a
    # later token's value may contain an earlier token's key.
    def self.restore_and_verify(text, tokens)
      result = text.dup
      missing = []
      tokens.to_a.reverse.each { |key, value| missing << key unless result.gsub!(key) { value } }
      [result, missing]
    end

    private

    def tokenize_link_urls(text)
      text.gsub(MARKDOWN_LINK_PATTERN) do |_match|
        display_text = Regexp.last_match(1)
        url = Regexp.last_match(2)
        key = "#{TOKEN_OPEN}#{@salt}:#{@counter}#{TOKEN_CLOSE}"
        @tokens[key] = url
        @counter += 1
        "[#{display_text}](#{key})"
      end
    end

    def tokenize(text, pattern)
      text.gsub(pattern) do |match|
        key = "#{TOKEN_OPEN}#{@salt}:#{@counter}#{TOKEN_CLOSE}"
        @tokens[key] = match
        @counter += 1
        key
      end
    end
  end
end
