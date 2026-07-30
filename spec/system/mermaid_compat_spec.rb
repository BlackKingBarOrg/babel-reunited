# frozen_string_literal: true

# MANUAL VERIFICATION HARNESS — not CI regression coverage. CI runs without
# MERMAID_COMPONENT_PATH, so every example here is skipped there; run this
# locally (or against staging) before enabling the component:
#
#   MERMAID_COMPONENT_PATH=/path/to/discourse-mermaid-theme-component \
#     LOAD_PLUGINS=1 bin/rspec plugins/babel-reunited/spec/system/mermaid_compat_spec.rb
#
# It proves the official mermaid theme component renders in BOTH the original
# and the translated view (possible only since post content renders through
# core's cooked pipeline). The CI-side regression for the related product
# decision — diagram sources pass through translation byte-for-byte, labels
# untranslated — lives in translation_service_spec.rb.
RSpec.describe "Mermaid theme component compatibility", type: :system do
  MERMAID_BLOCK = <<~MERMAID.freeze
    ```mermaid
    flowchart TD
        A[Start] --> B[End]
    ```
  MERMAID

  MERMAID_RAW = <<~MD
    Intro paragraph.

    #{MERMAID_BLOCK}
    Outro paragraph.
  MD

  # What production actually generates: MarkdownProtector shields the fenced
  # block, so only the surrounding prose is translated and the diagram source
  # stays byte-for-byte identical, labels included.
  TRANSLATED_MERMAID_RAW = <<~MD
    介绍段落。

    #{MERMAID_BLOCK}
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

    # Diagram labels stay in the source language even in the translated view
    svg_text = find("#post_1 .mermaid-wrapper .mermaid-diagram svg").text
    expect(svg_text).to include("Start")
    expect(svg_text).to include("End")
    expect(svg_text).not_to include("开始")

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
