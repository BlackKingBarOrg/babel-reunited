# frozen_string_literal: true

# Compatibility proof for the official mermaid theme component rendering in
# BOTH the original and the translated view (the translated view only works
# since post content is rendered through core's cooked pipeline).
#
# Needs a local checkout of
# https://github.com/discourse/discourse-mermaid-theme-component — skipped
# unless MERMAID_COMPONENT_PATH points at it:
#
#   MERMAID_COMPONENT_PATH=/path/to/component LOAD_PLUGINS=1 \
#     bin/rspec plugins/babel-reunited/spec/system/mermaid_compat_spec.rb
RSpec.describe "Mermaid theme component compatibility", type: :system do
  MERMAID_RAW = <<~MD
    Intro paragraph.

    ```mermaid
    flowchart TD
        A[Start] --> B[End]
    ```

    Outro paragraph.
  MD

  TRANSLATED_MERMAID_RAW = <<~MD
    介绍段落。

    ```mermaid
    flowchart TD
        A[开始] --> B[结束]
    ```

    结尾段落。
  MD

  fab!(:admin)
  fab!(:topic)
  fab!(:post_record) do
    Fabricate(:post, topic: topic, post_number: 1, raw: MERMAID_RAW)
  end

  fab!(:translation) do
    BabelReunited::PostTranslation.create!(
      post_id: post_record.id,
      language: "zh-cn",
      status: "completed",
      source_language: "en",
      translated_raw: TRANSLATED_MERMAID_RAW,
      translated_content: PrettyText.cook(TRANSLATED_MERMAID_RAW)
    )
  end

  before do
    if ENV["MERMAID_COMPONENT_PATH"].blank?
      skip "Set MERMAID_COMPONENT_PATH to a checkout of discourse-mermaid-theme-component"
    end

    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_auto_translate_languages = "en,zh-cn,es"

    component =
      RemoteTheme.import_theme_from_directory(ENV["MERMAID_COMPONENT_PATH"])
    Theme.find(SiteSetting.default_theme_id).child_themes << component

    sign_in(admin)
  end

  it "renders mermaid in the original view with working fullscreen" do
    visit "/t/#{topic.slug}/#{topic.id}"

    expect(page).to have_css("#post_1 .mermaid-wrapper .mermaid-diagram svg")
    expect(page).to have_css("#post_1 .mermaid-wrapper", count: 1)

    find("#post_1 .mermaid-wrapper").hover
    find("#post_1 .mermaid-fullscreen-button").click
    expect(page).to have_css(".mermaid-fullscreen .mermaid-diagram svg")
  end

  it "renders mermaid in the translated view and survives language switching" do
    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css("#post_1 .mermaid-wrapper .mermaid-diagram svg")

    # Switch to zh-cn (button order: Original, en, zh-cn, es)
    find("#post_1 .ai-language-tabs button:nth-child(3)").click
    expect(page).to have_css("#post_1 .cooked", text: "介绍段落")
    expect(page).to have_css("#post_1 .mermaid-wrapper .mermaid-diagram svg")
    expect(page).to have_css("#post_1 .mermaid-wrapper", count: 1)

    find("#post_1 .ai-language-tabs button:nth-child(1)").click
    expect(page).to have_css("#post_1 .cooked", text: "Outro paragraph")
    expect(page).to have_css("#post_1 .mermaid-wrapper", count: 1)

    find("#post_1 .ai-language-tabs button:nth-child(3)").click
    expect(page).to have_css("#post_1 .cooked", text: "介绍段落")
    expect(page).to have_css("#post_1 .mermaid-wrapper .mermaid-diagram svg")
    expect(page).to have_css("#post_1 .mermaid-wrapper", count: 1)
  end

  it "fails controlled on invalid mermaid syntax in the translated view" do
    translation.update!(
      translated_raw: "```mermaid\nnot a valid diagram %%{}\n```",
      translated_content:
        PrettyText.cook("```mermaid\nnot a valid diagram %%{}\n```")
    )

    visit "/t/#{topic.slug}/#{topic.id}"
    find("#post_1 .ai-language-tabs button:nth-child(3)").click

    expect(page).to have_css("#post_1 .mermaid-wrapper .alert.alert-error")
  end
end
