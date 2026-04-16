# frozen_string_literal: true

RSpec.describe BabelReunited::ContentSplitter do
  before { enable_current_plugin }

  describe ".split" do
    it "returns empty array for nil content" do
      expect(described_class.split(content: nil, chunk_size: 100)).to eq([])
    end

    it "returns single empty string for empty content" do
      expect(described_class.split(content: "", chunk_size: 100)).to eq([""])
    end

    it "returns single chunk when content is shorter than chunk_size" do
      text = "Short text"
      expect(described_class.split(content: text, chunk_size: 100)).to eq([text])
    end

    it "returns single chunk when content equals chunk_size" do
      text = "x" * 100
      expect(described_class.split(content: text, chunk_size: 100)).to eq([text])
    end

    it "splits at paragraph boundaries (double newline)" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      chunks = described_class.split(content: text, chunk_size: 30)

      expect(chunks.size).to be > 1
      expect(chunks.join("")).to eq(text)
      chunks[0..-2].each { |c| expect(c).to end_with("\n\n") }
    end

    it "splits at sentence boundaries when no paragraph break fits" do
      text = "First sentence. Second sentence. Third sentence. Fourth sentence."
      chunks = described_class.split(content: text, chunk_size: 35)

      expect(chunks.size).to be > 1
      expect(chunks.join("")).to eq(text)
    end

    it "splits at single newline when no sentence boundary fits" do
      text = "aaa bbb ccc\nddd eee fff\nggg hhh iii"
      chunks = described_class.split(content: text, chunk_size: 15)

      expect(chunks.size).to be > 1
      expect(chunks.join("")).to eq(text)
    end

    it "hard cuts when no natural boundary is found" do
      text = "a" * 200
      chunks = described_class.split(content: text, chunk_size: 50)

      expect(chunks.size).to eq(4)
      expect(chunks.join("")).to eq(text)
    end

    it "preserves fenced code blocks across chunk boundary" do
      code_block = "```ruby\ndef foo\n  bar\nend\n```"
      text = "Before text.\n\n#{code_block}\n\nAfter text."
      chunks = described_class.split(content: text, chunk_size: 20)

      all_text = chunks.join("")
      expect(all_text).to eq(text)

      code_chunk = chunks.find { |c| c.include?("```ruby") }
      expect(code_chunk).to include("```ruby")
      expect(code_chunk).to include("```")
    end

    it "preserves BBCode quote blocks" do
      quote = "[quote=\"user\"]\nSome quoted text here\n[/quote]"
      text = "Before.\n\n#{quote}\n\nAfter."
      chunks = described_class.split(content: text, chunk_size: 20)

      all_text = chunks.join("")
      expect(all_text).to eq(text)

      quote_chunk = chunks.find { |c| c.include?("[quote") }
      expect(quote_chunk).to include("[/quote]")
    end

    it "preserves BBCode details blocks" do
      details = "[details=\"Summary\"]\nHidden content here\n[/details]"
      text = "Before.\n\n#{details}\n\nAfter."
      chunks = described_class.split(content: text, chunk_size: 20)

      all_text = chunks.join("")
      expect(all_text).to eq(text)

      details_chunk = chunks.find { |c| c.include?("[details") }
      expect(details_chunk).to include("[/details]")
    end

    it "keeps oversized block as a single chunk" do
      large_code = "```\n#{"x" * 200}\n```"
      text = "Before.\n\n#{large_code}\n\nAfter."
      chunks = described_class.split(content: text, chunk_size: 50)

      all_text = chunks.join("")
      expect(all_text).to eq(text)

      code_chunk = chunks.find { |c| c.include?("```") }
      expect(code_chunk).to include("x" * 200)
    end

    it "reassembles to original content" do
      text =
        "Para one with some text.\n\nPara two with more.\n\n```\ncode\n```\n\nPara three final."
      chunks = described_class.split(content: text, chunk_size: 40)
      expect(chunks.join("")).to eq(text)
    end

    it "handles CJK content" do
      text = "first\n\n#{"a" * 50}\n\nsecond"
      chunks = described_class.split(content: text, chunk_size: 30)

      expect(chunks.join("")).to eq(text)
      expect(chunks.size).to be > 1
    end

    it "uses MarkdownProtector::BLOCK_PATTERNS for block detection" do
      expect(BabelReunited::MarkdownProtector::BLOCK_PATTERNS).to be_an(Array)
      expect(BabelReunited::MarkdownProtector::BLOCK_PATTERNS).not_to be_empty
    end
  end
end
