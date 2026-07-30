# frozen_string_literal: true

RSpec.describe "Language tabs" do
  fab!(:admin)
  fab!(:topic)
  fab!(:post_record) do
    Fabricate(
      :post,
      topic: topic,
      post_number: 1,
      raw: "Intro paragraph.\n\n```ruby\nputs 'hello'\n```\n\nOutro paragraph."
    )
  end

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    # Tab list is driven by this setting. Fabricated posts skip PostCreator
    # events, so no auto-translation jobs are enqueued and specs stay offline.
    SiteSetting.babel_reunited_auto_translate_languages = "en,zh-cn,es"
    # A user without a preference gets the language-preference modal after 1s,
    # which overlays the page and intercepts clicks mid-test.
    admin.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = "es"
    admin.save_custom_fields
    sign_in(admin)
  end

  it "shows the original tab, the preferred tab, and the language menu" do
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_css("#post_1 .ai-language-tabs")
    # original tab + preferred (es) tab + overflow menu trigger
    expect(page).to have_css("#post_1 .babel-reunited-language-tab", count: 3)
    expect(page).to have_css("#post_1 .babel-reunited-language-tab.--menu")
  end

  describe "cooked decoration pipeline" do
    fab!(:translation) do
      BabelReunited::PostTranslation.create!(
        post_id: post_record.id,
        language: "zh-cn",
        status: "completed",
        source_language: "en",
        translated_content:
          PrettyText.cook("介绍段落。\n\n```ruby\nputs 'hello'\n```\n\n结尾段落。"),
        translated_raw: "介绍段落。\n\n```ruby\nputs 'hello'\n```\n\n结尾段落。"
      )
    end

    # .codeblock-button-wrapper is added exclusively by core's client-side
    # decorator (registered via api.decorateCookedElement), so exactly one
    # wrapper inside the post is proof the decoration pipeline ran once.
    it "decorates the original view through core's pipeline" do
      visit "/t/#{topic.slug}/#{topic.id}"

      expect(page).to have_css("#post_1 .codeblock-button-wrapper", count: 1)
      expect(page).to have_css("#post_1 .cooked", count: 1)
    end

    def switch_to_translated
      find("#post_1 .babel-reunited-language-tab.--menu").click
      find(".babel-language-picker__item.--translated").click
    end

    it "decorates the translated view and never duplicates the post body" do
      visit "/t/#{topic.slug}/#{topic.id}"
      expect(page).to have_css("#post_1 .codeblock-button-wrapper", count: 1)

      # Switch to zh-cn via the overflow menu (fetches the body on demand)
      switch_to_translated
      expect(page).to have_css("#post_1 .cooked", text: "介绍段落")
      expect(page).to have_css("#post_1 .codeblock-button-wrapper", count: 1)
      expect(page).to have_css("#post_1 .cooked", count: 1)

      # Back to original, then translated again: no decoration DOM duplication
      find("#post_1 .ai-language-tabs button:nth-child(1)").click
      expect(page).to have_css("#post_1 .cooked", text: "Outro paragraph")
      expect(page).to have_css("#post_1 .codeblock-button-wrapper", count: 1)

      switch_to_translated
      expect(page).to have_css("#post_1 .cooked", text: "介绍段落")
      expect(page).to have_css("#post_1 .codeblock-button-wrapper", count: 1)
      expect(page).to have_css("#post_1 .cooked", count: 1)
    end
  end
end
