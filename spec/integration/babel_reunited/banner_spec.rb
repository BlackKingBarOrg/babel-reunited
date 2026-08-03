# frozen_string_literal: true

RSpec.describe "banner translation" do
  fab!(:spanish_reader, :user)
  fab!(:chinese_reader, :user)
  fab!(:banner_topic) { Fabricate(:topic, archetype: Archetype.banner) }
  fab!(:banner_post) do
    Fabricate(:post, topic: banner_topic, post_number: 1, raw: "Hello world")
  end

  before do
    enable_current_plugin
    SiteSetting.default_locale = "en"
    BabelReunited.store_detected_locale(banner_post, "en")
    ApplicationLayoutPreloader.banner_json_cache.clear

    Fabricate(
      :post_translation,
      post: banner_post,
      language: "es",
      translated_content: "<p>Hola mundo</p>"
    )
    Fabricate(
      :post_translation,
      post: banner_post,
      language: "zh-cn",
      translated_content: "<p>Ni hao</p>"
    )

    prefer(spanish_reader, "es")
    prefer(chinese_reader, "zh-cn")
  end

  def prefer(user, language)
    user.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = language
    user.save_custom_fields
  end

  def banner_json_for(user)
    ApplicationLayoutPreloader.new(
      guardian: Guardian.new(user),
      theme_id: nil,
      theme_target: :desktop,
      login_method: nil
    ).banner_json
  end

  describe "Topic#banner" do
    it "renders the reader's preferred language" do
      expect(banner_topic.banner(Guardian.new(spanish_reader))[:html]).to eq(
        "<p>Hola mundo</p>"
      )
    end

    it "renders the original when the reader's language is the post's own" do
      prefer(spanish_reader, "en")

      expect(banner_topic.banner(Guardian.new(spanish_reader))[:html]).to eq(
        banner_post.cooked
      )
    end

    # make_banner!/remove_banner! call this with no guardian and broadcast the
    # result to everyone, so it has to stay callable and land on one language.
    it "renders the site default without a guardian" do
      expect(banner_topic.banner[:html]).to eq(banner_post.cooked)
    end
  end

  describe "banner_json caching" do
    it "does not serve one reader's language to another" do
      # The regression this guards: the cache is process-wide and core keys it
      # by interface locale only, an axis these two readers share.
      expect(banner_json_for(spanish_reader)).to include("Hola mundo")
      expect(banner_json_for(chinese_reader)).to include("Ni hao")
    end

    it "serves anonymous readers the site default" do
      expect(banner_json_for(nil)).to include(banner_post.cooked)
    end
  end

  describe "cache invalidation" do
    # The reader is parked on a language with no translation yet, so the first
    # render caches the original. Nothing in core invalidates that when the
    # translation later lands.
    before { prefer(spanish_reader, "th") }

    def add_thai_translation
      Fabricate(
        :post_translation,
        post: banner_post,
        language: "th",
        translated_content: "<p>Thai body</p>"
      )
    end

    it "lets a translation that arrives after the first render reach readers" do
      expect(banner_json_for(spanish_reader)).to include(banner_post.cooked)

      add_thai_translation
      BabelReunited.clear_banner_cache_for(banner_post)

      expect(banner_json_for(spanish_reader)).to include("Thai body")
    end

    it "ignores a post outside the banner topic" do
      banner_json_for(spanish_reader)
      add_thai_translation

      BabelReunited.clear_banner_cache_for(Fabricate(:post))

      expect(banner_json_for(spanish_reader)).not_to include("Thai body")
    end

    it "ignores a reply inside the banner topic" do
      banner_json_for(spanish_reader)
      add_thai_translation

      BabelReunited.clear_banner_cache_for(
        Fabricate(:post, topic: banner_topic, post_number: 2)
      )

      expect(banner_json_for(spanish_reader)).not_to include("Thai body")
    end
  end
end
