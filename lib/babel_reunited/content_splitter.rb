# frozen_string_literal: true

module BabelReunited
  class ContentSplitter
    TEXT_BOUNDARIES = [
      /\n\s*\n\s*/, # double newlines (paragraph boundary)
      /[.!?]\s+/, # sentence endings
      /[,;]\s+/, # clause endings
      /\n/, # single newline
      /\s+/, # any whitespace
    ].freeze

    def self.split(content:, chunk_size:)
      return [] if content.nil?
      return [""] if content.empty?
      return [content] if content.length <= chunk_size

      chunks = []
      remaining = content.dup

      while remaining.present?
        chunk = extract_chunk(remaining, chunk_size)
        break if chunk.empty?
        chunks << chunk
        remaining = remaining[chunk.length..]
      end

      chunks
    end

    class << self
      private

      def extract_chunk(text, size)
        return text if text.length <= size

        split_point = find_block_boundary(text, size) || find_text_boundary(text, size) || size
        split_point = extend_through_whitespace(text, split_point)

        text[0...split_point]
      end

      # Inter-chunk whitespace must belong to the previous chunk: the translation
      # step only preserves trailing whitespace, so a separator left at the head
      # of the next chunk would be destroyed by the LLM response strip and glue
      # the chunks together (e.g. a closing ``` fence onto the next paragraph).
      def extend_through_whitespace(text, pos)
        pos += 1 while pos < text.length && text[pos].match?(/\s/)
        pos
      end

      def find_block_boundary(text, target_pos)
        best = nil

        MarkdownProtector::BLOCK_PATTERNS.each do |pattern|
          text.scan(pattern) do |_|
            match = Regexp.last_match
            block_start = match.begin(0)
            block_end = match.end(0)

            # If a block straddles the target position, split before it
            if block_start < target_pos && block_end > target_pos
              return block_start.positive? ? block_start : block_end
            end

            # Track the last block boundary that fits within target
            best = block_end if block_end <= target_pos && (best.nil? || block_end > best)
          end
        end

        best
      end

      def find_text_boundary(text, target_pos)
        TEXT_BOUNDARIES.each do |pattern|
          pos = text.rindex(pattern, target_pos)
          next unless pos

          # Include the matched whitespace in the current chunk
          match = text.match(pattern, pos)
          end_pos = match ? pos + match[0].length : pos + 1
          return end_pos if end_pos <= target_pos && end_pos.positive?
        end

        nil
      end
    end
  end
end
