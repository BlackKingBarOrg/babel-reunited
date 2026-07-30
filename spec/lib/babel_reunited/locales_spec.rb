# frozen_string_literal: true

RSpec.describe BabelReunited::Locales do
  describe ".valid?" do
    it "accepts supported two-letter codes" do
      expect(described_class.valid?("en")).to be true
      expect(described_class.valid?("th")).to be true
    end

    it "accepts supported regional codes" do
      expect(described_class.valid?("zh-cn")).to be true
      expect(described_class.valid?("pt-br")).to be true
    end

    it "accepts supported three-letter codes" do
      expect(described_class.valid?("yue")).to be true
      expect(described_class.valid?("fil")).to be true
    end

    it "rejects well-formed but unsupported codes" do
      expect(described_class.valid?("qq")).to be false
      expect(described_class.valid?("eng")).to be false
    end

    it "rejects blank and malformed codes" do
      expect(described_class.valid?(nil)).to be false
      expect(described_class.valid?("")).to be false
      expect(described_class.valid?("EN")).to be false
    end
  end

  describe ".format_valid?" do
    it "accepts two- and three-letter codes with optional region" do
      expect(described_class.format_valid?("en")).to be true
      expect(described_class.format_valid?("yue")).to be true
      expect(described_class.format_valid?("zh-cn")).to be true
    end

    it "rejects malformed codes" do
      expect(described_class.format_valid?("e")).to be false
      expect(described_class.format_valid?("abcd")).to be false
      expect(described_class.format_valid?("zh_CN")).to be false
      expect(described_class.format_valid?(nil)).to be false
    end
  end

  describe "list integrity" do
    it "contains only codes matching the format" do
      expect(described_class::SUPPORTED).to all(match(described_class::LANGUAGE_CODE_FORMAT))
    end

    it "contains no duplicates and stays sorted" do
      expect(described_class::SUPPORTED).to eq(described_class::SUPPORTED.uniq.sort)
    end

    it "includes the default auto-translate languages" do
      %w[en zh-cn es].each { |code| expect(described_class.valid?(code)).to be true }
    end

    it "stays in sync with the client-side mirror" do
      js_path =
        File.expand_path(
          "../../../assets/javascripts/discourse/lib/babel-locales.js",
          __dir__,
        )
      js_codes = File.read(js_path).scan(/^\s+"([a-z-]+)",$/).flatten
      expect(js_codes).to eq(described_class::SUPPORTED)
    end
  end
end
