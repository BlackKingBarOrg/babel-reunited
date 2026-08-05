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
      expect(described_class::SUPPORTED).to all(
        match(described_class::LANGUAGE_CODE_FORMAT)
      )
    end

    it "contains no duplicates and stays sorted" do
      expect(described_class::SUPPORTED).to eq(
        described_class::SUPPORTED.uniq.sort
      )
    end

    it "includes the default auto-translate languages" do
      %w[en zh-cn es].each do |code|
        expect(described_class.valid?(code)).to be true
      end
    end

    it "stays in sync with the client-side mirror" do
      js = File.read(js_mirror_path)
      supported = js[/SUPPORTED_LOCALES = \[(.*?)\];/m, 1]
      legacy = js[/PLACE_VARIANTS = new Set\(\[(.*?)\]\);/m, 1]

      expect(supported.scan(/"([a-z-]+)"/).flatten).to eq(
        described_class::SUPPORTED
      )
      expect(legacy.scan(/"([a-z-]+)"/).flatten).to eq(
        described_class::PLACE_VARIANTS
      )
    end

    # The client decides whether to fire a view trigger and whether to offer a
    # language at all; if its rule drifts from the server's, a reader pays for
    # a translation the server then refuses to show.
    it "agrees with the client-side mirror on language equivalence" do
      js = File.read(js_mirror_path)
      body = js[/export function sameLanguage\(a, b\) \{(.*?)\n\}/m, 1]
      expect(body).to be_present

      cases = [
        %w[en-us en],
        %w[en-gb en-us],
        %w[pt-br pt],
        %w[zh-cn zh-tw],
        %w[zh-cn zh-cn],
        %w[es en]
      ]
      cases.each do |a, b|
        expect(BabelReunited.same_language?(a, b)).to eq(
          js_same_language?(body, a, b)
        ),
        "#{a} vs #{b} disagrees between Ruby and JS"
      end
    end

    # Evaluates the mirrored rule rather than restating it, so a change to one
    # side without the other fails here.
    def js_same_language?(body, a, b)
      result =
        `node -e 'function sameLanguage(a, b) {#{body}\n}; process.stdout.write(String(sameLanguage(#{a.inspect}, #{b.inspect})))'`
      result == "true"
    end

    def js_mirror_path
      File.expand_path(
        "../../../assets/javascripts/discourse/lib/babel-locales.js",
        __dir__
      )
    end
  end

  describe "selectable list" do
    it "offers no country-level variant" do
      described_class::PLACE_VARIANTS.each do |code|
        expect(described_class.selectable?(code)).to be false
        expect(described_class.valid?(code)).to(
          be(true),
          "#{code} must stay valid so existing records keep working"
        )
      end
    end

    it "offers no variant distinguished by place" do
      # Every remaining selectable code with a region subtag is one whose
      # distinction is the script, shown as Simplified/Traditional.
      region_tagged = described_class::SELECTABLE.select { |c| c.include?("-") }
      expect(region_tagged).to contain_exactly("zh-cn", "zh-tw")
    end

    it "keeps script-level distinctions selectable" do
      # Simplified and Traditional are different writing systems; Cantonese
      # has its own code, so zh-hk adds nothing over zh-tw.
      %w[zh-cn zh-tw yue].each do |code|
        expect(described_class.selectable?(code)).to be true
      end
      expect(described_class.selectable?("zh-hk")).to be false
    end

    it "differs from the supported list only by those variants" do
      expect(described_class::SUPPORTED - described_class::SELECTABLE).to eq(
        described_class::PLACE_VARIANTS
      )
    end
  end
end
