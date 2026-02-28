# frozen_string_literal: true

RSpec.describe BabelReunited::MarkdownProtector do
  before { enable_current_plugin }

  def roundtrip(text)
    protector = described_class.new(text)
    protected_text, tokens = protector.protect
    described_class.restore(protected_text, tokens)
  end

  describe "#protect + .restore roundtrip" do
    it "preserves fenced code blocks" do
      text = "Hello\n```ruby\ndef foo\n  bar\nend\n```\nWorld"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves inline code" do
      text = "Use `some_method` for that"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves @mentions" do
      text = "Hey @admin check this out"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves markdown links" do
      text = "Visit [Discourse](https://discourse.org) for more"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves bare URLs" do
      text = "Check https://example.com/path?q=1 for details"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves BBCode quote blocks" do
      text = "Before\n[quote=\"user\"]\nSome quoted text\n[/quote]\nAfter"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves emoji shortcodes" do
      text = "This is great :smile: and :+1:"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves BBCode details blocks" do
      text = "Before\n[details=\"Summary\"]\nHidden content\n[/details]\nAfter"
      expect(roundtrip(text)).to eq(text)
    end

    it "preserves BBCode code blocks" do
      text = "Before\n[code]\nsome code\n[/code]\nAfter"
      expect(roundtrip(text)).to eq(text)
    end

    it "handles nested structures (code inside quote)" do
      text = "[quote=\"user\"]\n```\ncode here\n```\n[/quote]"
      expect(roundtrip(text)).to eq(text)
    end

    it "handles Unicode/CJK content around tokens" do
      text = "这是一个测试 `code` 和 @用户 链接 https://example.com"
      expect(roundtrip(text)).to eq(text)
    end

    it "handles empty input" do
      expect(roundtrip("")).to eq("")
    end

    it "handles text with no protectable content" do
      text = "Just plain text with nothing special"
      expect(roundtrip(text)).to eq(text)
    end
  end

  describe "#protect" do
    it "replaces code blocks with tokens" do
      protector = described_class.new("Hello\n```\ncode\n```\nWorld")
      protected_text, tokens = protector.protect

      expect(protected_text).not_to include("```")
      expect(protected_text).to include("\u27E6TK")
      expect(tokens.size).to eq(1)
    end

    it "replaces inline elements with tokens" do
      protector = described_class.new("Use `method` and @admin")
      protected_text, tokens = protector.protect

      expect(protected_text).not_to include("`method`")
      expect(protected_text).not_to include("@admin")
      expect(tokens.size).to eq(2)
    end

    it "tokenizes block patterns before inline patterns" do
      text = "```\n`inline` and @mention\n```"
      protector = described_class.new(text)
      _protected_text, tokens = protector.protect

      # The entire code block should be one token (block-level)
      # not three tokens (block + inline code + mention)
      expect(tokens.size).to eq(1)
    end
  end

  describe ".restore" do
    it "restores tokens back to original content" do
      tokens = { "\u27E6TK0\u27E7" => "```ruby\ncode\n```", "\u27E6TK1\u27E7" => "@admin" }
      text = "Hello \u27E6TK0\u27E7 and \u27E6TK1\u27E7"

      result = described_class.restore(text, tokens)
      expect(result).to include("```ruby\ncode\n```")
      expect(result).to include("@admin")
    end
  end
end
