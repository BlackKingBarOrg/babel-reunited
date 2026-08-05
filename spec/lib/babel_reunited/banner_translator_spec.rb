# frozen_string_literal: true

RSpec.describe BabelReunited::BannerTranslator do
  fab!(:user)
  fab!(:topic)
  fab!(:post_record) { Fabricate(:post, topic: topic, raw: "Hello world" * 20) }

  let(:guardian) { Guardian.new(user) }
  let(:anonymous) { Guardian.new }

  before do
    enable_current_plugin
    SiteSetting.default_locale = "en"
    BabelReunited.store_detected_locale(post_record, "zh-cn")
  end

  def prefer(language)
    user.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = language
    user.save_custom_fields
  end

  def translation(language, **attrs)
    Fabricate(
      :post_translation,
      post: post_record,
      language: language,
      translated_content: "<p>#{language} body</p>",
      **attrs
    )
  end

  it "returns the preferred language when it has a translation" do
    translation("es")
    translation("en")
    prefer("es")

    expect(described_class.cooked_for(post_record, guardian)).to eq(
      "<p>es body</p>"
    )
  end

  it "falls back to the site default when the preferred language has none" do
    translation("en")
    prefer("th")

    expect(described_class.cooked_for(post_record, guardian)).to eq(
      "<p>en body</p>"
    )
  end

  it "gives anonymous readers the site default" do
    translation("en")

    expect(described_class.cooked_for(post_record, anonymous)).to eq(
      "<p>en body</p>"
    )
  end

  it "keeps the original when no candidate has a translation" do
    prefer("th")

    expect(described_class.cooked_for(post_record, guardian)).to be_nil
  end

  it "keeps the original when the reader's language is the post's own" do
    # A same-language row can exist from before the fan-out learned to skip
    # the post's own language. Serving it would show a machine round-trip of
    # the original in place of the original.
    translation("zh-cn", translated_content: "<p>round trip</p>")
    translation("en")
    prefer("zh-cn")

    expect(described_class.cooked_for(post_record, guardian)).to be_nil
  end

  it "skips a stale translation, since the post changed after it was made" do
    translation("es", status: "stale")
    translation("en")
    prefer("es")

    expect(described_class.cooked_for(post_record, guardian)).to eq(
      "<p>en body</p>"
    )
  end

  it "skips a record that has been claimed but has no body yet" do
    translation("es", status: "translating", translated_content: "")
    translation("en")
    prefer("es")

    expect(described_class.cooked_for(post_record, guardian)).to eq(
      "<p>en body</p>"
    )
  end

  it "normalizes the site default locale to a plugin language code" do
    SiteSetting.default_locale = "zh_TW"
    translation("zh-tw")

    expect(described_class.cooked_for(post_record, anonymous)).to eq(
      "<p>zh-tw body</p>"
    )
  end

  it "keeps the original when the plugin is disabled" do
    translation("en")
    SiteSetting.babel_reunited_enabled = false

    expect(described_class.cooked_for(post_record, anonymous)).to be_nil
  end

  # The post stream honors the category allowlist by hiding the tabs. The
  # banner has no tabs, so it has to honor it by showing the original.
  it "keeps the original when the category is no longer enabled" do
    translation("en")
    SiteSetting.babel_reunited_enabled_categories = Fabricate(:category).id.to_s

    expect(described_class.cooked_for(post_record, anonymous)).to be_nil
  end

  describe ".cache_key_suffix" do
    it "is the preferred language" do
      prefer("es")
      expect(described_class.cache_key_suffix(guardian)).to eq("es")
    end

    it "is a placeholder when there is no preference" do
      expect(described_class.cache_key_suffix(anonymous)).to eq("-")
    end
  end
end
